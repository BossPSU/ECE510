/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// sram_bank.v -- hand-flattened Verilog 2005 of project/m2/rtl/sram_bank.sv
//
// Single-port behavioral SRAM bank. Synthesis tool infers BRAM (if
// available) or a flop array; yosys+Sky130 without macros will pick the
// flop array. DEPTH defaults inlined to project's SRAM_DEPTH=4096 but
// callers should override for the scope-down build.
// =============================================================================
module sram_bank (
    clk,
    req,
    we,
    addr,
    wdata,
    rdata,
    rvalid
);

    parameter DATA_WIDTH = 32;
    parameter DEPTH      = 4096;
    parameter ADDR_WIDTH = 12;

    input  wire                    clk;
    input  wire                    req;
    input  wire                    we;
    input  wire [ADDR_WIDTH-1:0]   addr;
    input  wire [DATA_WIDTH-1:0]   wdata;
    output reg  [DATA_WIDTH-1:0]   rdata;
    output reg                     rvalid;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        rvalid <= 1'b0;
        if (req) begin
            if (we) begin
                mem[addr] <= wdata;
            end else begin
                rdata  <= mem[addr];
                rvalid <= 1'b1;
            end
        end
    end

endmodule
