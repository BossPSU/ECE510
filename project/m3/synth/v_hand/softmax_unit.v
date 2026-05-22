/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// softmax_unit.v -- hand-flattened from project/m2/rtl/softmax_unit.sv
//
// 4-stage pipelined Q16.16 softmax:
//   stage 1: latch scores + find row max
//   stage 2: per-element exp(score - max) via Pade(x/4)^4
//   stage 3: sum exps
//   stage 4: divide once (1/sum) then multiply across the row
//
// Conversions:
//   - scores_in / probs_out unpacked-array ports -> packed
//     [(VEC_LEN*DATA_WIDTH)-1:0] buses, sliced inside as needed;
//   - internal per-slot arrays kept as 1D memory arrays;
//   - all in-block `logic` decls hoisted to module scope (Verilog 2005);
//   - q_mul/q_div inlined as functions; q_exp_approx ditto;
//   - Q16.16 constants from accel_pkg inlined as localparams.
// =============================================================================
module softmax_unit (
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

    parameter DATA_WIDTH = 32;
    parameter VEC_LEN    = 64;

    localparam [31:0] Q_ZERO       = 32'h00000000;
    localparam [31:0] Q_ONE        = 32'h00010000;
    localparam [31:0] Q_TWELVE     = 32'h000C0000;
    localparam [31:0] Q_SIX        = 32'h00060000;
    localparam [31:0] Q_EXP_FLOOR  = 32'hFFF00000;

    input  wire                                  clk;
    input  wire                                  rst_n;
    input  wire                                  en;
    input  wire                                  start;
    input  wire [7:0]                            vec_len;
    input  wire [(VEC_LEN*DATA_WIDTH)-1:0]       scores_in;
    input  wire                                  in_valid;
    output reg  [(VEC_LEN*DATA_WIDTH)-1:0]       probs_out;
    output reg                                   out_valid;

    // Suppress unused-port warning for start (kept for SV-API parity).
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

    function signed [31:0] q_div;
        input signed [31:0] num;
        input signed [31:0] den;
        reg signed [63:0] num_ext;
        reg signed [63:0] result;
        begin
            if (den == 32'h00000000) begin
                q_div = Q_ZERO;
            end else begin
                num_ext = $signed({{16{num[31]}}, num, 16'h0000});
                result  = num_ext / $signed({{32{den[31]}}, den});
                q_div   = result[31:0];
            end
        end
    endfunction

    // Pade(x/4)^4 exp approximation for x in [-16, 0]; clamps elsewhere.
    function signed [31:0] q_exp_approx;
        input signed [31:0] x;
        reg signed [31:0] y, y2, num, den, p, p2, p4;
        reg signed [63:0] num_ext, q_full;
        begin
            if (x >= $signed(Q_ZERO)) begin
                q_exp_approx = Q_ONE;
            end else if (x < $signed(Q_EXP_FLOOR)) begin
                q_exp_approx = Q_ZERO;
            end else begin
                y  = x >>> 2;
                y2 = q_mul(y, y);
                num = $signed(Q_TWELVE) + q_mul(Q_SIX, y) + y2;
                den = $signed(Q_TWELVE) - q_mul(Q_SIX, y) + y2;
                if (den <= 0) begin
                    q_exp_approx = Q_ZERO;
                end else begin
                    num_ext = $signed({{16{num[31]}}, num, 16'h0000});
                    q_full  = num_ext / $signed({{32{den[31]}}, den});
                    if (q_full[31] == 1'b1) begin
                        q_exp_approx = Q_ZERO;
                    end else begin
                        p  = q_full[31:0];
                        p2 = q_mul(p, p);
                        p4 = q_mul(p2, p2);
                        q_exp_approx = p4;
                    end
                end
            end
        end
    endfunction

    // ------- pipeline state ------------------------------------------
    reg s1_valid, s2_valid, s3_valid;
    reg [7:0] s1_len, s2_len, s3_len;

    // Stage-1 latched scores + the row max.
    reg signed [31:0] s1_scores [0:VEC_LEN-1];
    reg signed [31:0] s1_max;

    // Stage-2 exps.
    reg signed [31:0] s2_exp [0:VEC_LEN-1];

    // Stage-3 exps + their sum.
    reg signed [31:0] s3_exp [0:VEC_LEN-1];
    reg signed [31:0] s3_sum;

    integer i;
    reg signed [31:0] mx;
    reg signed [31:0] diff;
    reg signed [31:0] acc;
    reg signed [31:0] recip;

    // ===== Stage 1: latch + max-reduce =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_max   <= 32'h0;
            s1_len   <= 8'd0;
            for (i = 0; i < VEC_LEN; i = i + 1)
                s1_scores[i] <= 32'h0;
        end else if (en && in_valid) begin
            s1_valid <= 1'b1;
            s1_len   <= vec_len;
            mx = $signed(scores_in[0 +: DATA_WIDTH]);
            s1_scores[0] <= $signed(scores_in[0 +: DATA_WIDTH]);
            for (i = 1; i < VEC_LEN; i = i + 1) begin
                if ((i < vec_len) &&
                    ($signed(scores_in[(i*DATA_WIDTH) +: DATA_WIDTH]) > mx))
                    mx = $signed(scores_in[(i*DATA_WIDTH) +: DATA_WIDTH]);
                s1_scores[i] <=
                    $signed(scores_in[(i*DATA_WIDTH) +: DATA_WIDTH]);
            end
            s1_max <= mx;
        end else if (en) begin
            s1_valid <= 1'b0;
        end
    end

    // ===== Stage 2: subtract max, apply exp approx =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_len   <= 8'd0;
            for (i = 0; i < VEC_LEN; i = i + 1)
                s2_exp[i] <= 32'h0;
        end else if (en) begin
            s2_valid <= s1_valid;
            s2_len   <= s1_len;
            if (s1_valid) begin
                for (i = 0; i < VEC_LEN; i = i + 1) begin
                    diff = s1_scores[i] - s1_max;
                    if (i < s1_len)
                        s2_exp[i] <= q_exp_approx(diff);
                    else
                        s2_exp[i] <= 32'h0;
                end
            end
        end
    end

    // ===== Stage 3: sum exps =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_sum   <= 32'h0;
            s3_len   <= 8'd0;
            for (i = 0; i < VEC_LEN; i = i + 1)
                s3_exp[i] <= 32'h0;
        end else if (en) begin
            s3_valid <= s2_valid;
            s3_len   <= s2_len;
            if (s2_valid) begin
                acc = 32'h0;
                for (i = 0; i < VEC_LEN; i = i + 1) begin
                    if (i < s2_len)
                        acc = acc + s2_exp[i];
                    s3_exp[i] <= s2_exp[i];
                end
                s3_sum <= acc;
            end
        end
    end

    // ===== Stage 4: 1/sum * exp ===== (one divider, VEC_LEN multipliers)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            probs_out <= {(VEC_LEN*DATA_WIDTH){1'b0}};
        end else if (en) begin
            out_valid <= s3_valid;
            if (s3_valid) begin
                if (s3_sum > 32'sh00000000) begin
                    recip = q_div(Q_ONE, s3_sum);
                    for (i = 0; i < VEC_LEN; i = i + 1) begin
                        if (i < s3_len)
                            probs_out[(i*DATA_WIDTH) +: DATA_WIDTH]
                                <= q_mul(s3_exp[i], recip);
                        else
                            probs_out[(i*DATA_WIDTH) +: DATA_WIDTH]
                                <= 32'h0;
                    end
                end else begin
                    // Uniform-fallback: probs = 1/N for all active slots.
                    if (s3_len == 8'd0)
                        recip = 32'h0;
                    else
                        recip = q_div(Q_ONE, {8'd0, s3_len, 16'd0});
                    for (i = 0; i < VEC_LEN; i = i + 1) begin
                        if (i < s3_len)
                            probs_out[(i*DATA_WIDTH) +: DATA_WIDTH] <= recip;
                        else
                            probs_out[(i*DATA_WIDTH) +: DATA_WIDTH]
                                <= 32'h0;
                    end
                end
            end
        end
    end

endmodule
