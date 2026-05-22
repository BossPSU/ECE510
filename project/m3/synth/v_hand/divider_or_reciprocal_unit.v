/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// divider_or_reciprocal_unit.v -- hand-flattened from
// project/m2/rtl/divider_or_reciprocal_unit.sv
//
// Q16.16 signed division. Two-stage pipeline: register inputs, compute
// quotient as 64-bit num << 16 divided by 32-bit den, register output.
// Synthesis tools (yosys + abc) infer a sequential divider for the `/`
// operator since the divisor is non-constant.
//
// Q_ONE = 32'sh00010000 inlined from accel_pkg (1.0 in Q16.16).
// =============================================================================
module divider_or_reciprocal_unit (
    clk,
    rst_n,
    en,
    numerator,
    denominator,
    in_valid,
    quotient,
    out_valid
);

    parameter DATA_WIDTH = 32;

    localparam [DATA_WIDTH-1:0] Q_ONE = 32'h00010000;

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire signed [DATA_WIDTH-1:0]    numerator;
    input  wire signed [DATA_WIDTH-1:0]    denominator;
    input  wire                            in_valid;
    output reg  signed [DATA_WIDTH-1:0]    quotient;
    output reg                             out_valid;

    // --- Stage 1: register inputs ---
    reg signed [31:0] num_r;
    reg signed [31:0] den_r;
    reg               valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_r   <= 32'h00000000;
            den_r   <= Q_ONE;
            valid_r <= 1'b0;
        end else if (en) begin
            num_r   <= numerator;
            // Guard against divide-by-zero by substituting 1.0
            if (denominator == 32'h00000000)
                den_r <= Q_ONE;
            else
                den_r <= denominator;
            valid_r <= in_valid;
        end
    end

    // --- Stage 2: shift numerator left by FRAC_BITS, divide ---
    // Q16.16 division: (num << 16) / den keeps the result in Q16.16.
    wire signed [63:0] num_ext;
    wire signed [63:0] q_full;
    assign num_ext = $signed({{16{num_r[31]}}, num_r, 16'h0000});
    assign q_full  = num_ext / $signed({{32{den_r[31]}}, den_r});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quotient  <= 32'h00000000;
            out_valid <= 1'b0;
        end else if (en) begin
            out_valid <= valid_r;
            if (valid_r)
                quotient <= q_full[31:0];
        end
    end

endmodule
