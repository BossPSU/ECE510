/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_grad_unit_lut.v -- hand-flattened from project/RTL/gelu_grad_unit_lut.sv
//
// Drop-in port-compatible replacement for gelu_grad_unit.v. Same
// architecture as gelu_unit_lut: 256-entry direct GELU'(x) ROM with
// adjacent-entry linear interpolation; 3-cycle pipeline.
//
// Saturation tails: x > +4 -> 1.0, x < -4 -> 0.0.
// =============================================================================
module gelu_grad_unit_lut (
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
    localparam [31:0] Q_FOUR        = 32'h00040000;
    localparam [31:0] Q_NEG_FOUR    = 32'hFFFC0000;
    localparam [31:0] Q_FOUR_MINUS1 = 32'h0003FFFF;

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

    reg signed [31:0] clamped;
    reg        [31:0] shifted;
    reg        [7:0]  addr_lo_w;
    reg signed [31:0] diff;
    reg signed [31:0] delta;
    reg signed [31:0] interp;

    // ===== Stage 1: clamp, address gen, fractional position =====
    reg               s1_valid;
    reg [7:0]         s1_addr_lo;
    reg [7:0]         s1_addr_hi;
    reg signed [31:0] s1_frac_q16;
    reg               s1_sat_pos;
    reg               s1_sat_neg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid    <= 1'b0;
            s1_addr_lo  <= 8'd0;
            s1_addr_hi  <= 8'd0;
            s1_frac_q16 <= 32'h0;
            s1_sat_pos  <= 1'b0;
            s1_sat_neg  <= 1'b0;
        end else if (en) begin
            s1_valid <= in_valid;
            if (in_valid) begin
                s1_sat_pos <= ($signed(x_in) > $signed(Q_FOUR));
                s1_sat_neg <= ($signed(x_in) < $signed(Q_NEG_FOUR));

                if ($signed(x_in) > $signed(Q_FOUR_MINUS1))
                    clamped = $signed(Q_FOUR_MINUS1);
                else if ($signed(x_in) < $signed(Q_NEG_FOUR))
                    clamped = $signed(Q_NEG_FOUR);
                else
                    clamped = x_in;

                shifted    = clamped + Q_FOUR;
                addr_lo_w  = shifted[18:11];
                s1_addr_lo <= addr_lo_w;
                s1_addr_hi <= (addr_lo_w == 8'd255) ? 8'd255
                                                    : (addr_lo_w + 8'd1);
                s1_frac_q16 <= {16'h0000, shifted[10:0], 5'h00};
            end
        end
    end

    // ===== Stage 2: LUT registered read + carry forwarded signals =====
    reg               s2_valid;
    reg signed [31:0] s2_frac_q16;
    reg               s2_sat_pos;
    reg               s2_sat_neg;
    wire signed [DATA_WIDTH-1:0] s2_data_lo;
    wire signed [DATA_WIDTH-1:0] s2_data_hi;

    gelu_grad_direct_lut #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_lut (
        .clk     (clk),
        .addr_lo (s1_addr_lo),
        .addr_hi (s1_addr_hi),
        .data_lo (s2_data_lo),
        .data_hi (s2_data_hi)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid    <= 1'b0;
            s2_frac_q16 <= 32'h0;
            s2_sat_pos  <= 1'b0;
            s2_sat_neg  <= 1'b0;
        end else if (en) begin
            s2_valid    <= s1_valid;
            s2_frac_q16 <= s1_frac_q16;
            s2_sat_pos  <= s1_sat_pos;
            s2_sat_neg  <= s1_sat_neg;
        end
    end

    // ===== Stage 3: linear interp + saturation override =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            grad_out  <= 32'h0;
        end else if (en) begin
            out_valid <= s2_valid;
            if (s2_valid) begin
                diff   = s2_data_hi - s2_data_lo;
                delta  = q_mul(diff, s2_frac_q16);
                interp = s2_data_lo + delta;
                if (s2_sat_pos)
                    grad_out <= Q_ONE;
                else if (s2_sat_neg)
                    grad_out <= Q_ZERO;
                else
                    grad_out <= interp;
            end
        end
    end

endmodule
