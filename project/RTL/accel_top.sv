// accel_top.sv — Multi-tile, data-parallel accelerator chiplet top.
//
// Architecture:
//   * tile_dispatcher walks the (m_tiles, n_tiles) output grid and issues
//     per-tile cmd_pkt_t micro-commands to whichever lane is idle.
//   * N_LANES accel_engine instances run in parallel. Each preserves the
//     intra-tile fusion (LOAD -> autonomous matmul+activation -> WRITE) and
//     owns a private scratchpad bank.
//   * Host DMA addresses are routed to the right lane via address bit
//     [LANE_ADDR_BIT]: 0 -> lane 0 bank, 1 -> lane 1 bank. Lower bits are
//     the per-bank offset.
//   * For shared input data (e.g., X used by all output tiles in FFN fwd),
//     the host duplicates the write into both banks. This keeps the
//     per-bank SRAM single-ported and avoids cross-lane arbitration.
//
// Macro-command interface (cmd_pkt_t single-tile path is gone — wrap with
// num_m_tiles=num_n_tiles=1 if you need single-tile behavior).
module accel_top
  import accel_pkg::*;
#(
  // Number of data-parallel compute lanes. UCIe x16 standard package at
  // 16 GT/s (~32 GB/s/dir) keeps 16 lanes (~131 TOPS at 1 GHz, ~13 GB/s
  // peak demand at AI=5 MAC/byte) fed with ~2.5x BW headroom.
  parameter int N_LANES         = 16,
  // Lower bits of DMA address are the per-lane local offset; upper bits
  // are the lane id. With LANE_LOCAL_BITS=12 each lane bank is 4 KW
  // (16 KB at 32-bit data) and ceil(log2(N_LANES)) bits select the bank.
  parameter int LANE_LOCAL_BITS = 12,
  parameter int LANE_BITS       = (N_LANES <= 1) ? 1 : $clog2(N_LANES)
)(
  input  logic        clk,
  input  logic        rst_n,

  // Host macro-command interface
  input  macro_cmd_t  macro_cmd_in,
  input  logic        macro_cmd_valid,
  output logic        macro_cmd_ready,

  // DMA: host writes / reads scratchpad. Address bit [LANE_ADDR_BIT]
  // selects which lane bank the access goes to.
  input  logic        dma_wr_valid,
  input  logic [15:0] dma_wr_addr,
  input  logic [31:0] dma_wr_data,
  output logic        dma_wr_ready,

  input  logic        dma_rd_req,
  input  logic [15:0] dma_rd_addr,
  output logic [31:0] dma_rd_data,
  output logic        dma_rd_valid,

  // Status
  output logic        busy,
  output logic        done,
  output logic        irq,

  // Aggregate performance counters (sum across lanes)
  output logic [31:0] perf_active_cycles,
  output logic [31:0] perf_stall_cycles,
  output logic [31:0] perf_tiles_completed
);

  // ====================================================================
  // Dispatcher <-> lanes
  // ====================================================================
  cmd_pkt_t lane_cmd       [N_LANES];
  logic     lane_cmd_valid [N_LANES];
  logic     lane_cmd_ready [N_LANES];
  logic     lane_done      [N_LANES];
  logic     lane_busy      [N_LANES];

  // Per-lane SRAM ports
  logic        lane_sram_req   [N_LANES];
  logic        lane_sram_we    [N_LANES];
  logic [15:0] lane_sram_addr  [N_LANES];
  logic [31:0] lane_sram_wdata [N_LANES];
  logic [31:0] lane_sram_rdata [N_LANES];
  logic        lane_sram_rvalid[N_LANES];

  // Per-lane perf
  logic [31:0] lane_perf_active [N_LANES];
  logic [31:0] lane_perf_stall  [N_LANES];
  logic [31:0] lane_perf_tiles  [N_LANES];

  // ====================================================================
  // Tile dispatcher
  // ====================================================================
  logic dispatcher_done;

  tile_dispatcher #(
    .N_LANES (N_LANES),
    .TILE_DIM(64)
  ) u_dispatcher (
    .clk            (clk),
    .rst_n          (rst_n),
    .macro_cmd      (macro_cmd_in),
    .macro_valid    (macro_cmd_valid),
    .macro_ready    (macro_cmd_ready),
    .macro_done     (dispatcher_done),
    .lane_cmd       (lane_cmd),
    .lane_cmd_valid (lane_cmd_valid),
    .lane_cmd_ready (lane_cmd_ready),
    .lane_done      (lane_done)
  );

  // ====================================================================
  // DMA engine (single, address-routed to per-lane scratchpad)
  // ====================================================================
  logic        dma_sram_req, dma_sram_we;
  logic [15:0] dma_sram_addr;
  logic [31:0] dma_sram_wdata, dma_sram_rdata;
  logic        dma_sram_rvalid;

  dma_engine u_dma (
    .clk           (clk),
    .rst_n         (rst_n),
    .host_wr_valid (dma_wr_valid),
    .host_wr_addr  (dma_wr_addr),
    .host_wr_data  (dma_wr_data),
    .host_wr_ready (dma_wr_ready),
    .host_rd_req   (dma_rd_req),
    .host_rd_addr  (dma_rd_addr),
    .host_rd_data  (dma_rd_data),
    .host_rd_valid (dma_rd_valid),
    .sram_req      (dma_sram_req),
    .sram_we       (dma_sram_we),
    .sram_addr     (dma_sram_addr),
    .sram_wdata    (dma_sram_wdata),
    .sram_rdata    (dma_sram_rdata),
    .sram_rvalid   (dma_sram_rvalid)
  );

  // Lane select on DMA address: bits [LANE_LOCAL_BITS +: LANE_BITS] choose
  // the bank, bits [LANE_LOCAL_BITS-1:0] are the per-bank offset. So a DMA
  // write to 0x3180 with N_LANES=16 routes to lane 3 (= 0x3) at local 0x180.
  logic [LANE_BITS-1:0] dma_lane_sel;
  logic [15:0]          dma_local_addr;
  assign dma_lane_sel   = dma_sram_addr[LANE_LOCAL_BITS +: LANE_BITS];
  assign dma_local_addr = {{(16-LANE_LOCAL_BITS){1'b0}},
                           dma_sram_addr[LANE_LOCAL_BITS-1:0]};

  // ====================================================================
  // Lanes (each: accel_engine + private scratchpad with DMA second port)
  // ====================================================================
  // Per-bank DMA-side wires (only one bank sees the DMA each cycle)
  logic        bank_dma_req   [N_LANES];
  logic        bank_dma_we    [N_LANES];
  logic [15:0] bank_dma_addr  [N_LANES];
  logic [31:0] bank_dma_wdata [N_LANES];
  logic [31:0] bank_dma_rdata [N_LANES];
  logic        bank_dma_rvalid[N_LANES];

  // Route DMA to the addressed bank; other bank sees zero req
  always_comb begin
    for (int l = 0; l < N_LANES; l++) begin
      bank_dma_req  [l] = 1'b0;
      bank_dma_we   [l] = 1'b0;
      bank_dma_addr [l] = '0;
      bank_dma_wdata[l] = '0;
    end
    bank_dma_req  [dma_lane_sel] = dma_sram_req;
    bank_dma_we   [dma_lane_sel] = dma_sram_we;
    bank_dma_addr [dma_lane_sel] = dma_local_addr;
    bank_dma_wdata[dma_lane_sel] = dma_sram_wdata;
  end

  // Mux DMA-side rdata/rvalid back from the addressed bank.
  // The lane-select is registered one cycle to align with the scratchpad's
  // 1-cycle read latency.
  logic [LANE_BITS-1:0] dma_lane_sel_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) dma_lane_sel_q <= '0;
    else        dma_lane_sel_q <= dma_lane_sel;
  end
  assign dma_sram_rdata  = bank_dma_rdata [dma_lane_sel_q];
  assign dma_sram_rvalid = bank_dma_rvalid[dma_lane_sel_q];

  genvar gl;
  generate
    for (gl = 0; gl < N_LANES; gl++) begin : gen_lane
      // ----- engine -----
      accel_engine u_engine (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cmd_in               (lane_cmd[gl]),
        .cmd_valid            (lane_cmd_valid[gl]),
        .cmd_ready            (lane_cmd_ready[gl]),
        .sram_req             (lane_sram_req[gl]),
        .sram_we              (lane_sram_we[gl]),
        .sram_addr            (lane_sram_addr[gl]),
        .sram_wdata           (lane_sram_wdata[gl]),
        .sram_rdata           (lane_sram_rdata[gl]),
        .sram_rvalid          (lane_sram_rvalid[gl]),
        .busy                 (lane_busy[gl]),
        .done                 (lane_done[gl]),
        .perf_active_cycles   (lane_perf_active[gl]),
        .perf_stall_cycles    (lane_perf_stall[gl]),
        .perf_tiles_completed (lane_perf_tiles[gl])
      );

      // ----- private scratchpad bank -----
      scratchpad_ctrl u_bank (
        .clk     (clk),
        .rst_n   (rst_n),
        // Engine read port
        .a_req   (lane_sram_req[gl] && !lane_sram_we[gl]),
        .a_addr  (lane_sram_addr[gl]),
        .a_rdata (lane_sram_rdata[gl]),
        .a_rvalid(lane_sram_rvalid[gl]),
        // Engine write port
        .b_req   (lane_sram_req[gl] && lane_sram_we[gl]),
        .b_we    (lane_sram_we[gl]),
        .b_addr  (lane_sram_addr[gl]),
        .b_wdata (lane_sram_wdata[gl]),
        // DMA port (gated by address)
        .c_req   (bank_dma_req[gl]),
        .c_we    (bank_dma_we[gl]),
        .c_addr  (bank_dma_addr[gl]),
        .c_wdata (bank_dma_wdata[gl]),
        .c_rdata (bank_dma_rdata[gl]),
        .c_rvalid(bank_dma_rvalid[gl])
      );
    end
  endgenerate

  // ====================================================================
  // Aggregate status / perf
  // ====================================================================
  logic any_busy;
  always_comb begin
    any_busy = 1'b0;
    for (int l = 0; l < N_LANES; l++)
      if (lane_busy[l]) any_busy = 1'b1;
  end
  assign busy = any_busy || !macro_cmd_ready;
  assign done = dispatcher_done;
  assign irq  = dispatcher_done;

  always_comb begin
    perf_active_cycles   = '0;
    perf_stall_cycles    = '0;
    perf_tiles_completed = '0;
    for (int l = 0; l < N_LANES; l++) begin
      perf_active_cycles   = perf_active_cycles   + lane_perf_active[l];
      perf_stall_cycles    = perf_stall_cycles    + lane_perf_stall[l];
      perf_tiles_completed = perf_tiles_completed + lane_perf_tiles[l];
    end
  end

endmodule
