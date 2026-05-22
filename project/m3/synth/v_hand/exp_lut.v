/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// exp_lut.v -- hand-flattened Verilog 2005 of project/m2/rtl/exp_lut.sv
//
// 256-entry x 32-bit Q16.16 ROM for e^x on input range [-8, 0]. Contents
// loaded from exp_lut.mem (must be alongside this file at synth time).
//
// Conversions:
//   - dropped `import accel_pkg::*`; LUT_DEPTH=256, LUT_ADDR_W=8 inlined as
//     parameter defaults.
//   - `logic` -> wire/reg.
//   - (* rom_style = "block" *) attribute kept; yosys ignores unknown attrs
//     and the synthesis tool (OpenROAD on Sky130A) can hint memory inference.
//   - `always_ff` -> `always @(posedge clk)`.
// =============================================================================
module exp_lut (
    clk,
    addr,
    data
);

    parameter DATA_WIDTH = 32;
    parameter DEPTH      = 256;
    parameter ADDR_W     = 8;

    input  wire                            clk;
    input  wire [ADDR_W-1:0]               addr;
    output reg  signed [DATA_WIDTH-1:0]    data;

    (* rom_style = "block" *) reg signed [DATA_WIDTH-1:0] lut_mem [0:DEPTH-1];

    initial begin
        $readmemh("exp_lut.mem", lut_mem);
    end

    always @(posedge clk) begin
        data <= lut_mem[addr];
    end

endmodule
