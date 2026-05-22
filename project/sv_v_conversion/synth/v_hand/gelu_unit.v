/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_unit.v -- hand-flattened from project/m2/rtl/gelu_unit.sv
//
// GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
// tanh approximated as Pade: tanh(z) ~= z*(27+z^2)/(27+9*z^2), saturated.
// Pipelined 6 stages.
//
// Conversions:
//   - inlined Q16.16 constants from accel_pkg as localparams;
//   - inlined q_mul / q_div as local functions;
//   - `logic` -> `wire`/`reg`, `always_ff` -> `always`;
//   - `return ...` removed from functions (Verilog 2005 uses bare assignment).
// =============================================================================
module gelu_unit (
    clk,
    rst_n,
    en,
    x_in,
    in_valid,
    y_out,
    out_valid
);

    parameter DATA_WIDTH = 32;

    // Q16.16 constants (from accel_pkg, no `signed` attribute -- yosys
    // handles signedness inside the q_mul/q_div helpers via $signed casts).
    localparam [31:0] Q_ZERO        = 32'h00000000;
    localparam [31:0] Q_ONE         = 32'h00010000;
    localparam [31:0] Q_HALF        = 32'h00008000;
    localparam [31:0] Q_NEG_ONE     = 32'hFFFF0000;
    localparam [31:0] Q_SQRT_2_PI   = 32'h0000CC38;
    localparam [31:0] Q_GELU_C1     = 32'h00000B72;
    localparam [31:0] Q_SAT_POS     = 32'h00040000; // +4.0
    localparam [31:0] Q_SAT_NEG     = 32'hFFFC0000; // -4.0
    localparam [31:0] Q_27          = 32'h001B0000;
    localparam [31:0] Q_9           = 32'h00090000;
    localparam [31:0] Q_GELU_X_MAX  = 32'h00100000; // +16.0
    localparam [31:0] Q_GELU_X_MIN  = 32'hFFF00000; // -16.0

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire signed [DATA_WIDTH-1:0]    x_in;
    input  wire                            in_valid;
    output reg  signed [DATA_WIDTH-1:0]    y_out;
    output reg                             out_valid;

    // -------------------------------------------------------------------
    // q_mul / q_div helpers (Q16.16 * Q16.16 -> Q16.16; division shifts
    // numerator left by 16 to preserve fractional precision).
    // -------------------------------------------------------------------
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

    // -------------------------------------------------------------------
    // Pre-stage: clamp polynomial input to +/-16 to keep x^3 in Q16.16.
    // -------------------------------------------------------------------
    reg signed [31:0] x_for_poly;
    always @* begin
        if (x_in > $signed(Q_GELU_X_MAX))
            x_for_poly = Q_GELU_X_MAX;
        else if (x_in < $signed(Q_GELU_X_MIN))
            x_for_poly = Q_GELU_X_MIN;
        else
            x_for_poly = x_in;
    end

    // Stage 1: x, clamped x, x^2, x^3
    reg signed [31:0] s1_x, s1_xp, s1_x2, s1_x3;
    reg               s1_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_x     <= 32'h0;
            s1_xp    <= 32'h0;
            s1_x2    <= 32'h0;
            s1_x3    <= 32'h0;
        end else if (en) begin
            s1_valid <= in_valid;
            if (in_valid) begin
                s1_x  <= x_in;
                s1_xp <= x_for_poly;
                s1_x2 <= q_mul(x_for_poly, x_for_poly);
                s1_x3 <= q_mul(q_mul(x_for_poly, x_for_poly), x_for_poly);
            end
        end
    end

    // Stage 2: z = sqrt(2/pi) * (x_clamped + 0.044715 * x^3)
    reg signed [31:0] s2_x, s2_z;
    reg               s2_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_x     <= 32'h0;
            s2_z     <= 32'h0;
        end else if (en) begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_x <= s1_x;
                s2_z <= q_mul(Q_SQRT_2_PI,
                              s1_xp + q_mul(Q_GELU_C1, s1_x3));
            end
        end
    end

    // Stage 3: clamp z to +/-4, compute z^2
    reg signed [31:0] s3_x, s3_z, s3_z2;
    reg               s3_valid;
    reg               s3_saturate_pos;
    reg               s3_saturate_neg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_x     <= 32'h0;
            s3_z     <= 32'h0;
            s3_z2    <= 32'h0;
            s3_saturate_pos <= 1'b0;
            s3_saturate_neg <= 1'b0;
        end else if (en) begin
            s3_valid <= s2_valid;
            if (s2_valid) begin
                s3_x <= s2_x;
                if (s2_z > $signed(Q_SAT_POS)) begin
                    s3_z <= Q_SAT_POS;
                    s3_saturate_pos <= 1'b1;
                    s3_saturate_neg <= 1'b0;
                end else if (s2_z < $signed(Q_SAT_NEG)) begin
                    s3_z <= Q_SAT_NEG;
                    s3_saturate_pos <= 1'b0;
                    s3_saturate_neg <= 1'b1;
                end else begin
                    s3_z <= s2_z;
                    s3_saturate_pos <= 1'b0;
                    s3_saturate_neg <= 1'b0;
                end
                s3_z2 <= q_mul(s2_z, s2_z);
            end
        end
    end

    // Stage 4: num = z*(27+z^2), den = 27 + 9*z^2
    reg signed [31:0] s4_x, s4_num, s4_den;
    reg               s4_valid;
    reg               s4_sat_pos;
    reg               s4_sat_neg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_valid <= 1'b0;
            s4_x     <= 32'h0;
            s4_num   <= 32'h0;
            s4_den   <= Q_ONE;
            s4_sat_pos <= 1'b0;
            s4_sat_neg <= 1'b0;
        end else if (en) begin
            s4_valid <= s3_valid;
            if (s3_valid) begin
                s4_x   <= s3_x;
                s4_num <= q_mul(s3_z, Q_27 + s3_z2);
                s4_den <= Q_27 + q_mul(Q_9, s3_z2);
                s4_sat_pos <= s3_saturate_pos;
                s4_sat_neg <= s3_saturate_neg;
            end
        end
    end

    // Stage 5: tanh = num/den (or saturated +/-1)
    reg signed [31:0] s5_x, s5_tanh;
    reg               s5_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_valid <= 1'b0;
            s5_x     <= 32'h0;
            s5_tanh  <= 32'h0;
        end else if (en) begin
            s5_valid <= s4_valid;
            if (s4_valid) begin
                s5_x <= s4_x;
                if (s4_sat_pos)
                    s5_tanh <= Q_ONE;
                else if (s4_sat_neg)
                    s5_tanh <= Q_NEG_ONE;
                else
                    s5_tanh <= q_div(s4_num, s4_den);
            end
        end
    end

    // Stage 6: y = 0.5 * x * (1 + tanh)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            y_out     <= 32'h0;
        end else if (en) begin
            out_valid <= s5_valid;
            if (s5_valid)
                y_out <= q_mul(Q_HALF, q_mul(s5_x, Q_ONE + s5_tanh));
        end
    end

endmodule
