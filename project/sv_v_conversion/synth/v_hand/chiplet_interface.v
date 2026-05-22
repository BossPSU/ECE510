/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// chiplet_interface.v -- hand-flattened from project/m2/rtl/interface.sv
//
// UCIe-style protocol adapter. Pure pass-through; only field unpacking and
// fixed bit-routing. macro_cmd_t and cmd_pkt_t are flat buses on both sides.
// =============================================================================
module chiplet_interface #(
    parameter LANE_LOCAL_BITS = 15,
    parameter LANE_BITS       = 4,
    parameter DMA_ADDR_W      = LANE_LOCAL_BITS + LANE_BITS,
    parameter CMD_BUS_W       = 128,
    parameter WR_BUS_W        = DMA_ADDR_W + 32
) (
    clk,
    rst_n,
    ucie_cmd_valid,
    ucie_cmd_ready,
    ucie_cmd_data,
    ucie_wr_valid,
    ucie_wr_ready,
    ucie_wr_data,
    ucie_rd_req,
    ucie_rd_addr,
    ucie_rd_data,
    ucie_rd_valid,
    ucie_irq,
    ucie_busy,
    core_macro_cmd,
    core_macro_cmd_valid,
    core_macro_cmd_ready,
    core_dma_wr_valid,
    core_dma_wr_addr,
    core_dma_wr_data,
    core_dma_wr_ready,
    core_dma_rd_req,
    core_dma_rd_addr,
    core_dma_rd_data,
    core_dma_rd_valid,
    core_busy,
    core_irq
);

    localparam MACRO_W = 107;  // $bits(macro_cmd_t)

    input  wire                  clk;
    input  wire                  rst_n;

    input  wire                  ucie_cmd_valid;
    output wire                  ucie_cmd_ready;
    input  wire [CMD_BUS_W-1:0]  ucie_cmd_data;
    input  wire                  ucie_wr_valid;
    output wire                  ucie_wr_ready;
    input  wire [WR_BUS_W-1:0]   ucie_wr_data;
    input  wire                  ucie_rd_req;
    input  wire [DMA_ADDR_W-1:0] ucie_rd_addr;
    output wire [31:0]           ucie_rd_data;
    output wire                  ucie_rd_valid;
    output wire                  ucie_irq;
    output wire                  ucie_busy;

    output wire [MACRO_W-1:0]    core_macro_cmd;
    output wire                  core_macro_cmd_valid;
    input  wire                  core_macro_cmd_ready;
    output wire                  core_dma_wr_valid;
    output wire [DMA_ADDR_W-1:0] core_dma_wr_addr;
    output wire [31:0]           core_dma_wr_data;
    input  wire                  core_dma_wr_ready;
    output wire                  core_dma_rd_req;
    output wire [DMA_ADDR_W-1:0] core_dma_rd_addr;
    input  wire [31:0]           core_dma_rd_data;
    input  wire                  core_dma_rd_valid;
    input  wire                  core_busy;
    input  wire                  core_irq;

    // Suppress unused-port warnings for clk/rst_n (this module is purely
    // combinational; both signals are wired in for future CDC additions).
    wire _unused_clk   = clk;
    wire _unused_rst_n = rst_n;

    // ---- Command channel: low MACRO_W bits of ucie_cmd_data are the cmd. ----
    assign core_macro_cmd       = ucie_cmd_data[MACRO_W-1:0];
    assign core_macro_cmd_valid = ucie_cmd_valid;
    assign ucie_cmd_ready       = core_macro_cmd_ready;

    // ---- Write channel: {addr[DMA_ADDR_W-1:0], data[31:0]} packed. ----
    assign core_dma_wr_valid = ucie_wr_valid;
    assign core_dma_wr_addr  = ucie_wr_data[32 +: DMA_ADDR_W];
    assign core_dma_wr_data  = ucie_wr_data[31:0];
    assign ucie_wr_ready     = core_dma_wr_ready;

    // ---- Read channel: pass-through. ----
    assign core_dma_rd_req  = ucie_rd_req;
    assign core_dma_rd_addr = ucie_rd_addr;
    assign ucie_rd_data     = core_dma_rd_data;
    assign ucie_rd_valid    = core_dma_rd_valid;

    // ---- Status pass-through. ----
    assign ucie_busy = core_busy;
    assign ucie_irq  = core_irq;

endmodule
