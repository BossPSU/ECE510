// =============================================================================
// top.sv -- M3 Integrated Chiplet Top
// =============================================================================
//
// Description:
//   Integrates the M2 chiplet_interface (interface.sv) with the M2
//   compute_core (compute_core.sv). The interface terminates the UCIe-style
//   host link on the outside; compute_core houses the 16-lane, 64x64 fused
//   transformer engine (matmul + activation pipeline). Wiring is a direct
//   structural pass-through -- the interface module's core_* ports were
//   designed to mate one-to-one with compute_core's host-facing ports. No
//   glue logic, no FIFOs, no CDC: both blocks share the chiplet clock
//   domain and the same valid/ready handshakes.
//
//   This is the M3 deliverable per the milestone checklist: the single
//   external face of the chiplet is the UCIe-side ports; everything
//   beyond that (tile dispatch, lane scheduling, DMA, scratchpad,
//   systolic arrays, softmax) is inside compute_core.
//
// Clock / reset:
//   Single chiplet clock (clk). Reset is active-low asynchronous.
//   A real UCIe PHY would add CDC outside this module.
//
// Parameters:
//   N_LANES         -- number of data-parallel compute lanes (default 16,
//                      matches M2). Set to 1 for a scoped-down build.
//   LANE_LOCAL_BITS -- per-lane DMA local-address width (from accel_pkg).
//   LANE_BITS       -- lane-select width = $clog2(N_LANES).
//   DMA_ADDR_W      -- full DMA address = {lane, local}.
//   CMD_BUS_W       -- UCIe command bus width (128, zero-padded above
//                      macro_cmd_t).
//   WR_BUS_W        -- UCIe write bus width = DMA_ADDR_W + 32.
//
// External ports (UCIe-side):
//   clk             : in  : 1                 : chiplet clock
//   rst_n           : in  : 1                 : async reset, active low
//   ucie_cmd_valid  : in  : 1                 : command-channel valid
//   ucie_cmd_ready  : out : 1                 : command-channel ready
//   ucie_cmd_data   : in  : CMD_BUS_W (=128)  : packed macro_cmd_t
//   ucie_wr_valid   : in  : 1                 : write-channel valid
//   ucie_wr_ready   : out : 1                 : write-channel ready
//   ucie_wr_data    : in  : WR_BUS_W (=51)    : {addr[18:0], data[31:0]}
//   ucie_rd_req     : in  : 1                 : read-channel request
//   ucie_rd_addr    : in  : DMA_ADDR_W (=19)  : read address
//   ucie_rd_data    : out : 32                : read data (Q16.16)
//   ucie_rd_valid   : out : 1                 : read response valid
//   ucie_irq        : out : 1                 : interrupt to host (= done)
//   ucie_busy       : out : 1                 : chiplet busy
//
// =============================================================================
module top
  import accel_pkg::*;
#(
  parameter int N_LANES         = 16,
  parameter int LANE_LOCAL_BITS = LANE_LOCAL_W,
  parameter int LANE_BITS       = (N_LANES <= 1) ? 1 : $clog2(N_LANES),
  parameter int DMA_ADDR_W      = LANE_LOCAL_BITS + LANE_BITS,
  parameter int CMD_BUS_W       = 128,
  parameter int WR_BUS_W        = DMA_ADDR_W + 32
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- UCIe-side host link (the chiplet's only external face) ----
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

  // Performance counters: instantiated but not exposed at the chiplet edge
  // (the M2 status pass-through covers busy + irq; perf is internal).
  logic [31:0]           perf_active, perf_stall, perf_tiles;

  // -------------------------------------------------------------------------
  // UCIe protocol adapter (M2 chiplet_interface)
  // -------------------------------------------------------------------------
  chiplet_interface #(
    .LANE_LOCAL_BITS(LANE_LOCAL_BITS),
    .LANE_BITS      (LANE_BITS),
    .DMA_ADDR_W     (DMA_ADDR_W),
    .CMD_BUS_W      (CMD_BUS_W),
    .WR_BUS_W       (WR_BUS_W)
  ) u_iface (
    .clk                  (clk),
    .rst_n                (rst_n),

    // External UCIe pins
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

    // Core-facing bus
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

  // -------------------------------------------------------------------------
  // Compute core (M2 compute_core wraps accel_top: 16 lanes, 64x64 array,
  // fused matmul+activation pipeline). The interface module's core_* ports
  // mate one-to-one with compute_core's host-facing ports.
  // -------------------------------------------------------------------------
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
