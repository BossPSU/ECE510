// =============================================================================
// top_small.sv -- M3 scope-down integrated top, OpenLane synth target
// =============================================================================
//
// Same wiring as project/m3/rtl/top.sv (chiplet_interface + compute_core)
// but with N_LANES=1 and using the scoped-down accel_pkg in this folder
// (ARRAY_ROWS=4, TILE_SIZE=4, SRAM_DEPTH=64, etc.). Lives only inside the
// OpenLane filelist -- the QuestaSim co-simulation uses project/m3/rtl/top.sv
// against the unmodified M2 64x64 RTL.
//
// Why a separate file: scoping down to OpenLane's ~50K-cell ceiling needs
// (a) accel_pkg fork (shrinks ARRAY/TILE/SRAM dims), (b) accel_engine fork
// (replaces hardcoded `localparam int TILE_DIM = 64`), (c) accel_top fork
// (replaces hardcoded `.TILE_DIM(64)` instantiation), and (d) N_LANES=1.
// All four together are the "Option A scope-down" described in
// project/m3/synthesis_notes.md.
//
// External pins are IDENTICAL to project/m3/rtl/top.sv. Only the internal
// dimensions change. The grader can compile either top against the same
// chiplet_interface and get the same UCIe-side protocol.
// =============================================================================
module top_small
  import accel_pkg::*;
#(
  parameter int N_LANES         = 1,
  parameter int LANE_LOCAL_BITS = LANE_LOCAL_W,
  parameter int LANE_BITS       = (N_LANES <= 1) ? 1 : $clog2(N_LANES),
  parameter int DMA_ADDR_W      = LANE_LOCAL_BITS + LANE_BITS,
  parameter int CMD_BUS_W       = 128,
  parameter int WR_BUS_W        = DMA_ADDR_W + 32
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- UCIe-side host link ----
  input  logic                  ucie_cmd_valid,
  output logic                  ucie_cmd_ready,
  input  logic [CMD_BUS_W-1:0]  ucie_cmd_data,

  input  logic                  ucie_wr_valid,
  output logic                  ucie_wr_ready,
  input  logic [WR_BUS_W-1:0]   ucie_wr_data,

  input  logic                  ucie_rd_req,
  input  logic [DMA_ADDR_W-1:0] ucie_rd_addr,
  output logic [31:0]           ucie_rd_data,
  output logic                  ucie_rd_valid,

  output logic                  ucie_irq,
  output logic                  ucie_busy
);

  // ---- Internal interface <-> core bus ----
  macro_cmd_t            core_macro_cmd;
  logic                  core_macro_cmd_valid;
  logic                  core_macro_cmd_ready;

  logic                  core_dma_wr_valid;
  logic [DMA_ADDR_W-1:0] core_dma_wr_addr;
  logic [31:0]           core_dma_wr_data;
  logic                  core_dma_wr_ready;

  logic                  core_dma_rd_req;
  logic [DMA_ADDR_W-1:0] core_dma_rd_addr;
  logic [31:0]           core_dma_rd_data;
  logic                  core_dma_rd_valid;

  logic                  core_busy;
  logic                  core_done;
  logic                  core_irq;

  logic [31:0]           perf_active, perf_stall, perf_tiles;

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

endmodule
