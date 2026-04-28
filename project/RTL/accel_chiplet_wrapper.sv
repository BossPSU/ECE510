// accel_chiplet_wrapper.sv — Outer wrapper for chiplet-level integration
// Models UCIe host-facing link, clock/reset, and top-level packaging signals
module accel_chiplet_wrapper
  import accel_pkg::*;
(
  // Chiplet clock and reset
  input  logic        clk_chiplet,
  input  logic        rst_n,

  // UCIe-style host interface (simplified)
  // Command channel
  input  logic        ucie_cmd_valid,
  output logic        ucie_cmd_ready,
  input  logic [127:0] ucie_cmd_data,    // packed cmd_pkt_t (zero-extended)

  // Data write channel (host → chiplet)
  input  logic        ucie_wr_valid,
  output logic        ucie_wr_ready,
  input  logic [47:0] ucie_wr_data,      // {addr[15:0], data[31:0]}

  // Data read channel (chiplet → host)
  input  logic        ucie_rd_req,
  input  logic [15:0] ucie_rd_addr,
  output logic [31:0] ucie_rd_data,
  output logic        ucie_rd_valid,

  // Status / interrupt
  output logic        ucie_irq,
  output logic        ucie_busy
);

  // ---- Unpack UCIe command ----
  cmd_pkt_t cmd_unpacked;
  assign cmd_unpacked = cmd_pkt_t'(ucie_cmd_data[$bits(cmd_pkt_t)-1:0]);

  // ---- Unpack UCIe write data ----
  logic [15:0] wr_addr;
  logic [31:0] wr_data;
  assign wr_addr = ucie_wr_data[47:32];
  assign wr_data = ucie_wr_data[31:0];

  // ---- Performance counter outputs ----
  logic [31:0] perf_active, perf_stall, perf_tiles;

  // ---- Accelerator core ----
  accel_top u_accel (
    .clk                  (clk_chiplet),
    .rst_n                (rst_n),

    .cmd_in               (cmd_unpacked),
    .cmd_valid            (ucie_cmd_valid),
    .cmd_ready            (ucie_cmd_ready),

    .dma_wr_valid         (ucie_wr_valid),
    .dma_wr_addr          (wr_addr),
    .dma_wr_data          (wr_data),
    .dma_wr_ready         (ucie_wr_ready),

    .dma_rd_req           (ucie_rd_req),
    .dma_rd_addr          (ucie_rd_addr),
    .dma_rd_data          (ucie_rd_data),
    .dma_rd_valid         (ucie_rd_valid),

    .busy                 (ucie_busy),
    .done                 (),
    .irq                  (ucie_irq),

    .perf_active_cycles   (perf_active),
    .perf_stall_cycles    (perf_stall),
    .perf_tiles_completed (perf_tiles)
  );

endmodule
