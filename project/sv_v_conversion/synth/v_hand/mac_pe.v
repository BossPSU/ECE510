/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// mac_pe.v -- hand-flattened from project/RTL/mac_pe.sv  (the M3 mixed-
// precision variant; 8x8 Q4.4 multiplier feeding a Q16.16 accumulator).
//
// Why this replaces the earlier Q16.16-only mac_pe.v in this folder: the
// project/m2/rtl/mac_pe.sv I initially flattened uses a 32x32 multiplier,
// which yosys lowers to a Brent-Kung tree that blew WSL2's memory limit
// during synthesis. The M3 chip-scale RTL uses Q4.4 inputs with an
// 8x8 multiplier (16x smaller area), matching the cf07 leaf OpenLane run
// (1,482 cells per PE). That fits in OpenLane.
//
// Per-PE precision policy (matches project/RTL/mac_pe.sv):
//   * a_in / b_in / a_out / b_out are Q16.16 across module boundaries
//     so the systolic feed stays at full precision.
//   * Each operand is shifted right by 12 then saturated to 8-bit signed
//     immediately before the multiplier (Q4.4 quantize).
//   * The 8x8 -> 16-bit Q8.8 product is sign-extended and left-shifted
//     by 8 into Q16.16 for accumulation. Accumulator keeps full headroom.
// =============================================================================
module mac_pe (
    clk,
    rst_n,
    en,
    clear_acc,
    a_in,
    a_out,
    b_in,
    b_out,
    acc_out
);

    parameter DATA_WIDTH = 32;

    // Inlined accel_pkg constants
    localparam MULT_W         = 8;                    // multiplier width
    localparam MULT_FRAC      = 4;                    // Q4.4 fractional bits
    localparam FRAC_BITS      = 16;                   // Q16.16 fractional bits
    localparam Q44_ALIGN_SH   = FRAC_BITS - MULT_FRAC;     // 12
    localparam Q88_PROMOTE_SH = FRAC_BITS - 2*MULT_FRAC;   //  8

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire                            clear_acc;

    input  wire signed [DATA_WIDTH-1:0]    a_in;
    output reg  signed [DATA_WIDTH-1:0]    a_out;

    input  wire signed [DATA_WIDTH-1:0]    b_in;
    output reg  signed [DATA_WIDTH-1:0]    b_out;

    output wire signed [DATA_WIDTH-1:0]    acc_out;

    // Q16.16 -> Q4.4 with saturation on the 8-bit signed range
    wire signed [DATA_WIDTH-1:0] a_shifted;
    wire signed [DATA_WIDTH-1:0] b_shifted;
    wire signed [MULT_W-1:0]     a_q44;
    wire signed [MULT_W-1:0]     b_q44;

    assign a_shifted = a_in >>> Q44_ALIGN_SH;
    assign b_shifted = b_in >>> Q44_ALIGN_SH;

    assign a_q44 = (a_shifted >  32'sd127) ?  8'sd127 :
                   (a_shifted < -32'sd128) ? -8'sd128 :
                                              a_shifted[MULT_W-1:0];
    assign b_q44 = (b_shifted >  32'sd127) ?  8'sd127 :
                   (b_shifted < -32'sd128) ? -8'sd128 :
                                              b_shifted[MULT_W-1:0];

    // 8x8 -> 16-bit Q8.8 multiply -- the small one that makes this fit in
    // OpenLane.
    wire signed [2*MULT_W-1:0] product_q88;
    assign product_q88 = a_q44 * b_q44;

    // Promote Q8.8 -> Q16.16 (sign-extend + shift left 8)
    wire signed [DATA_WIDTH-1:0] product_q;
    assign product_q = {
        { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88[2*MULT_W-1]} },
        product_q88,
        { Q88_PROMOTE_SH{1'b0} }
    };

    // Accumulator + west/north forwarding registers
    reg signed [DATA_WIDTH-1:0] acc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            acc_r <= {DATA_WIDTH{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clear_acc)
                acc_r <= {DATA_WIDTH{1'b0}};
            else
                acc_r <= acc_r + product_q;
        end
    end

    assign acc_out = acc_r;

endmodule
