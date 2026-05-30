// softmax_unit_lut.sv — LUT-based Q16.16 softmax (M4 Option C)
//
// Drop-in replacement for softmax_unit.sv. Same port list, same Q16.16
// numerical contract. Two structural changes recover the f_max that the
// Padé+combinational-divider version sacrificed:
//
//   1. Per-lane Padé[2,2] exp + 64-bit combinational divide is replaced
//      by a bank of N_LUT_BANKS exp_lut ROMs, time-multiplexed across
//      N_PHASES = ceil(VEC_LEN / N_LUT_BANKS) cycles. Each bank serves
//      VEC_LEN / N_LUT_BANKS lanes per row.
//   2. Stage-4 combinational 1/sum is replaced by the existing
//      divider_or_reciprocal_unit (registered, 2-cycle latency).
//
// Throughput: one row every (N_PHASES + 4) cycles after pipeline fill.
// The caller (stream_pipeline) already paces softmax inputs slower than
// this, so dropping back-pressure here is safe.
module softmax_unit_lut
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH  = 32,
  parameter int VEC_LEN     = 64,
  parameter int N_LUT_BANKS = (VEC_LEN < 8) ? VEC_LEN : 8,
  // M5: 0 = legacy 2-cycle combinational divider_or_reciprocal_unit
  //         (fast latency but ~65 ns combinational depth -- the
  //          post-M4 chip critical path);
  //     1 = iterative divider_or_reciprocal_seq for stage-4 1/sum
  //         (48-cycle latency, ~0.5 ns combinational depth -> closes chip
  //          timing). Side-band info (exp values, len, sum-zero flag)
  //          held in a single wait register.
  //
  // M5 default is 1 -- aligns with the v_hand path's M5 swap so cosim,
  // Genus, and OpenLane all see the same architecture. Flip back to 0
  // explicitly if you need to compare against the legacy divider.
  parameter int USE_PIPELINED_DIVIDER = 1
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            start,

  // Active length: only first vec_len slots participate; the rest are
  // masked to 0 on the output. vec_len <= VEC_LEN.
  input  logic [7:0]                      vec_len,

  input  logic signed [DATA_WIDTH-1:0]    scores_in [VEC_LEN],
  input  logic                            in_valid,

  output logic signed [DATA_WIDTH-1:0]    probs_out [VEC_LEN],
  output logic                            out_valid
);

  // Number of LUT cycles per row.
  localparam int N_PHASES = (VEC_LEN + N_LUT_BANKS - 1) / N_LUT_BANKS;

  // 8.0 in Q16.16 — used to shift the [-8,0] exp domain up to [0,8] before
  // converting to the 8-bit LUT address.
  localparam logic signed [31:0] Q_EIGHT = 32'sh00080000;

  // Convert a Q16.16 difference (score - max, expected in [-8, 0]) to an
  // 8-bit address into the 256-entry exp_lut.mem (which spans [-8, 0]).
  // Address mapping: addr = (diff + 8) * 256 / 8 = (diff + 8) >> 11.
  function automatic logic [7:0] q_to_lut_addr(input logic signed [31:0] diff);
    logic signed [31:0] clamped;
    logic        [31:0] shifted;
    if (diff < Q_EXP_MIN)      clamped = Q_EXP_MIN;
    else if (diff > Q_ZERO)    clamped = Q_ZERO;
    else                       clamped = diff;
    shifted = clamped + Q_EIGHT;          // 0 .. 0x00080000
    if (shifted >= 32'h00080000) return 8'd255;
    return shifted[18:11];
  endfunction

  // 1/N fallback table for the degenerate sum<=0 path. The exact value is
  // not critical — this path only fires when every score is below -8
  // (an out-of-domain input). Keeps the fallback combinational-divider-free.
  function automatic logic signed [31:0] q_uniform_recip(input logic [7:0] n);
    case (n)
      8'd1:    return Q_ONE;
      8'd2:    return 32'sh00008000;  // 0.5
      8'd4:    return 32'sh00004000;  // 0.25
      8'd8:    return 32'sh00002000;  // 0.125
      8'd16:   return 32'sh00001000;
      8'd32:   return 32'sh00000800;
      8'd64:   return 32'sh00000400;
      default: return 32'sh00000400;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Stage 1: latch scores + find row max (identical to softmax_unit.sv)
  // ---------------------------------------------------------------------
  logic               s1_valid;
  logic [7:0]         s1_len;
  logic signed [31:0] s1_scores [VEC_LEN];
  logic signed [31:0] s1_max;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_max   <= '0;
      s1_len   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s1_scores[i] <= '0;
    end else if (en && in_valid) begin
      logic signed [31:0] mx;
      s1_valid <= 1'b1;
      s1_len   <= vec_len;
      mx = scores_in[0];
      s1_scores[0] <= scores_in[0];
      for (int i = 1; i < VEC_LEN; i++) begin
        if ((i < int'(vec_len)) && (scores_in[i] > mx)) mx = scores_in[i];
        s1_scores[i] <= scores_in[i];
      end
      s1_max <= mx;
    end else if (en) begin
      s1_valid <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Stage 2: time-multiplexed LUT lookups for exp(score - max)
  // ---------------------------------------------------------------------
  //
  // FSM: idle → busy. While busy, s2_phase walks 0..N_PHASES-1, presenting
  // N_LUT_BANKS addresses per cycle. LUT outputs lag the address by one
  // cycle (exp_lut registers data). s2_phase_valid_d1/s2_phase_cap_d1
  // carry the address-side phase index forward by one cycle so the data
  // capture logic knows which lanes are landing.
  //
  // Note on declarations: s2_phase is sized as [7:0] for headroom; the
  // FSM only ever counts to N_PHASES-1 (≤16 for default N_LUT_BANKS=8 and
  // VEC_LEN up to 128).

  logic               s2_busy;
  logic [7:0]         s2_phase;
  logic               s2_phase_valid_d1;
  logic [7:0]         s2_phase_cap_d1;
  logic               s2_valid;
  logic [7:0]         s2_len;
  logic signed [31:0] s2_max_held;
  logic signed [31:0] s2_scores_held [VEC_LEN];
  logic signed [31:0] s2_exp [VEC_LEN];

  logic [7:0]         lut_addr [N_LUT_BANKS];
  logic signed [31:0] lut_data [N_LUT_BANKS];

  genvar gb;
  generate
    for (gb = 0; gb < N_LUT_BANKS; gb++) begin : g_lut_bank
      exp_lut #(
        .DATA_WIDTH (DATA_WIDTH)
      ) u_exp_lut (
        .clk  (clk),
        .addr (lut_addr[gb]),
        .data (lut_data[gb])
      );
    end
  endgenerate

  // Combinational address generation for the current phase.
  // The (score - max) difference is computed inline inside the
  // q_to_lut_addr call rather than via an intermediate reg, because
  // the hand-flatten path (project/m3/synth/v_hand/softmax_unit_lut.v)
  // has to hoist temporaries to module scope where a write only in
  // the "if" branch infers a latch. Keep the structure identical in
  // both flows to avoid divergence.
  always_comb begin
    for (int b = 0; b < N_LUT_BANKS; b++) begin
      int lane;
      lane = int'(s2_phase) * N_LUT_BANKS + b;
      if (s2_busy && (lane < VEC_LEN) && (lane < int'(s2_len)))
        lut_addr[b] = q_to_lut_addr(s2_scores_held[lane] - s2_max_held);
      else
        lut_addr[b] = 8'd0;
    end
  end

  // Phase FSM + LUT data capture.
  //
  // Split into per-register always_ff blocks to avoid yosys inferring
  // $_ALDFFE_PNP_ (async-load DFF) cells that Sky130 standard cells
  // can't realize. Each register gets a clean
  //   if (!rst_n) <reset> else if (en) <update>
  // shape and maps to a Sky130 DFFE via dfflibmap.

  // --- FSM state: s2_busy, s2_phase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_busy  <= 1'b0;
      s2_phase <= '0;
    end else if (en) begin
      if (!s2_busy) begin
        if (s1_valid) begin
          s2_busy  <= 1'b1;
          s2_phase <= '0;
        end
      end else begin
        if (s2_phase == 8'(N_PHASES - 1)) begin
          s2_busy  <= 1'b0;
          s2_phase <= '0;
        end else begin
          s2_phase <= s2_phase + 8'd1;
        end
      end
    end
  end

  // --- 1-cycle FSM shadow regs
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_phase_valid_d1 <= 1'b0;
      s2_phase_cap_d1   <= '0;
    end else if (en) begin
      s2_phase_valid_d1 <= s2_busy;
      s2_phase_cap_d1   <= s2_phase;
    end
  end

  // --- Held state captured at start of a row
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_len      <= '0;
      s2_max_held <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s2_scores_held[i] <= '0;
    end else if (en && !s2_busy && s1_valid) begin
      s2_len      <= s1_len;
      s2_max_held <= s1_max;
      for (int i = 0; i < VEC_LEN; i++)
        s2_scores_held[i] <= s1_scores[i];
    end
  end

  // --- s2_valid pulse: fires for one cycle when the last phase's LUT
  // data lands (delayed phase cap reaches N_PHASES-1).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
    end else if (en) begin
      s2_valid <= s2_phase_valid_d1 &&
                  (s2_phase_cap_d1 == 8'(N_PHASES - 1));
    end
  end

  // --- LUT data capture: writes N_LUT_BANKS adjacent lanes per phase.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < VEC_LEN; i++)
        s2_exp[i] <= '0;
    end else if (en && s2_phase_valid_d1) begin
      for (int b = 0; b < N_LUT_BANKS; b++) begin
        int lane;
        lane = int'(s2_phase_cap_d1) * N_LUT_BANKS + b;
        if (lane < VEC_LEN) begin
          if (lane < int'(s2_len))
            s2_exp[lane] <= lut_data[b];
          else
            s2_exp[lane] <= '0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------
  // Stage 3: sum exponentials (single-cycle reduction)
  // ---------------------------------------------------------------------
  logic               s3_valid;
  logic [7:0]         s3_len;
  logic signed [31:0] s3_exp [VEC_LEN];
  logic signed [31:0] s3_sum;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
      s3_sum   <= '0;
      s3_len   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s3_exp[i] <= '0;
    end else if (en) begin
      s3_valid <= s2_valid;
      s3_len   <= s2_len;
      if (s2_valid) begin
        logic signed [31:0] acc;
        acc = '0;
        for (int i = 0; i < VEC_LEN; i++) begin
          if (i < int'(s2_len))
            acc = acc + s2_exp[i];
          s3_exp[i] <= s2_exp[i];
        end
        s3_sum <= acc;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Stage 4: reciprocal divide (1/sum) via shared unit.
  //
  // Two variants gated by USE_PIPELINED_DIVIDER:
  //   0 (default) - divider_or_reciprocal_unit, 2-cycle pipeline.
  //                 Side-band info (exp values, len, sum-zero) carried
  //                 through a 2-deep shadow pipe.
  //   1 (M5)      - divider_or_reciprocal_seq, ~48-cycle iterative pipe.
  //                 Side-band info latched once into a wait register
  //                 when in_valid asserts, held until out_valid pulses.
  //                 Same wait-register pattern would work for ANY
  //                 divider latency.
  // ---------------------------------------------------------------------

  logic               div_in_valid;
  logic signed [31:0] div_num, div_den;
  logic               div_ready;
  logic               recip_valid;
  logic signed [31:0] recip;
  logic               s3_sum_zero;

  assign div_num     = Q_ONE;
  assign div_den     = (s3_sum > 0) ? s3_sum : Q_ONE;
  assign s3_sum_zero = (s3_sum <= 0);

  generate
    if (USE_PIPELINED_DIVIDER) begin : g_seq_div
      divider_or_reciprocal_seq #(
        .DATA_WIDTH (DATA_WIDTH),
        .N_ITER     (48)
      ) u_recip (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .numerator   (div_num),
        .denominator (div_den),
        .in_valid    (div_in_valid),
        .ready       (div_ready),
        .quotient    (recip),
        .out_valid   (recip_valid)
      );
    end else begin : g_comb_div
      divider_or_reciprocal_unit #(
        .DATA_WIDTH (DATA_WIDTH)
      ) u_recip (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .numerator   (div_num),
        .denominator (div_den),
        .in_valid    (div_in_valid),
        .quotient    (recip),
        .out_valid   (recip_valid)
      );
      assign div_ready = 1'b1;  // legacy has no backpressure
    end
  endgenerate

  // s3 fires divider only when divider is ready. The LUT-side row
  // cadence at ARRAY_DIM=N is N_PHASES = ceil(N/8) cycles, which is
  // less than the 48-cycle iterative divider latency at ARRAY_DIM>=8.
  // The simulator will see s3_valid pulses dropped when the divider
  // is BUSY; integration tests must respect this throughput cap.
  // (Backpressure to upstream stages is a follow-on -- the cf07-style
  // softmax workloads issue rows once per attention step, far slower
  // than the divider, so no rows are lost in practice.)
  assign div_in_valid = s3_valid && div_ready;

  // -------- Side-band info carried through the divider latency --------
  // For USE_PIPELINED_DIVIDER=0 we use the original 2-deep shadow pipe.
  // For USE_PIPELINED_DIVIDER=1 we use a single wait register latched
  // on div_in_valid, released by recip_valid.
  logic                       s4_pipe_valid_d1, s4_pipe_valid_d2;
  logic [7:0]                 s4_pipe_len_d1,   s4_pipe_len_d2;
  logic                       s4_d1_sum_zero,   s4_d2_sum_zero;
  logic signed [31:0]         s4_pipe_exp_d1 [VEC_LEN];
  logic signed [31:0]         s4_pipe_exp_d2 [VEC_LEN];

  logic                       s4_wait_valid;
  logic [7:0]                 s4_wait_len;
  logic                       s4_wait_sum_zero;
  logic signed [31:0]         s4_wait_exp [VEC_LEN];

  generate
    if (USE_PIPELINED_DIVIDER) begin : g_wait_reg
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          s4_wait_valid    <= 1'b0;
          s4_wait_len      <= '0;
          s4_wait_sum_zero <= 1'b0;
          for (int i = 0; i < VEC_LEN; i++)
            s4_wait_exp[i] <= '0;
        end else if (en) begin
          if (div_in_valid) begin
            s4_wait_valid    <= 1'b1;
            s4_wait_len      <= s3_len;
            s4_wait_sum_zero <= s3_sum_zero;
            for (int i = 0; i < VEC_LEN; i++)
              s4_wait_exp[i] <= s3_exp[i];
          end else if (recip_valid) begin
            s4_wait_valid <= 1'b0;
          end
        end
      end
      // Tie off the shadow pipe so the always_ff below doesn't latch.
      always_comb begin
        s4_pipe_valid_d1 = 1'b0;
        s4_pipe_valid_d2 = 1'b0;
        s4_pipe_len_d1   = '0;
        s4_pipe_len_d2   = '0;
        s4_d1_sum_zero   = 1'b0;
        s4_d2_sum_zero   = 1'b0;
        for (int i = 0; i < VEC_LEN; i++) begin
          s4_pipe_exp_d1[i] = '0;
          s4_pipe_exp_d2[i] = '0;
        end
      end
    end else begin : g_shadow_pipe
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          s4_pipe_valid_d1 <= 1'b0;
          s4_pipe_valid_d2 <= 1'b0;
          s4_pipe_len_d1   <= '0;
          s4_pipe_len_d2   <= '0;
          s4_d1_sum_zero   <= 1'b0;
          s4_d2_sum_zero   <= 1'b0;
          for (int i = 0; i < VEC_LEN; i++) begin
            s4_pipe_exp_d1[i] <= '0;
            s4_pipe_exp_d2[i] <= '0;
          end
        end else if (en) begin
          s4_pipe_valid_d1 <= s3_valid;
          s4_pipe_valid_d2 <= s4_pipe_valid_d1;
          s4_pipe_len_d1   <= s3_len;
          s4_pipe_len_d2   <= s4_pipe_len_d1;
          s4_d1_sum_zero   <= s3_sum_zero;
          s4_d2_sum_zero   <= s4_d1_sum_zero;
          for (int i = 0; i < VEC_LEN; i++) begin
            s4_pipe_exp_d1[i] <= s3_exp[i];
            s4_pipe_exp_d2[i] <= s4_pipe_exp_d1[i];
          end
        end
      end
      // Tie off the wait register.
      always_comb begin
        s4_wait_valid    = 1'b0;
        s4_wait_len      = '0;
        s4_wait_sum_zero = 1'b0;
        for (int i = 0; i < VEC_LEN; i++)
          s4_wait_exp[i] = '0;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------
  // Stage 5: multiply each exp by the reciprocal (or uniform fallback).
  // Selects between the shadow pipe (legacy) and wait register (M5) by
  // the same USE_PIPELINED_DIVIDER parameter -- which set is live is a
  // synthesis-time choice with no runtime mux on probs_out.
  // ---------------------------------------------------------------------
  // Source signals that feed stage 5:
  logic [7:0]                 s5_len;
  logic                       s5_sum_zero;
  logic signed [31:0]         s5_exp [VEC_LEN];

  assign s5_len      = USE_PIPELINED_DIVIDER ? s4_wait_len      : s4_pipe_len_d2;
  assign s5_sum_zero = USE_PIPELINED_DIVIDER ? s4_wait_sum_zero : s4_d2_sum_zero;
  genvar gi;
  generate
    for (gi = 0; gi < VEC_LEN; gi++) begin : g_s5_exp_mux
      assign s5_exp[gi] = USE_PIPELINED_DIVIDER ? s4_wait_exp[gi]
                                                : s4_pipe_exp_d2[gi];
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      for (int i = 0; i < VEC_LEN; i++)
        probs_out[i] <= '0;
    end else if (en) begin
      out_valid <= recip_valid;
      if (recip_valid) begin
        if (!s5_sum_zero) begin
          for (int i = 0; i < VEC_LEN; i++) begin
            if (i < int'(s5_len))
              probs_out[i] <= q_mul(s5_exp[i], recip);
            else
              probs_out[i] <= '0;
          end
        end else begin
          logic signed [31:0] uniform;
          uniform = (s5_len == 0) ? '0 : q_uniform_recip(s5_len);
          for (int i = 0; i < VEC_LEN; i++) begin
            if (i < int'(s5_len))
              probs_out[i] <= uniform;
            else
              probs_out[i] <= '0;
          end
        end
      end
    end
  end

endmodule
