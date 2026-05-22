/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_grad_unit.v -- hand-flattened from project/m2/rtl/gelu_grad_unit.sv
//
// gelu'(x) = 0.5*(1+tanh(z)) + 0.5*x*(1-tanh^2(z)) * sqrt(2/pi)*(1+3*0.044715*x^2)
// where z = sqrt(2/pi)*(x + 0.044715*x^3).
// Same Pade tanh + saturation regime as gelu_unit.v.
//
// Verilog-2005 portability: declarations inside always blocks have been
// hoisted to module-scope regs (Verilog 2005 disallows in-block decls).
// =============================================================================
module gelu_grad_unit (
    clk,
    rst_n,
    en,
    x_in,
    in_valid,
    grad_out,
    out_valid
);

    parameter DATA_WIDTH = 32;

    localparam [31:0] Q_ZERO        = 32'h00000000;
    localparam [31:0] Q_ONE         = 32'h00010000;
    localparam [31:0] Q_HALF        = 32'h00008000;
    localparam [31:0] Q_NEG_ONE     = 32'hFFFF0000;
    localparam [31:0] Q_SQRT_2_PI   = 32'h0000CC38;
    localparam [31:0] Q_GELU_C1     = 32'h00000B72;
    localparam [31:0] Q_GELU_C3     = 32'h00002257;
    localparam [31:0] Q_SAT_POS     = 32'h00040000;
    localparam [31:0] Q_SAT_NEG     = 32'hFFFC0000;
    localparam [31:0] Q_27          = 32'h001B0000;
    localparam [31:0] Q_9           = 32'h00090000;
    localparam [31:0] Q_GELU_X_MAX  = 32'h00100000;
    localparam [31:0] Q_GELU_X_MIN  = 32'hFFF00000;

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire signed [DATA_WIDTH-1:0]    x_in;
    input  wire                            in_valid;
    output reg  signed [DATA_WIDTH-1:0]    grad_out;
    output reg                             out_valid;

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

    // Clamp polynomial input to +/-16
    reg signed [31:0] x_for_poly;
    always @* begin
        if (x_in > $signed(Q_GELU_X_MAX))
            x_for_poly = Q_GELU_X_MAX;
        else if (x_in < $signed(Q_GELU_X_MIN))
            x_for_poly = Q_GELU_X_MIN;
        else
            x_for_poly = x_in;
    end

    // Stage 1
    reg signed [31:0] s1_x, s1_xp, s1_x2, s1_x3;
    reg               s1_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_x  <= 32'h0; s1_xp <= 32'h0; s1_x2 <= 32'h0; s1_x3 <= 32'h0;
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

    // Stage 2
    reg signed [31:0] s2_x, s2_z, s2_inner_pre;
    reg               s2_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_x <= 32'h0; s2_z <= 32'h0; s2_inner_pre <= 32'h0;
        end else if (en) begin
            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_x         <= s1_x;
                s2_z         <= q_mul(Q_SQRT_2_PI,
                                      s1_xp + q_mul(Q_GELU_C1, s1_x3));
                s2_inner_pre <= Q_ONE + q_mul(Q_GELU_C3, s1_x2);
            end
        end
    end

    // Stage 3
    reg signed [31:0] s3_x, s3_z, s3_z2, s3_inner;
    reg               s3_valid;
    reg               s3_sat_pos;
    reg               s3_sat_neg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_x <= 32'h0; s3_z <= 32'h0; s3_z2 <= 32'h0; s3_inner <= 32'h0;
            s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b0;
        end else if (en) begin
            s3_valid <= s2_valid;
            if (s2_valid) begin
                s3_x     <= s2_x;
                s3_inner <= q_mul(Q_SQRT_2_PI, s2_inner_pre);
                if (s2_z > $signed(Q_SAT_POS)) begin
                    s3_z <= Q_SAT_POS;
                    s3_sat_pos <= 1'b1; s3_sat_neg <= 1'b0;
                end else if (s2_z < $signed(Q_SAT_NEG)) begin
                    s3_z <= Q_SAT_NEG;
                    s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b1;
                end else begin
                    s3_z <= s2_z;
                    s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b0;
                end
                s3_z2 <= q_mul(s2_z, s2_z);
            end
        end
    end

    // Stage 4
    reg signed [31:0] s4_x, s4_num, s4_den, s4_inner;
    reg               s4_valid;
    reg               s4_sat_pos;
    reg               s4_sat_neg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_valid <= 1'b0;
            s4_x <= 32'h0; s4_num <= 32'h0; s4_den <= Q_ONE; s4_inner <= 32'h0;
            s4_sat_pos <= 1'b0; s4_sat_neg <= 1'b0;
        end else if (en) begin
            s4_valid <= s3_valid;
            if (s3_valid) begin
                s4_x     <= s3_x;
                s4_inner <= s3_inner;
                s4_num   <= q_mul(s3_z, Q_27 + s3_z2);
                s4_den   <= Q_27 + q_mul(Q_9, s3_z2);
                s4_sat_pos <= s3_sat_pos;
                s4_sat_neg <= s3_sat_neg;
            end
        end
    end

    // Stage 5: tanh, dtanh = 1 - tanh^2
    reg signed [31:0] s5_x, s5_tanh, s5_dtanh, s5_inner;
    reg               s5_valid;
    reg signed [31:0] tanh_val; // hoisted from always-block local in SV
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_valid <= 1'b0;
            s5_x <= 32'h0; s5_tanh <= 32'h0; s5_dtanh <= 32'h0; s5_inner <= 32'h0;
        end else if (en) begin
            s5_valid <= s4_valid;
            if (s4_valid) begin
                s5_x     <= s4_x;
                s5_inner <= s4_inner;
                if (s4_sat_pos)
                    tanh_val = Q_ONE;
                else if (s4_sat_neg)
                    tanh_val = Q_NEG_ONE;
                else
                    tanh_val = q_div(s4_num, s4_den);
                s5_tanh  <= tanh_val;
                s5_dtanh <= Q_ONE - q_mul(tanh_val, tanh_val);
            end
        end
    end

    // Stage 6: grad = 0.5*(1+tanh) + 0.5*x*dtanh*inner
    reg signed [31:0] term1; // hoisted from in-block local in SV
    reg signed [31:0] term2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            grad_out  <= 32'h0;
        end else if (en) begin
            out_valid <= s5_valid;
            if (s5_valid) begin
                term1 = q_mul(Q_HALF, Q_ONE + s5_tanh);
                term2 = q_mul(Q_HALF,
                              q_mul(s5_x, q_mul(s5_dtanh, s5_inner)));
                grad_out <= term1 + term2;
            end
        end
    end

endmodule
