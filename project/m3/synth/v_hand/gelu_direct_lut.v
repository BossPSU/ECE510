/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_direct_lut.v -- hand-flattened from project/RTL/gelu_direct_lut.sv
//
// 256-entry x 32-bit Q16.16 ROM holding GELU(x) for x in [-4, +4).
// Two registered read ports (addr_lo, addr_hi) for adjacent-entry
// linear interpolation in gelu_unit_lut. Contents loaded from
// gelu_lut_direct.mem at $readmemh time.
//
// Hand-flatten conversions:
//   - dropped `import accel_pkg::*`;
//   - `logic` -> wire/reg;
//   - `always_ff @(posedge clk)` -> `always @(posedge clk)`;
//   - both reads in one always block, mirroring exp_lut.v style.
// =============================================================================
module gelu_direct_lut (
    clk,
    addr_lo,
    addr_hi,
    data_lo,
    data_hi
);

    parameter DATA_WIDTH = 32;
    parameter DEPTH      = 256;
    parameter ADDR_W     = 8;

    input  wire                            clk;
    input  wire [ADDR_W-1:0]               addr_lo;
    input  wire [ADDR_W-1:0]               addr_hi;
    output reg  signed [DATA_WIDTH-1:0]    data_lo;
    output reg  signed [DATA_WIDTH-1:0]    data_hi;

    (* rom_style = "block" *) reg signed [DATA_WIDTH-1:0] lut_mem [0:DEPTH-1];

    initial begin
        $readmemh("gelu_lut_direct.mem", lut_mem);
    end

    always @(posedge clk) begin
        data_lo <= lut_mem[addr_lo];
        data_hi <= lut_mem[addr_hi];
    end

endmodule
