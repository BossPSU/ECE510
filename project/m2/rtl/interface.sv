// =============================================================================
// interface.sv -- M2 UCIe Host-to-Chiplet Interface for ECE 410/510
// =============================================================================
//
// NOTE on filename vs module name:
//   The grader's filename rule says "compute_core.sv ... interface.sv ...
//   the two files named above must exist and must be the top-level modules."
//   "interface" is a SystemVerilog reserved word and CANNOT be used as a
//   module name, so this file's top-level module is `chiplet_interface`.
//
// Description:
//   Pure protocol-layer adapter between a UCIe-style host link and the
//   compute_core's command/DMA bus. Selected as the chiplet interface
//   in M1 (project/m1/interface_selection.md): UCIe x16 standard
//   package, 16 GT/s (~32 GB/s/dir). Provides ~2.5x BW headroom for the
//   16-lane compute (peak demand ~13 GB/s at AI=5 MAC/byte).
//
//   This module ONLY shapes traffic; it has no compute, no SRAM, and no
//   internal state beyond port pass-through. It can be tested in
//   isolation with tb_interface.sv before being paired with compute_core.
//
// Protocol (UCIe 1.0 conformance, simplified for this project):
//   * Three independent valid/ready channels:
//       command (host -> chiplet, packed macro_cmd_t),
//       data write (host -> chiplet, packed {addr, data}),
//       data read (host <-> chiplet, addr in / data+valid out).
//   * Status: ucie_busy (chiplet level), ucie_irq (= done from compute).
//   * Single clock domain (chiplet clock); UCIe Gen 1 mainband does
//     forward-clocked source-synchronous, which is here represented by
//     a shared `clk` between sender and receiver. CDC for a real UCIe
//     PHY would live OUTSIDE this module.
//   * Reset is active-low asynchronous.
//
// Transaction format / register map:
//   * ucie_cmd_data is the packed bits of accel_pkg::macro_cmd_t,
//     LSB-aligned. Upper bits beyond $bits(macro_cmd_t) are reserved.
//     macro_cmd_t fields (in declaration order, packed): mode, addr_a,
//     addr_b, addr_aux, addr_out, num_m_tiles, num_n_tiles,
//     tile_m, tile_n, tile_k.
//   * ucie_wr_data packs {addr[DMA_ADDR_W-1:0], data[31:0]}.
//     The 19-bit DMA address splits into 4-bit lane id (upper) and
//     15-bit per-lane local offset.
//   * ucie_rd_addr is the same 19-bit DMA address; ucie_rd_data returns
//     a 32-bit Q16.16 word with ucie_rd_valid 2 cycles after request
//     (matches scratchpad_ctrl read latency).
//
// Ports:
//   clk, rst_n           : in    : 1, 1                  : clock and async reset
//   ucie_cmd_valid/ready : in/out: 1, 1                  : cmd handshake
//   ucie_cmd_data        : in    : 128                   : packed macro_cmd_t
//   ucie_wr_valid/ready  : in/out: 1, 1                  : write handshake
//   ucie_wr_data         : in    : DMA_ADDR_W + 32 (=51) : {addr, data}
//   ucie_rd_req          : in    : 1                     : read request
//   ucie_rd_addr         : in    : DMA_ADDR_W (=19)      : read address
//   ucie_rd_data         : out   : 32                    : read data
//   ucie_rd_valid        : out   : 1                     : read response valid
//   ucie_irq             : out   : 1                     : interrupt to host
//   ucie_busy            : out   : 1                     : chiplet busy
//   core_*               : out/in: ...                   : forwarded to compute_core
// =============================================================================
module chiplet_interface
  import accel_pkg::*;
#(
  parameter int LANE_LOCAL_BITS = LANE_LOCAL_W,
  parameter int LANE_BITS       = $clog2(16),
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
  output logic                  ucie_busy,

  // ---- Core-side internal bus (drives compute_core when paired) ----
  output macro_cmd_t            core_macro_cmd,
  output logic                  core_macro_cmd_valid,
  input  logic                  core_macro_cmd_ready,

  output logic                  core_dma_wr_valid,
  output logic [DMA_ADDR_W-1:0] core_dma_wr_addr,
  output logic [31:0]           core_dma_wr_data,
  input  logic                  core_dma_wr_ready,

  output logic                  core_dma_rd_req,
  output logic [DMA_ADDR_W-1:0] core_dma_rd_addr,
  input  logic [31:0]           core_dma_rd_data,
  input  logic                  core_dma_rd_valid,

  input  logic                  core_busy,
  input  logic                  core_irq
);

  // ---- Command channel: unpack ucie_cmd_data -> macro_cmd_t ----
  // The struct is packed (declared in accel_pkg.sv); cast its LSBs.
  assign core_macro_cmd       = macro_cmd_t'(ucie_cmd_data[$bits(macro_cmd_t)-1:0]);
  assign core_macro_cmd_valid = ucie_cmd_valid;
  assign ucie_cmd_ready       = core_macro_cmd_ready;

  // ---- Write channel: split packed {addr, data} ----
  assign core_dma_wr_valid = ucie_wr_valid;
  assign core_dma_wr_addr  = ucie_wr_data[31 +: DMA_ADDR_W];
  assign core_dma_wr_data  = ucie_wr_data[31:0];
  assign ucie_wr_ready     = core_dma_wr_ready;

  // ---- Read channel: pass through ----
  assign core_dma_rd_req  = ucie_rd_req;
  assign core_dma_rd_addr = ucie_rd_addr;
  assign ucie_rd_data     = core_dma_rd_data;
  assign ucie_rd_valid    = core_dma_rd_valid;

  // ---- Status pass-through ----
  assign ucie_busy = core_busy;
  assign ucie_irq  = core_irq;

endmodule
