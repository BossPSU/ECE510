// accel_top.sv — Top integration module for the accelerator chiplet
// Instantiates: datapath, control, SRAM, fused post-processing
module accel_top
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Host command interface (from CSR or UCIe adapter)
  input  cmd_pkt_t    cmd_in,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  // DMA: host writes data to scratchpad
  input  logic        dma_wr_valid,
  input  logic [15:0] dma_wr_addr,
  input  logic [31:0] dma_wr_data,
  output logic        dma_wr_ready,

  // DMA: host reads data from scratchpad
  input  logic        dma_rd_req,
  input  logic [15:0] dma_rd_addr,
  output logic [31:0] dma_rd_data,
  output logic        dma_rd_valid,

  // Status
  output logic        busy,
  output logic        done,
  output logic        irq,

  // Performance counters
  output logic [31:0] perf_active_cycles,
  output logic [31:0] perf_stall_cycles,
  output logic [31:0] perf_tiles_completed
);

  // ---- Internal signals ----

  // Controller outputs: latched command dimensions
  logic [7:0]  ctrl_tile_m, ctrl_tile_n, ctrl_tile_k;
  logic [15:0] ctrl_addr_a, ctrl_addr_b, ctrl_addr_out;

  // Controller <-> Scheduler
  logic       sched_start, sched_done, sched_tile_start;
  logic       sched_active;
  logic [7:0] sched_tile_m, sched_tile_n, sched_tile_k;

  // Controller <-> Loader/Writer
  logic       loader_a_start, loader_b_start;
  logic       loader_a_done, loader_b_done;
  logic       writer_start, writer_done;
  logic [15:0] loader_a_base, loader_b_base, writer_base;

  // Controller <-> Array
  logic       array_en, array_clear_acc;
  fused_op_t  fused_sel;

  // Loader <-> Scratchpad
  logic        load_a_req;
  logic [15:0] load_a_addr;
  logic [31:0] load_a_rdata;
  logic        load_a_rvalid;

  // Writer <-> Scratchpad
  logic        write_req, write_we;
  logic [15:0] write_addr;
  logic [31:0] write_wdata;

  // DMA <-> Scratchpad
  logic        dma_sram_req, dma_sram_we;
  logic [15:0] dma_sram_addr;
  logic [31:0] dma_sram_wdata, dma_sram_rdata;
  logic        dma_sram_rvalid;

  // Systolic array I/O
  logic [31:0] a_in  [ARRAY_ROWS];
  logic [31:0] b_in  [ARRAY_COLS];
  logic [31:0] c_out [ARRAY_ROWS][ARRAY_COLS];

  // Fused post-proc
  logic [31:0] fused_data_in, fused_data_out, fused_aux_in;
  logic        fused_in_valid, fused_out_valid;

  // ---- Controller ----
  accel_controller u_ctrl (
    .clk            (clk),
    .rst_n          (rst_n),
    .cmd            (cmd_in),
    .cmd_valid      (cmd_valid),
    .cmd_ready      (cmd_ready),
    .cmd_tile_m     (ctrl_tile_m),
    .cmd_tile_n     (ctrl_tile_n),
    .cmd_tile_k     (ctrl_tile_k),
    .cmd_addr_a     (ctrl_addr_a),
    .cmd_addr_b     (ctrl_addr_b),
    .cmd_addr_out   (ctrl_addr_out),
    .sched_start    (sched_start),
    .sched_done     (sched_done),
    .sched_tile_start(sched_tile_start),
    .sched_tile_m   (sched_tile_m),
    .sched_tile_n   (sched_tile_n),
    .sched_tile_k   (sched_tile_k),
    .loader_a_start (loader_a_start),
    .loader_b_start (loader_b_start),
    .loader_a_done  (loader_a_done),
    .loader_b_done  (loader_b_done),
    .writer_start   (writer_start),
    .writer_done    (writer_done),
    .array_en       (array_en),
    .array_clear_acc(array_clear_acc),
    .fused_sel      (fused_sel),
    .loader_a_base  (loader_a_base),
    .loader_b_base  (loader_b_base),
    .writer_base    (writer_base),
    .busy           (busy),
    .done           (done)
  );

  // ---- Tile Scheduler ----
  // Uses LATCHED dimensions from controller, not cmd_in directly
  tile_scheduler u_sched (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (sched_start),
    .tile_done   (writer_done),
    .dim_m       (ctrl_tile_m),
    .dim_n       (ctrl_tile_n),
    .dim_k       (ctrl_tile_k),
    .tile_m_idx  (sched_tile_m),
    .tile_n_idx  (sched_tile_n),
    .tile_k_idx  (sched_tile_k),
    .tile_start  (sched_tile_start),
    .all_done    (sched_done),
    .active      (sched_active)
  );

  // ---- Tile Loaders ----
  // Use LATCHED tile dimensions, not hardcoded TILE_SIZE
  tile_loader u_loader_a (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (loader_a_start),
    .en         (1'b1),
    .base_addr  (loader_a_base),
    .stride     ({8'b0, ctrl_tile_k}),
    .tile_rows  (ctrl_tile_m),
    .tile_cols  (ctrl_tile_k),
    .sram_req   (load_a_req),
    .sram_addr  (load_a_addr),
    .sram_rdata (load_a_rdata),
    .sram_rvalid(load_a_rvalid),
    .data_out   (),
    .data_valid (),
    .done       (loader_a_done)
  );

  tile_loader u_loader_b (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (loader_b_start),
    .en         (1'b1),
    .base_addr  (loader_b_base),
    .stride     ({8'b0, ctrl_tile_n}),
    .tile_rows  (ctrl_tile_k),
    .tile_cols  (ctrl_tile_n),
    .sram_req   (),
    .sram_addr  (),
    .sram_rdata ('0),
    .sram_rvalid(1'b1),  // Simplified: assume B always ready
    .data_out   (),
    .data_valid (),
    .done       (loader_b_done)
  );

  // ---- Tile Writer ----
  tile_writer u_writer (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (writer_start),
    .en         (1'b1),
    .base_addr  (writer_base),
    .stride     ({8'b0, ctrl_tile_n}),
    .tile_rows  (ctrl_tile_m),
    .tile_cols  (ctrl_tile_n),
    .data_in    (fused_data_out),
    .data_valid (fused_out_valid),
    .sram_req   (write_req),
    .sram_we    (write_we),
    .sram_addr  (write_addr),
    .sram_wdata (write_wdata),
    .done       (writer_done)
  );

  // ---- Systolic Array ----
  systolic_array_64x64 u_array (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (array_en),
    .clear_acc (array_clear_acc),
    .a_in      (a_in),
    .b_in      (b_in),
    .c_out     (c_out)
  );

  // ---- Fused Post-Processing ----
  assign fused_data_in  = c_out[0][0];
  assign fused_in_valid = array_en;
  assign fused_aux_in   = '0;

  fused_postproc_unit u_fused (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (1'b1),
    .op_sel    (fused_sel),
    .data_in   (fused_data_in),
    .in_valid  (fused_in_valid),
    .aux_in    (fused_aux_in),
    .data_out  (fused_data_out),
    .out_valid (fused_out_valid)
  );

  // ---- DMA Engine ----
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

  // ---- Scratchpad ----
  scratchpad_ctrl u_scratchpad (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_req   (load_a_req),
    .a_addr  (load_a_addr),
    .a_rdata (load_a_rdata),
    .a_rvalid(load_a_rvalid),
    .b_req   (write_req),
    .b_we    (write_we),
    .b_addr  (write_addr),
    .b_wdata (write_wdata),
    .c_req   (dma_sram_req),
    .c_we    (dma_sram_we),
    .c_addr  (dma_sram_addr),
    .c_wdata (dma_sram_wdata),
    .c_rdata (dma_sram_rdata),
    .c_rvalid(dma_sram_rvalid)
  );

  // ---- Performance Counters ----
  perf_counter_block u_perf (
    .clk            (clk),
    .rst_n          (rst_n),
    .clear          (!rst_n),
    .array_active   (array_en),
    .array_stall    (busy && !array_en),
    .tile_complete  (writer_done),
    .active_cycles  (perf_active_cycles),
    .stall_cycles   (perf_stall_cycles),
    .total_cycles   (),
    .tiles_completed(perf_tiles_completed)
  );

  assign irq = done;

endmodule
