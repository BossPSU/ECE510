/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_lut.v -- hand-flattened Verilog 2005 of project/m2/rtl/gelu_lut.sv
// 256-entry tanh ROM (Q16.16) for input range [-4, 4]. Identical pattern
// to exp_lut.v; only mem-file path differs.
// =============================================================================
module gelu_lut (
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
        $readmemh("gelu_tanh_lut.mem", lut_mem);
    end

    always @(posedge clk) begin
        data <= lut_mem[addr];
    end

endmodule
