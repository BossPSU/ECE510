// stream_pipeline.sv — Streaming fused compute pipeline
// Once `start` asserts, runs autonomously to completion. No FSM micromanagement.
//
// Internal stages (all continuously active during `running`):
//   feeder -> systolic -> [elemwise path | softmax path] -> output buffer
//
// Intermediates flow through registers, NEVER materialize in SRAM.
// This is the "fusion" — the FSM only sees start/done at the boundaries.
//
// FULL M x N x K SUPPORT:
//   Input buffers expose their full memory (a_mem, b_mem). The feeder
//   constructs the proper output-stationary skewed feed:
//     a_in[r] at cycle (s+1) = A[r][s-r]   if r < tile_m and s-r in [0, tile_k)
//     b_in[c] at cycle (s+1) = B[s-c][c]   if c < tile_n and s-c in [0, tile_k)
//   PE[r][c] then accumulates A[r][k]*B[k][c] for k in [0, tile_k).
//
// TWO POST-PROCESSING PATHS:
//   Elemwise (GELU, GELU_GRAD, BYPASS, MASK):
//     Output mux walks all tile_m * tile_n cells through the fused unit.
//   Softmax:
//     Feed entire c_out row to softmax_unit in parallel (one row/cycle).
//     After SOFTMAX_LAT cycles, capture probs_out rows into a 2D buffer.
//     Then walk the buffer to the output buffer one element/cycle.
module stream_pipeline
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH      = 32,
  parameter int ARRAY_DIM       = ARRAY_ROWS,  // square array
  // 0 = current Padé+comb-divide softmax (default; unchanged behavior)
  // 1 = LUT+seq-divide softmax (softmax_unit_lut, M4 Option C)
  parameter int USE_LUT_SOFTMAX = 1,
  // 0 = current Padé+comb-divide gelu / gelu_grad
  // 1 = direct LUT+linterp gelu_unit_lut / gelu_grad_unit_lut (M4)
  // Threaded into fused_postproc_unit so the chip-level synth actually
  // picks up the M4 LUT swap. Without this, fused_postproc_unit defaults
  // to the Padé path and the gelu_grad combinational divider becomes the
  // chip critical path (M5 phobos run observed -14.85 ns slack at TT).
  parameter int USE_LUT_GELU    = 1,
  // M5 MAC pipeline selector. Threaded to systolic_array_64x64 and used
  // to size DRAIN_CYCLES locally.
  //   USE_PIPED4_MAC == 1 -> mac_pe_piped4 (4-stage, option D)
  //   USE_PIPED_MAC  == 1 -> mac_pe_piped  (2-stage, option C)
  //   neither         -> legacy mac_pe (1-stage)
  parameter int USE_PIPED4_MAC  = 1,
  parameter int USE_PIPED_MAC   = 1
)(
  input  logic                            clk,
  input  logic                            rst_n,

  // Boundary control
  input  logic                            start,        // pulse to begin
  output logic                            done,         // pulse when complete
  input  logic [7:0]                      tile_m,       // result rows
  input  logic [7:0]                      tile_n,       // result cols
  input  logic [7:0]                      tile_k,       // shared dim
  input  fused_op_t                       op_sel,       // GELU / GELU' / softmax / bypass

  // Multi-port read interface to input-A buffer (ARRAY_DIM scattered reads
  // per cycle — one per array row). Drives mp_rd_row/col, reads mp_rd_data.
  output logic [7:0]                      a_rd_row  [ARRAY_DIM],
  output logic [7:0]                      a_rd_col  [ARRAY_DIM],
  input  logic signed [DATA_WIDTH-1:0]    a_rd_data [ARRAY_DIM],

  // Same for input-B buffer (ARRAY_DIM reads/cycle, one per array column).
  output logic [7:0]                      b_rd_row  [ARRAY_DIM],
  output logic [7:0]                      b_rd_col  [ARRAY_DIM],
  input  logic signed [DATA_WIDTH-1:0]    b_rd_data [ARRAY_DIM],

  // Auxiliary buffer (h_pre for FFN_BWD); only one element/cycle needed
  // — paired with the elemwise output mux's (row, col). Unused for other modes.
  output logic [7:0]                      aux_rd_row,
  output logic [7:0]                      aux_rd_col,
  input  logic signed [DATA_WIDTH-1:0]    aux_rd_data,

  // Write interface to output buffer ({row[5:0], col[5:0]})
  output logic                            out_wr_en,
  output logic [11:0]                     out_wr_idx,
  output logic signed [DATA_WIDTH-1:0]    out_wr_data,

  // Status: high while internal compute is in progress (for perf counters)
  output logic                            running_o
);

  // ==========================================================
  // Phase counter — drives all internal stages without an FSM
  // ==========================================================

  logic [15:0] cycle_cnt;
  logic        running;
  assign running_o = running;

  // ==========================================================
  // Tile-dim shadow registers (Option F)
  //
  // Local flop snapshots of tile_m / tile_n / tile_k. All downstream
  // logic (cycle-bound calculation, per-cycle comparators, output
  // counter terminators, softmax vec_len) reads the _r versions
  // instead of the input ports, so every path that previously
  // launched from a primary input pin now launches from a local
  // flop CK->Q (~50 ps) instead of input_delay (~400 ps).
  //
  // FSM assumption: tile_m / tile_n / tile_k are stable for at least
  // 2 cycles before `start` is pulsed. The accel_engine writes the
  // tile config in one FSM state and pulses `start` in a later state,
  // so this is naturally satisfied.
  // ==========================================================
  logic [7:0]  tile_m_r, tile_n_r, tile_k_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tile_m_r <= 8'd0;
      tile_n_r <= 8'd0;
      tile_k_r <= 8'd0;
    end else begin
      tile_m_r <= tile_m;
      tile_n_r <= tile_n;
      tile_k_r <= tile_k;
    end
  end

  // Drain depth grows with the MAC pipeline depth:
  //   legacy mac_pe       -> drain 4
  //   mac_pe_piped (+1)   -> drain 5
  //   mac_pe_piped4 (+3)  -> drain 7
  // M6 Tier 1.5 (Option B) adds +1: array inputs registered at
  // stream_pipeline boundary -> array sees data 1 cycle late.
  // M6 Tier 1.6 (extended Option B) adds +1 more: tile_buffer
  // address ports also registered -> array data path is now 2
  // cycles delayed from the cycle_cnt that drove the address.
  localparam int DRAIN_CYCLES   = USE_PIPED4_MAC ? 9 :
                                  (USE_PIPED_MAC ? 7 : 6);
  // M6 Tier 2: +2 vs M5 -- one for the new fused_postproc output register
  // (Tier 2A) and one for the gelu LUT stage-3 split (Tier 2B).
  localparam int FUSED_DEPTH    = 9;
  // Padé softmax_unit: in_valid -> out_valid = 4 cycles.
  // LUT softmax_unit_lut M6 Tier 3: latency = 8 + N_PHASES (was 7 + N_PHASES;
  // +1 from the new s5 multiplier-output register that breaks the
  // s4_wait_exp -> q_mul -> probs_out chain).
  localparam int LUT_N_BANKS    = (ARRAY_DIM < 8) ? ARRAY_DIM : 8;
  localparam int LUT_N_PHASES   = (ARRAY_DIM + LUT_N_BANKS - 1) / LUT_N_BANKS;
  localparam int SOFTMAX_LAT    = USE_LUT_SOFTMAX ? (8 + LUT_N_PHASES) : 4;

  logic        softmax_mode;
  assign softmax_mode = (op_sel == FUSED_SOFTMAX);

  // M6 Tier 1: register all cycle-boundary values at `start` so the
  // tile_m*tile_n product (the ~12 ns Sky130-SS chip critical path on
  // Attempt 9 -- 461 of 833 violators >5 ns landed here) drops off
  // the per-cycle comparator cone. The bounds are stable for the
  // entire tile, so latching them once at start is functionally
  // identical to the original combinational version.
  logic [15:0] feed_end_c, output_start_c, output_end_c, elemwise_end_c;
  logic [15:0] sm_feed_end_c, sm_capture_start_c, sm_capture_end_c;
  logic [15:0] sm_walk_start_c, sm_walk_end_c;

  // Option F: bound calculation reads tile_m_r/n_r/k_r (local flops)
  // instead of the input ports. The 8x8 multiplier (tile_m * tile_n)
  // -- the worst path in the c06bfee run at -349 ps slack -- now
  // launches from a flop instead of an input port, saving the 400 ps
  // input_delay charge and dropping the bound-calc path delay from
  // 1,111 ps to ~750 ps (multiplier + adder only).
  assign feed_end_c         = {8'b0, tile_m_r} + {8'b0, tile_n_r}
                            + {8'b0, tile_k_r} + 16'd2;
  assign output_start_c     = feed_end_c + 16'(DRAIN_CYCLES);
  assign output_end_c       = output_start_c
                            + ({8'b0, tile_m_r} * {8'b0, tile_n_r});
  assign elemwise_end_c     = output_end_c + 16'(FUSED_DEPTH);
  // Softmax bounds: backpressured by the divider's ~48-cycle latency, so
  // worst-case row period is SM_ROW_PERIOD cycles. We use a conservative
  // 64 to cover divider iterations + Stage 2 LUT phases + sideband
  // pipeline cycles. The actual schedule is data-driven (counters
  // increment on accept/output_valid) but cycle_cnt-based bounds still
  // form the outer "tile not done" window for the done-pulse generator.
  localparam int SM_ROW_PERIOD = 64;
  assign sm_feed_end_c      = output_start_c
                            + ({8'b0, tile_m_r} * 16'(SM_ROW_PERIOD));
  assign sm_capture_start_c = output_start_c + 16'(SOFTMAX_LAT);
  // Capture window must cover the entire feed window (each fed row
  // eventually produces an output_valid).
  assign sm_capture_end_c   = sm_feed_end_c + 16'(SM_ROW_PERIOD);
  assign sm_walk_start_c    = sm_capture_end_c;
  assign sm_walk_end_c      = sm_walk_start_c
                            + ({8'b0, tile_m_r} * {8'b0, tile_n_r});

  logic [15:0] feed_end, output_start, output_end, elemwise_end;
  logic [15:0] sm_feed_end, sm_capture_start, sm_capture_end;
  logic [15:0] sm_walk_start, sm_walk_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      feed_end         <= 16'd0;
      output_start     <= 16'd0;
      output_end       <= 16'd0;
      elemwise_end     <= 16'd0;
      sm_feed_end      <= 16'd0;
      sm_capture_start <= 16'd0;
      sm_capture_end   <= 16'd0;
      sm_walk_start    <= 16'd0;
      sm_walk_end      <= 16'd0;
    end else if (start && !running) begin
      feed_end         <= feed_end_c;
      output_start     <= output_start_c;
      output_end       <= output_end_c;
      elemwise_end     <= elemwise_end_c;
      sm_feed_end      <= sm_feed_end_c;
      sm_capture_start <= sm_capture_start_c;
      sm_capture_end   <= sm_capture_end_c;
      sm_walk_start    <= sm_walk_start_c;
      sm_walk_end      <= sm_walk_end_c;
    end
  end

  // all_end picks the longer path (combinational select, but both
  // operands are now registered).
  logic [15:0] all_end;
  assign all_end = softmax_mode ? sm_walk_end : elemwise_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt <= '0;
      running   <= 1'b0;
      done      <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start && !running) begin
        running   <= 1'b1;
        cycle_cnt <= '0;
      end else if (running) begin
        cycle_cnt <= cycle_cnt + 16'd1;
        if (cycle_cnt >= all_end) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end

  // ==========================================================
  // Stage 1: Feeder — skewed input streams
  // ==========================================================
  logic feed_active;
  assign feed_active = running && (cycle_cnt < feed_end);

  // Clear accumulators at cycle_cnt == 0 (with en=1 and a/b=0 -> acc cleared)
  logic array_clear;
  assign array_clear = running && (cycle_cnt == 16'd0);

  logic signed [31:0] a_in_array [ARRAY_DIM];
  logic signed [31:0] b_in_array [ARRAY_DIM];

  logic        feed_valid_a [ARRAY_DIM];
  logic        feed_valid_b [ARRAY_DIM];
  logic [15:0] feed_idx_a   [ARRAY_DIM];  // s - r
  logic [15:0] feed_idx_b   [ARRAY_DIM];  // s - c

  // Combinational tile_buffer-address candidates (before registering).
  logic [7:0]  a_rd_col_int [ARRAY_DIM];
  logic [7:0]  b_rd_row_int [ARRAY_DIM];

  genvar gr, gc;
  generate
    for (gr = 0; gr < ARRAY_DIM; gr++) begin : gen_feed_a
      assign feed_idx_a[gr]   = cycle_cnt - 16'd1 - 16'(gr);
      // Option F: per-cycle comparators read tile_m_r / tile_k_r (local
      // flops) instead of the input ports -- collapses the 400 ps
      // input_delay charge on every per-row feed_valid.
      assign feed_valid_a[gr] = feed_active &&
                                (cycle_cnt > 16'(gr)) &&
                                (16'(gr) < {8'b0, tile_m_r}) &&
                                (feed_idx_a[gr] < {8'b0, tile_k_r});
      assign a_rd_col_int[gr] = feed_valid_a[gr] ? feed_idx_a[gr][7:0]
                                                 : 8'd0;
    end
    for (gc = 0; gc < ARRAY_DIM; gc++) begin : gen_feed_b
      assign feed_idx_b[gc]   = cycle_cnt - 16'd1 - 16'(gc);
      assign feed_valid_b[gc] = feed_active &&
                                (cycle_cnt > 16'(gc)) &&
                                (16'(gc) < {8'b0, tile_n_r}) &&
                                (feed_idx_b[gc] < {8'b0, tile_k_r});
      assign b_rd_row_int[gc] = feed_valid_b[gc] ? feed_idx_b[gc][7:0]
                                                 : 8'd0;
    end
  endgenerate

  // ==========================================================
  // Stage 1.5a: tile_buffer address + feed_valid register
  //
  // M6 Tier 1.6 (extended Option B). The c06bfee run had 5 of the top
  // 20 violators at -329 to -340 ps on `a_rd_col[*]` / `b_rd_row[*]`
  // primary output ports -- the same comparator cone Option B broke
  // for `a_in_array`, but launched from a different exit. Registering
  // the tile_buffer address ports (and the per-row feed_valid bit so
  // the data side can re-AND with the right qualifier) collapses the
  // output-port path to 0 ps of combinational delay from this flop.
  //
  // Cost: +1 cycle of array-fill latency (absorbed by DRAIN_CYCLES
  // += 1 above), ~1,150 extra flops chip-wide (~0.006 mm^2 at SAED32).
  // ==========================================================
  logic        feed_valid_a_r [ARRAY_DIM];
  logic        feed_valid_b_r [ARRAY_DIM];
  logic [7:0]  a_rd_col_r     [ARRAY_DIM];
  logic [7:0]  b_rd_row_r     [ARRAY_DIM];
  // feed_active / array_clear get a first stage here so the second
  // stage below (the original Option B flop) keeps them aligned with
  // the data path after this extra pipeline cycle.
  logic        feed_active_p1;
  logic        array_clear_p1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      feed_active_p1 <= 1'b0;
      array_clear_p1 <= 1'b0;
      for (int i = 0; i < ARRAY_DIM; i++) begin
        feed_valid_a_r[i] <= 1'b0;
        feed_valid_b_r[i] <= 1'b0;
        a_rd_col_r[i]     <= 8'd0;
        b_rd_row_r[i]     <= 8'd0;
      end
    end else begin
      feed_active_p1 <= feed_active;
      array_clear_p1 <= array_clear;
      for (int i = 0; i < ARRAY_DIM; i++) begin
        feed_valid_a_r[i] <= feed_valid_a[i];
        feed_valid_b_r[i] <= feed_valid_b[i];
        a_rd_col_r[i]     <= a_rd_col_int[i];
        b_rd_row_r[i]     <= b_rd_row_int[i];
      end
    end
  end

  // Drive tile_buffer address output ports from registers (Class B fix).
  generate
    for (gr = 0; gr < ARRAY_DIM; gr++) begin : gen_addr_a
      assign a_rd_row[gr] = 8'(gr);
      assign a_rd_col[gr] = a_rd_col_r[gr];
    end
    for (gc = 0; gc < ARRAY_DIM; gc++) begin : gen_addr_b
      assign b_rd_row[gc] = b_rd_row_r[gc];
      assign b_rd_col[gc] = 8'(gc);
    end
  endgenerate

  // tile_buffer combinationally reads a_rd_data/b_rd_data from the
  // registered addresses. The qualifier we AND against is the
  // registered feed_valid, so a_in_array / b_in_array now reflect the
  // intent of cycle (current - 1).
  generate
    for (gr = 0; gr < ARRAY_DIM; gr++) begin : gen_a_in
      assign a_in_array[gr] = feed_valid_a_r[gr] ? a_rd_data[gr]
                                                 : 32'sd0;
    end
    for (gc = 0; gc < ARRAY_DIM; gc++) begin : gen_b_in
      assign b_in_array[gc] = feed_valid_b_r[gc] ? b_rd_data[gc]
                                                 : 32'sd0;
    end
  endgenerate

  // ==========================================================
  // Stage 1.5b: pipeline register between feeder and systolic array
  //
  // M6 Tier 1.5 (original Option B). The c06bfee run measured this
  // stage already in place; it brought the cycle_cnt -> MUX -> MAC
  // path from 1,833 ps down to 1,111 ps. Kept here verbatim --
  // feeds the array `en` / `clear_acc` / `a_in` / `b_in` from a
  // second pipeline stage that aligns with the address-side flops
  // above.
  // ==========================================================
  logic                feed_active_r;
  logic                array_clear_r;
  logic signed [31:0]  a_in_array_r [ARRAY_DIM];
  logic signed [31:0]  b_in_array_r [ARRAY_DIM];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      feed_active_r <= 1'b0;
      array_clear_r <= 1'b0;
      for (int i = 0; i < ARRAY_DIM; i++) begin
        a_in_array_r[i] <= 32'sd0;
        b_in_array_r[i] <= 32'sd0;
      end
    end else begin
      feed_active_r <= feed_active_p1;
      array_clear_r <= array_clear_p1;
      for (int i = 0; i < ARRAY_DIM; i++) begin
        a_in_array_r[i] <= a_in_array[i];
        b_in_array_r[i] <= b_in_array[i];
      end
    end
  end

  // ==========================================================
  // Stage 2: Systolic array — output-stationary, full ARRAY_DIM x ARRAY_DIM
  // ==========================================================
  logic signed [31:0] c_out_array [ARRAY_DIM][ARRAY_DIM];

  systolic_array_64x64 #(
    .ROWS           (ARRAY_DIM),
    .COLS           (ARRAY_DIM),
    .DATA_WIDTH     (32),
    .USE_PIPED4_MAC (USE_PIPED4_MAC),
    .USE_PIPED_MAC  (USE_PIPED_MAC)
  ) u_array (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (feed_active_r),
    .clear_acc (array_clear_r),
    .a_in      (a_in_array_r),
    .b_in      (b_in_array_r),
    .c_out     (c_out_array)
  );

  // ==========================================================
  // Stage 3a: Elemwise output mux + fused unit
  //   Active for non-softmax modes only.
  // ==========================================================
  logic       out_active;
  logic [7:0] out_row_cnt, out_col_cnt;

  assign out_active = !softmax_mode && running &&
                      (cycle_cnt >= output_start) &&
                      (cycle_cnt <  output_end);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_row_cnt <= '0;
      out_col_cnt <= '0;
    end else if (start && !running) begin
      out_row_cnt <= '0;
      out_col_cnt <= '0;
    end else if (out_active) begin
      if (out_col_cnt + 8'd1 >= tile_n_r) begin
        out_col_cnt <= '0;
        out_row_cnt <= out_row_cnt + 8'd1;
      end else begin
        out_col_cnt <= out_col_cnt + 8'd1;
      end
    end
  end

  logic signed [31:0] mux_data;
  logic signed [31:0] aux_data;
  assign mux_data = c_out_array[out_row_cnt[5:0]][out_col_cnt[5:0]];
  // For FFN_BWD: read h_pre at the same (row, col) the elemwise mux is
  // walking. For other modes the buffer is unloaded and aux_rd_data = 0.
  assign aux_rd_row = out_row_cnt;
  assign aux_rd_col = out_col_cnt;
  assign aux_data   = aux_rd_data;

  // Fused activation (GELU, GELU_GRAD, BYPASS, MASK)
  logic signed [31:0] fused_out;
  logic               fused_valid;

  fused_postproc_unit #(
    .DATA_WIDTH   (32),
    .USE_LUT_GELU (USE_LUT_GELU)
  ) u_fused (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (1'b1),
    .op_sel    (op_sel),
    .data_in   (mux_data),
    .in_valid  (out_active),
    .aux_in    (aux_data),         // h_pre for GELU_GRAD; ignored for other ops
    .data_out  (fused_out),
    .out_valid (fused_valid)
  );

  // Elemwise collector (independent counter to absorb fused-pipe latency)
  logic [7:0] coll_row_cnt, coll_col_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      coll_row_cnt <= '0;
      coll_col_cnt <= '0;
    end else if (start && !running) begin
      coll_row_cnt <= '0;
      coll_col_cnt <= '0;
    end else if (fused_valid && running && !softmax_mode) begin
      if (coll_col_cnt + 8'd1 >= tile_n_r) begin
        coll_col_cnt <= '0;
        coll_row_cnt <= coll_row_cnt + 8'd1;
      end else begin
        coll_col_cnt <= coll_col_cnt + 8'd1;
      end
    end
  end

  // ==========================================================
  // Stage 3b: Softmax path
  //   Feed c_out rows in parallel (one row/cycle for tile_m cycles).
  //   Capture probs_out rows after SOFTMAX_LAT into a 2D buffer.
  //   Walk the buffer out one element/cycle.
  // ==========================================================
  logic [15:0] sm_in_offset, sm_capture_offset;
  assign sm_in_offset      = cycle_cnt - output_start;
  assign sm_capture_offset = cycle_cnt - sm_capture_start;

  // ---- Softmax feed: ready-gated, counter-driven ----
  // Backpressure (M7-fix): the divider can't keep up with 1 row/cycle, so
  // we throttle the feed using softmax_unit_lut.ready. sm_in_row_r is the
  // index of the row we're trying to feed; it advances ONLY when the
  // handshake fires (sm_in_valid && sm_ready). Replaces the original
  // cycle-window scheme that silently dropped 56/64 rows.
  logic       sm_in_valid;
  logic [7:0] sm_in_row;
  logic [7:0] sm_in_row_r;
  logic       sm_feed_phase;
  logic       sm_ready;          // forward-decl; assigned in generate below

  assign sm_feed_phase = softmax_mode && running &&
                         (cycle_cnt >= output_start) &&
                         (sm_in_row_r < tile_m_r);
  assign sm_in_valid   = sm_feed_phase && sm_ready;
  assign sm_in_row     = sm_in_row_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_in_row_r <= 8'd0;
    end else if (start && !running) begin
      sm_in_row_r <= 8'd0;
    end else if (sm_in_valid) begin
      sm_in_row_r <= sm_in_row_r + 8'd1;
    end
  end

  logic signed [31:0] sm_scores_in [ARRAY_DIM];
  logic signed [31:0] sm_probs_out [ARRAY_DIM];
  logic               sm_out_valid;

  genvar gsi;
  generate
    for (gsi = 0; gsi < ARRAY_DIM; gsi++) begin : gen_sm_scores
      assign sm_scores_in[gsi] = sm_in_valid ? c_out_array[sm_in_row[5:0]][gsi]
                                             : 32'sd0;
    end
  endgenerate

  // Softmax-side backpressure: the LUT softmax's internal divider takes
  // ~48 cycles per row, so we MUST throttle the feed or rows get silently
  // dropped (4032/4096 cell failures on tb_stream_pipeline_tile S6).
  // The LUT softmax exposes a ready signal; the Pade variant doesn't, so
  // we tie its ready high (matches the legacy assumption of one row at a
  // time from upstream).
  // (sm_ready forward-declared above with sm_in_valid.)
  generate
    if (USE_LUT_SOFTMAX) begin : g_softmax_lut
      softmax_unit_lut #(
        .DATA_WIDTH (32),
        .VEC_LEN    (ARRAY_DIM)
      ) u_softmax (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .start     (1'b0),
        .vec_len   (tile_n_r),
        .scores_in (sm_scores_in),
        .in_valid  (sm_in_valid),
        .probs_out (sm_probs_out),
        .out_valid (sm_out_valid),
        .ready     (sm_ready)
      );
    end else begin : g_softmax_pade
      softmax_unit #(
        .DATA_WIDTH (32),
        .VEC_LEN    (ARRAY_DIM)
      ) u_softmax (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .start     (1'b0),
        .vec_len   (tile_n_r),
        .scores_in (sm_scores_in),
        .in_valid  (sm_in_valid),
        .probs_out (sm_probs_out),
        .out_valid (sm_out_valid)
      );
      assign sm_ready = 1'b1;
    end
  endgenerate

  // Capture softmax output rows
  // ---- Softmax capture: data-driven on sm_out_valid ----
  // Cycle-window approach can't track backpressured outputs (they arrive
  // at irregular intervals depending on divider state). Count outputs as
  // they fire; index sm_row_buf by the counter.
  logic       sm_capture_active;
  logic [7:0] sm_capture_row;
  logic [7:0] sm_cap_row_r;
  assign sm_capture_active = softmax_mode && running && sm_out_valid;
  assign sm_capture_row    = sm_cap_row_r;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_cap_row_r <= 8'd0;
    end else if (start && !running) begin
      sm_cap_row_r <= 8'd0;
    end else if (sm_capture_active) begin
      sm_cap_row_r <= sm_cap_row_r + 8'd1;
    end
  end

  logic signed [31:0] sm_row_buf [ARRAY_DIM][ARRAY_DIM];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < ARRAY_DIM; r++)
        for (int c = 0; c < ARRAY_DIM; c++)
          sm_row_buf[r][c] <= '0;
    end else if (sm_capture_active) begin
      for (int c = 0; c < ARRAY_DIM; c++)
        sm_row_buf[sm_capture_row[5:0]][c] <= sm_probs_out[c];
    end
  end

  // Walk softmax output buffer out one elem/cycle
  // ---- Softmax walk: data-driven, fires after all rows captured ----
  // Old cycle-window approach assumed captures finished at a fixed time.
  // With backpressure, captures finish at variable times. Gate walk on
  // a sticky "all rows captured" flag + its own walk counter.
  logic       sm_walk_active;
  logic [7:0] sm_walk_row_cnt, sm_walk_col_cnt;
  logic       sm_capture_done_r;
  logic [15:0] sm_walk_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_capture_done_r <= 1'b0;
    end else if (start && !running) begin
      sm_capture_done_r <= 1'b0;
    end else if (sm_capture_active &&
                 (sm_cap_row_r + 8'd1 >= tile_m_r)) begin
      sm_capture_done_r <= 1'b1;
    end
  end

  assign sm_walk_active = softmax_mode && running && sm_capture_done_r &&
                          (sm_walk_cnt < ({8'b0, tile_m_r} *
                                          {8'b0, tile_n_r}));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_walk_cnt <= 16'd0;
    end else if (start && !running) begin
      sm_walk_cnt <= 16'd0;
    end else if (sm_walk_active) begin
      sm_walk_cnt <= sm_walk_cnt + 16'd1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_walk_row_cnt <= '0;
      sm_walk_col_cnt <= '0;
    end else if (start && !running) begin
      sm_walk_row_cnt <= '0;
      sm_walk_col_cnt <= '0;
    end else if (sm_walk_active) begin
      if (sm_walk_col_cnt + 8'd1 >= tile_n_r) begin
        sm_walk_col_cnt <= '0;
        sm_walk_row_cnt <= sm_walk_row_cnt + 8'd1;
      end else begin
        sm_walk_col_cnt <= sm_walk_col_cnt + 8'd1;
      end
    end
  end

  // ==========================================================
  // Stage 4: Output buffer write port — mux between elemwise and softmax
  // ==========================================================
  logic               wr_en_em, wr_en_sm;
  logic [11:0]        wr_idx_em, wr_idx_sm;
  logic signed [31:0] wr_data_em, wr_data_sm;

  assign wr_en_em   = !softmax_mode && fused_valid && running;
  assign wr_idx_em  = {coll_row_cnt[5:0], coll_col_cnt[5:0]};
  assign wr_data_em = fused_out;

  assign wr_en_sm   = sm_walk_active;
  assign wr_idx_sm  = {sm_walk_row_cnt[5:0], sm_walk_col_cnt[5:0]};
  assign wr_data_sm = sm_row_buf[sm_walk_row_cnt[5:0]][sm_walk_col_cnt[5:0]];

  assign out_wr_en   = softmax_mode ? wr_en_sm   : wr_en_em;
  assign out_wr_idx  = softmax_mode ? wr_idx_sm  : wr_idx_em;
  assign out_wr_data = softmax_mode ? wr_data_sm : wr_data_em;

endmodule
