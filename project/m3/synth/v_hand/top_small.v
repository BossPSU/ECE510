/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// top_small.v -- M3 Option-A integrated top, hand-flattened.
//
// Wires chiplet_interface (UCIe protocol) to compute_core (multi-lane
// accel_top). Default parameter values give the Option-A scope-down:
//   N_LANES        = 1
//   TILE_DIM       = 4   (4x4 systolic, softmax_v4, tile_buffer x 4)
//   LANE_LOCAL_BITS= 7   ($clog2(N_SLOTS=2 * SLOT_STRIDE=4*4*4))
//   DMA_ADDR_W     = 8
//
// External pin layout matches project/m3/rtl/top.sv (the cosim top); the
// only differences are the scoped-down internal dimensions.
// =============================================================================
module top_small #(
    parameter N_LANES         = 1,
    parameter TILE_DIM        = 2,
    parameter LANE_LOCAL_BITS = 5,
    parameter LANE_BITS       = (N_LANES <= 1) ? 1 : clog2_f(N_LANES),
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
    ucie_busy
);

    localparam MACRO_W = 107;

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

    // Internal interface <-> core bus.
    wire [MACRO_W-1:0]    core_macro_cmd;
    wire                  core_macro_cmd_valid;
    wire                  core_macro_cmd_ready;
    wire                  core_dma_wr_valid;
    wire [DMA_ADDR_W-1:0] core_dma_wr_addr;
    wire [31:0]           core_dma_wr_data;
    wire                  core_dma_wr_ready;
    wire                  core_dma_rd_req;
    wire [DMA_ADDR_W-1:0] core_dma_rd_addr;
    wire [31:0]           core_dma_rd_data;
    wire                  core_dma_rd_valid;
    wire                  core_busy;
    wire                  core_done;
    wire                  core_irq;
    wire [31:0]           perf_active, perf_stall, perf_tiles;

    chiplet_interface #(
        .LANE_LOCAL_BITS(LANE_LOCAL_BITS),
        .LANE_BITS      (LANE_BITS),
        .DMA_ADDR_W     (DMA_ADDR_W),
        .CMD_BUS_W      (CMD_BUS_W),
        .WR_BUS_W       (WR_BUS_W)
    ) u_iface (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ucie_cmd_valid       (ucie_cmd_valid),
        .ucie_cmd_ready       (ucie_cmd_ready),
        .ucie_cmd_data        (ucie_cmd_data),
        .ucie_wr_valid        (ucie_wr_valid),
        .ucie_wr_ready        (ucie_wr_ready),
        .ucie_wr_data         (ucie_wr_data),
        .ucie_rd_req          (ucie_rd_req),
        .ucie_rd_addr         (ucie_rd_addr),
        .ucie_rd_data         (ucie_rd_data),
        .ucie_rd_valid        (ucie_rd_valid),
        .ucie_irq             (ucie_irq),
        .ucie_busy            (ucie_busy),
        .core_macro_cmd       (core_macro_cmd),
        .core_macro_cmd_valid (core_macro_cmd_valid),
        .core_macro_cmd_ready (core_macro_cmd_ready),
        .core_dma_wr_valid    (core_dma_wr_valid),
        .core_dma_wr_addr     (core_dma_wr_addr),
        .core_dma_wr_data     (core_dma_wr_data),
        .core_dma_wr_ready    (core_dma_wr_ready),
        .core_dma_rd_req      (core_dma_rd_req),
        .core_dma_rd_addr     (core_dma_rd_addr),
        .core_dma_rd_data     (core_dma_rd_data),
        .core_dma_rd_valid    (core_dma_rd_valid),
        .core_busy            (core_busy),
        .core_irq             (core_irq)
    );

    compute_core #(
        .N_LANES        (N_LANES),
        .TILE_DIM       (TILE_DIM),
        .LANE_LOCAL_BITS(LANE_LOCAL_BITS),
        .LANE_BITS      (LANE_BITS),
        .DMA_ADDR_W     (DMA_ADDR_W)
    ) u_core (
        .clk                  (clk),
        .rst_n                (rst_n),
        .macro_cmd_in         (core_macro_cmd),
        .macro_cmd_valid      (core_macro_cmd_valid),
        .macro_cmd_ready      (core_macro_cmd_ready),
        .dma_wr_valid         (core_dma_wr_valid),
        .dma_wr_addr          (core_dma_wr_addr),
        .dma_wr_data          (core_dma_wr_data),
        .dma_wr_ready         (core_dma_wr_ready),
        .dma_rd_req           (core_dma_rd_req),
        .dma_rd_addr          (core_dma_rd_addr),
        .dma_rd_data          (core_dma_rd_data),
        .dma_rd_valid         (core_dma_rd_valid),
        .busy                 (core_busy),
        .done                 (core_done),
        .irq                  (core_irq),
        .perf_active_cycles   (perf_active),
        .perf_stall_cycles    (perf_stall),
        .perf_tiles_completed (perf_tiles)
    );

    function integer clog2_f;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2_f = 0;
            while (v > 0) begin v = v >> 1; clog2_f = clog2_f + 1; end
        end
    endfunction

endmodule
