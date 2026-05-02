// =============================================================================
// compute_core.sv -- M2 Top-Level Compute Core for ECE 410/510
// =============================================================================
//
// Description:
//   Multi-tile, data-parallel transformer accelerator. 16 lanes of
//   intra-tile fusion (matmul + activation in a single autonomous
//   streaming pipeline), with hardware tile orchestration and per-lane
//   tile slots. Supports FFN forward (GELU), FFN backward (fused
//   dh * GELU'(h_pre)), and attention forward (softmax). All numeric
//   work is in Q16.16 signed fixed-point.
//
//   Internally instantiates accel_top, which contains:
//     - tile_dispatcher (static round-robin -> per-lane micro_cmds)
//     - 16x accel_engine (controller + 4 tile_buffers + stream_pipeline + perf)
//     - 16x scratchpad_ctrl (private per-lane SRAM bank)
//     - dma_engine (host-visible address-routed bus)
//   Every submodule is synthesizable; see precision.md for numeric format.
//
// Clock / reset:
//   Single clock domain (target 1 GHz).
//   Reset is active-low asynchronous (rst_n falling edge clears all state).
//
// Ports (name : direction : width : purpose):
//   clk                  : in     : 1                        : clock
//   rst_n                : in     : 1                        : async reset, active low
//   macro_cmd_in         : in     : $bits(macro_cmd_t)       : packed multi-tile command
//   macro_cmd_valid      : in     : 1                        : command valid (host -> chiplet)
//   macro_cmd_ready      : out    : 1                        : command ready (chiplet -> host)
//   dma_wr_valid         : in     : 1                        : DMA write valid
//   dma_wr_addr          : in     : DMA_ADDR_W (=19)         : DMA write addr {lane,local}
//   dma_wr_data          : in     : 32                       : DMA write data (Q16.16)
//   dma_wr_ready         : out    : 1                        : DMA write ready
//   dma_rd_req           : in     : 1                        : DMA read request
//   dma_rd_addr          : in     : DMA_ADDR_W (=19)         : DMA read addr
//   dma_rd_data          : out    : 32                       : DMA read data (Q16.16)
//   dma_rd_valid         : out    : 1                        : DMA read valid
//   busy                 : out    : 1                        : any lane busy or macro pending
//   done                 : out    : 1                        : macro complete pulse
//   irq                  : out    : 1                        : interrupt to host (= done)
//   perf_active_cycles   : out    : 32                       : sum across lanes
//   perf_stall_cycles    : out    : 32                       : sum across lanes
//   perf_tiles_completed : out    : 32                       : tiles finished count
//
// =============================================================================
module compute_core
  import accel_pkg::*;
#(
  parameter int N_LANES         = 16,
  parameter int LANE_LOCAL_BITS = LANE_LOCAL_W,
  parameter int LANE_BITS       = (N_LANES <= 1) ? 1 : $clog2(N_LANES),
  parameter int DMA_ADDR_W      = LANE_LOCAL_BITS + LANE_BITS
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  macro_cmd_t            macro_cmd_in,
  input  logic                  macro_cmd_valid,
  output logic                  macro_cmd_ready,

  input  logic                  dma_wr_valid,
  input  logic [DMA_ADDR_W-1:0] dma_wr_addr,
  input  logic [31:0]           dma_wr_data,
  output logic                  dma_wr_ready,

  input  logic                  dma_rd_req,
  input  logic [DMA_ADDR_W-1:0] dma_rd_addr,
  output logic [31:0]           dma_rd_data,
  output logic                  dma_rd_valid,

  output logic                  busy,
  output logic                  done,
  output logic                  irq,

  output logic [31:0]           perf_active_cycles,
  output logic [31:0]           perf_stall_cycles,
  output logic [31:0]           perf_tiles_completed
);

  accel_top #(
    .N_LANES        (N_LANES),
    .LANE_LOCAL_BITS(LANE_LOCAL_BITS),
    .LANE_BITS      (LANE_BITS),
    .DMA_ADDR_W     (DMA_ADDR_W)
  ) u_accel_top (
    .clk                  (clk),
    .rst_n                (rst_n),
    .macro_cmd_in         (macro_cmd_in),
    .macro_cmd_valid      (macro_cmd_valid),
    .macro_cmd_ready      (macro_cmd_ready),
    .dma_wr_valid         (dma_wr_valid),
    .dma_wr_addr          (dma_wr_addr),
    .dma_wr_data          (dma_wr_data),
    .dma_wr_ready         (dma_wr_ready),
    .dma_rd_req           (dma_rd_req),
    .dma_rd_addr          (dma_rd_addr),
    .dma_rd_data          (dma_rd_data),
    .dma_rd_valid         (dma_rd_valid),
    .busy                 (busy),
    .done                 (done),
    .irq                  (irq),
    .perf_active_cycles   (perf_active_cycles),
    .perf_stall_cycles    (perf_stall_cycles),
    .perf_tiles_completed (perf_tiles_completed)
  );

endmodule
