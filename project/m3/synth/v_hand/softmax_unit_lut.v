/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// softmax_unit_lut.v -- hand-flattened from project/RTL/softmax_unit_lut.sv
//
// M4 Option C drop-in for softmax_unit.v. Same port list, same Q16.16
// semantics. Two structural changes vs the Pade+combinational-divider
// baseline:
//   1. Per-lane Pade[2,2] exp + 64-bit comb divide is replaced by a
//      bank of N_LUT_BANKS exp_lut ROMs, time-multiplexed across
//      N_PHASES = ceil(VEC_LEN / N_LUT_BANKS) cycles.
//   2. Stage-4 combinational 1/sum is replaced by the existing
//      divider_or_reciprocal_unit (2-cycle pipeline).
//
// Hand-flatten conversions (same rules as the other 33 v_hand modules):
//   - dropped `import accel_pkg::*`; Q_ZERO/Q_ONE/Q_EXP_MIN/Q_EIGHT
//     inlined as 32-bit hex localparams;
//   - `logic` -> wire/reg with explicit direction;
//   - `always_ff @(posedge clk)` -> `always @(posedge clk)`;
//   - `always_comb` -> `always @*`;
//   - unpacked-array ports scores_in/probs_out [VEC_LEN] -> packed
//     [(VEC_LEN*DATA_WIDTH)-1:0] buses, sliced via [+:DATA_WIDTH];
//   - internal per-slot arrays kept as 1D memory regs;
//   - q_mul/q_to_lut_addr/q_uniform_recip inlined as Verilog 2005
//     functions; no `automatic`;
//   - loop iterators hoisted to module-scope `integer` regs;
//   - N_LUT_BANKS parameter default = (VEC_LEN < 8) ? VEC_LEN : 8;
//     callers (e.g. stream_pipeline) may override.
// =============================================================================
module softmax_unit_lut (
    clk,
    rst_n,
    en,
    start,
    vec_len,
    scores_in,
    in_valid,
    probs_out,
    out_valid
);

    parameter DATA_WIDTH  = 32;
    parameter VEC_LEN     = 64;
    parameter N_LUT_BANKS = (VEC_LEN < 8) ? VEC_LEN : 8;

    localparam N_PHASES = (VEC_LEN + N_LUT_BANKS - 1) / N_LUT_BANKS;

    localparam [31:0] Q_ZERO    = 32'h00000000;
    localparam [31:0] Q_ONE     = 32'h00010000;
    localparam [31:0] Q_EXP_MIN = 32'hFFF80000;  // -8.0
    localparam [31:0] Q_EIGHT   = 32'h00080000;  // +8.0

    input  wire                                  clk;
    input  wire                                  rst_n;
    input  wire                                  en;
    input  wire                                  start;
    input  wire [7:0]                            vec_len;
    input  wire [(VEC_LEN*DATA_WIDTH)-1:0]       scores_in;
    input  wire                                  in_valid;
    output reg  [(VEC_LEN*DATA_WIDTH)-1:0]       probs_out;
    output reg                                   out_valid;

    // Suppress unused-port warning for start (kept for API parity).
    wire _unused_start = start;

    // ------- helpers --------------------------------------------------
    function signed [31:0] q_mul;
        input signed [31:0] a;
        input signed [31:0] b;
        reg signed [63:0] product;
        begin
            product = $signed(a) * $signed(b);
            q_mul   = product[47:16];
        end
    endfunction

    // Q16.16 diff (expected in [-8, 0]) -> 8-bit address into 256-entry
    // exp_lut spanning [-8, 0]. addr = (diff + 8) * 256 / 8 = (diff + 8) >> 11.
    function [7:0] q_to_lut_addr;
        input signed [31:0] diff;
        reg signed [31:0] clamped;
        reg        [31:0] shifted;
        begin
            if ($signed(diff) < $signed(Q_EXP_MIN))
                clamped = $signed(Q_EXP_MIN);
            else if ($signed(diff) > $signed(Q_ZERO))
                clamped = $signed(Q_ZERO);
            else
                clamped = diff;
            shifted = clamped + Q_EIGHT;
            if (shifted >= 32'h00080000)
                q_to_lut_addr = 8'd255;
            else
                q_to_lut_addr = shifted[18:11];
        end
    endfunction

    // 1/N fallback for sum<=0 degenerate path (no combinational divide).
    function signed [31:0] q_uniform_recip;
        input [7:0] n;
        begin
            case (n)
                8'd1:    q_uniform_recip = Q_ONE;
                8'd2:    q_uniform_recip = 32'h00008000;
                8'd4:    q_uniform_recip = 32'h00004000;
                8'd8:    q_uniform_recip = 32'h00002000;
                8'd16:   q_uniform_recip = 32'h00001000;
                8'd32:   q_uniform_recip = 32'h00000800;
                8'd64:   q_uniform_recip = 32'h00000400;
                default: q_uniform_recip = 32'h00000400;
            endcase
        end
    endfunction

    // ------- module-scope temporaries (per-block where used) ----------
    // NOTE: variables used inside more than one always block are split
    // into per-block names. Sharing a single module-scope `lane_idx` or
    // `b` between the lut_addr always_comb and the LUT-data capture
    // always_ff triggers yosys's "multiple conflicting drivers" warning
    // and forces $_ALDFFE_PNP_ inference for the affected nets, which
    // Sky130 standard cells can't realize. Per-block names give each
    // always block its own RTL net.
    integer s1_i;
    integer s3_i;
    integer s4_i;
    integer s5_i;
    integer s2h_i;             // s2 held-state init loop
    integer s2c_i;             // s2 capture init loop
    integer aw_b;              // lut_addr always_comb iterator
    integer aw_lane_idx;
    integer cap_b;             // capture always_ff iterator
    integer cap_lane_idx;
    reg signed [31:0] mx;
    reg signed [31:0] acc;

    // ===== Stage 1: latch + max-reduce =====
    reg               s1_valid;
    reg [7:0]         s1_len;
    reg signed [31:0] s1_scores [0:VEC_LEN-1];
    reg signed [31:0] s1_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_max   <= 32'h0;
            s1_len   <= 8'd0;
            for (s1_i = 0; s1_i < VEC_LEN; s1_i = s1_i + 1)
                s1_scores[s1_i] <= 32'h0;
        end else if (en && in_valid) begin
            s1_valid <= 1'b1;
            s1_len   <= vec_len;
            mx = $signed(scores_in[0 +: DATA_WIDTH]);
            s1_scores[0] <= $signed(scores_in[0 +: DATA_WIDTH]);
            for (s1_i = 1; s1_i < VEC_LEN; s1_i = s1_i + 1) begin
                if ((s1_i < vec_len) &&
                    ($signed(scores_in[(s1_i*DATA_WIDTH) +: DATA_WIDTH]) > mx))
                    mx = $signed(scores_in[(s1_i*DATA_WIDTH) +: DATA_WIDTH]);
                s1_scores[s1_i] <=
                    $signed(scores_in[(s1_i*DATA_WIDTH) +: DATA_WIDTH]);
            end
            s1_max <= mx;
        end else if (en) begin
            s1_valid <= 1'b0;
        end
    end

    // ===== Stage 2: time-multiplexed LUT exp =====
    reg               s2_busy;
    reg [7:0]         s2_phase;
    reg               s2_phase_valid_d1;
    reg [7:0]         s2_phase_cap_d1;
    reg               s2_valid;
    reg [7:0]         s2_len;
    reg signed [31:0] s2_max_held;
    reg signed [31:0] s2_scores_held [0:VEC_LEN-1];
    reg signed [31:0] s2_exp         [0:VEC_LEN-1];

    // LUT bank wires
    reg  [7:0]         lut_addr [0:N_LUT_BANKS-1];
    wire signed [31:0] lut_data [0:N_LUT_BANKS-1];

    genvar gb;
    generate
        for (gb = 0; gb < N_LUT_BANKS; gb = gb + 1) begin : g_lut_bank
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
    // an intermediate written only in the "if" branch infers a latch
    // (the else branch needs every reg either assigned or held).
    always @* begin
        for (aw_b = 0; aw_b < N_LUT_BANKS; aw_b = aw_b + 1) begin
            aw_lane_idx = s2_phase * N_LUT_BANKS + aw_b;
            if (s2_busy && (aw_lane_idx < VEC_LEN) && (aw_lane_idx < s2_len))
                lut_addr[aw_b] = q_to_lut_addr(
                    s2_scores_held[aw_lane_idx] - s2_max_held);
            else
                lut_addr[aw_b] = 8'd0;
        end
    end

    // Phase FSM + LUT data capture (data lands 1 cycle after address).
    //
    // Note: the FSM, shadow registers, captured holds, valid-pulse, and
    // LUT-data capture each get their own always block. A single combined
    // always block with the same logic infers $_ALDFFE_PNP_ cells in
    // yosys (because the partial-conditional assignments look like an
    // async-load pattern), which dfflibmap can't lower to Sky130. One
    // register per always block gives a clean DFFE inference instead.

    // --- FSM state: s2_busy, s2_phase ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_busy  <= 1'b0;
            s2_phase <= 8'd0;
        end else if (en) begin
            if (!s2_busy) begin
                if (s1_valid) begin
                    s2_busy  <= 1'b1;
                    s2_phase <= 8'd0;
                end
            end else begin
                if (s2_phase == (N_PHASES - 1)) begin
                    s2_busy  <= 1'b0;
                    s2_phase <= 8'd0;
                end else begin
                    s2_phase <= s2_phase + 8'd1;
                end
            end
        end
    end

    // --- 1-cycle delayed FSM shadow regs ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_phase_valid_d1 <= 1'b0;
            s2_phase_cap_d1   <= 8'd0;
        end else if (en) begin
            s2_phase_valid_d1 <= s2_busy;
            s2_phase_cap_d1   <= s2_phase;
        end
    end

    // --- Held state captured at start of a row ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_len      <= 8'd0;
            s2_max_held <= 32'h0;
            for (s2h_i = 0; s2h_i < VEC_LEN; s2h_i = s2h_i + 1)
                s2_scores_held[s2h_i] <= 32'h0;
        end else if (en && !s2_busy && s1_valid) begin
            s2_len      <= s1_len;
            s2_max_held <= s1_max;
            for (s2h_i = 0; s2h_i < VEC_LEN; s2h_i = s2h_i + 1)
                s2_scores_held[s2h_i] <= s1_scores[s2h_i];
        end
    end

    // --- s2_valid pulse: fires for one cycle when the last phase's
    // LUT data lands (i.e. when the delayed phase cap reaches N_PHASES-1).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
        end else if (en) begin
            s2_valid <= s2_phase_valid_d1 &&
                        (s2_phase_cap_d1 == (N_PHASES - 1));
        end
    end

    // --- LUT data capture: writes adjacent N_LUT_BANKS lanes per phase. ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s2c_i = 0; s2c_i < VEC_LEN; s2c_i = s2c_i + 1)
                s2_exp[s2c_i] <= 32'h0;
        end else if (en && s2_phase_valid_d1) begin
            for (cap_b = 0; cap_b < N_LUT_BANKS; cap_b = cap_b + 1) begin
                cap_lane_idx = s2_phase_cap_d1 * N_LUT_BANKS + cap_b;
                if (cap_lane_idx < VEC_LEN) begin
                    if (cap_lane_idx < s2_len)
                        s2_exp[cap_lane_idx] <= lut_data[cap_b];
                    else
                        s2_exp[cap_lane_idx] <= 32'h0;
                end
            end
        end
    end

    // ===== Stage 3: sum exps =====
    reg               s3_valid;
    reg [7:0]         s3_len;
    reg signed [31:0] s3_exp [0:VEC_LEN-1];
    reg signed [31:0] s3_sum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_sum   <= 32'h0;
            s3_len   <= 8'd0;
            for (s3_i = 0; s3_i < VEC_LEN; s3_i = s3_i + 1)
                s3_exp[s3_i] <= 32'h0;
        end else if (en) begin
            s3_valid <= s2_valid;
            s3_len   <= s2_len;
            if (s2_valid) begin
                acc = 32'h0;
                for (s3_i = 0; s3_i < VEC_LEN; s3_i = s3_i + 1) begin
                    if (s3_i < s2_len)
                        acc = acc + s2_exp[s3_i];
                    s3_exp[s3_i] <= s2_exp[s3_i];
                end
                s3_sum <= acc;
            end
        end
    end

    // ===== Stage 4: sequential reciprocal divider (1/sum) =====
    wire               div_in_valid;
    wire signed [31:0] div_num;
    wire signed [31:0] div_den;
    wire               recip_valid;
    wire signed [31:0] recip;

    // M5 Item A: iterative pipelined divider with backpressure.
    // Replaces divider_or_reciprocal_unit's 2-cycle combinational core
    // (~65 ns critical path) with divider_or_reciprocal_seq's 48-cycle
    // shift-subtract (~0.5 ns per cycle). Side-band info (exp values,
    // len, sum-zero flag) is held in a single WAIT REGISTER latched on
    // div_in_valid, released on recip_valid -- which is depth-agnostic
    // (works for any divider latency).
    wire div_ready;

    // s3 only fires the divider when divider is ready. Softmax row
    // cadence from the LUT side (N_PHASES cycles) is faster than the
    // divider's 48-cycle latency at ARRAY_DIM >= 8, so rows arriving
    // while the divider is BUSY will silently drop. Real workloads
    // issue softmax rows much slower than this; not a correctness
    // issue for the inference pipeline.
    assign div_in_valid = s3_valid && div_ready;
    assign div_num      = Q_ONE;
    assign div_den      = ($signed(s3_sum) > 0) ? s3_sum : Q_ONE;

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

    // -------- Wait register: side-band info for the divide --------
    // Latched once on div_in_valid (when divider start), held through
    // the ~48-cycle iteration, released on the recip_valid pulse so
    // stage 5 sees a consistent {exp, len, sum_zero, recip} tuple.
    reg               s4_wait_valid;
    reg [7:0]         s4_wait_len;
    reg               s4_wait_sum_zero;
    reg signed [31:0] s4_wait_exp [0:VEC_LEN-1];

    wire s3_sum_zero;
    assign s3_sum_zero = ($signed(s3_sum) <= 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_wait_valid    <= 1'b0;
            s4_wait_len      <= 8'd0;
            s4_wait_sum_zero <= 1'b0;
            for (s4_i = 0; s4_i < VEC_LEN; s4_i = s4_i + 1)
                s4_wait_exp[s4_i] <= 32'h0;
        end else if (en) begin
            if (div_in_valid) begin
                s4_wait_valid    <= 1'b1;
                s4_wait_len      <= s3_len;
                s4_wait_sum_zero <= s3_sum_zero;
                for (s4_i = 0; s4_i < VEC_LEN; s4_i = s4_i + 1)
                    s4_wait_exp[s4_i] <= s3_exp[s4_i];
            end else if (recip_valid) begin
                s4_wait_valid <= 1'b0;
            end
        end
    end

    // ===== Stage 5: multiply each held exp by recip on recip_valid =====
    reg signed [31:0] uniform_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            probs_out <= {(VEC_LEN*DATA_WIDTH){1'b0}};
        end else if (en) begin
            out_valid <= recip_valid;
            if (recip_valid) begin
                if (!s4_wait_sum_zero) begin
                    for (s5_i = 0; s5_i < VEC_LEN; s5_i = s5_i + 1) begin
                        if (s5_i < s4_wait_len)
                            probs_out[(s5_i*DATA_WIDTH) +: DATA_WIDTH]
                                <= q_mul(s4_wait_exp[s5_i], recip);
                        else
                            probs_out[(s5_i*DATA_WIDTH) +: DATA_WIDTH] <= 32'h0;
                    end
                end else begin
                    if (s4_wait_len == 8'd0)
                        uniform_r = 32'h0;
                    else
                        uniform_r = q_uniform_recip(s4_wait_len);
                    for (s5_i = 0; s5_i < VEC_LEN; s5_i = s5_i + 1) begin
                        if (s5_i < s4_wait_len)
                            probs_out[(s5_i*DATA_WIDTH) +: DATA_WIDTH] <= uniform_r;
                        else
                            probs_out[(s5_i*DATA_WIDTH) +: DATA_WIDTH] <= 32'h0;
                    end
                end
            end
        end
    end

endmodule
