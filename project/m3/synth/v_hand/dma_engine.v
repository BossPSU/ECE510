/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// dma_engine.v -- hand-flattened from project/m2/rtl/dma_engine.sv
// Pass-through DMA between UCIe-side host bus and scratchpad SRAM port.
// =============================================================================
module dma_engine (
    clk,
    rst_n,
    host_wr_valid,
    host_wr_addr,
    host_wr_data,
    host_wr_ready,
    host_rd_req,
    host_rd_addr,
    host_rd_data,
    host_rd_valid,
    sram_req,
    sram_we,
    sram_addr,
    sram_wdata,
    sram_rdata,
    sram_rvalid
);

    parameter DATA_WIDTH = 32;
    parameter ADDR_WIDTH = 16;

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    host_wr_valid;
    input  wire [ADDR_WIDTH-1:0]   host_wr_addr;
    input  wire [DATA_WIDTH-1:0]   host_wr_data;
    output wire                    host_wr_ready;
    input  wire                    host_rd_req;
    input  wire [ADDR_WIDTH-1:0]   host_rd_addr;
    output wire [DATA_WIDTH-1:0]   host_rd_data;
    output wire                    host_rd_valid;
    output reg                     sram_req;
    output reg                     sram_we;
    output reg  [ADDR_WIDTH-1:0]   sram_addr;
    output reg  [DATA_WIDTH-1:0]   sram_wdata;
    input  wire [DATA_WIDTH-1:0]   sram_rdata;
    input  wire                    sram_rvalid;

    assign host_wr_ready = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_req   <= 1'b0;
            sram_we    <= 1'b0;
            sram_addr  <= {ADDR_WIDTH{1'b0}};
            sram_wdata <= {DATA_WIDTH{1'b0}};
        end else if (host_wr_valid) begin
            sram_req   <= 1'b1;
            sram_we    <= 1'b1;
            sram_addr  <= host_wr_addr;
            sram_wdata <= host_wr_data;
        end else if (host_rd_req) begin
            sram_req  <= 1'b1;
            sram_we   <= 1'b0;
            sram_addr <= host_rd_addr;
        end else begin
            sram_req <= 1'b0;
            sram_we  <= 1'b0;
        end
    end

    assign host_rd_data  = sram_rdata;
    assign host_rd_valid = sram_rvalid;

endmodule
