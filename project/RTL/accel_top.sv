// accel_top.sv — Streaming fused accelerator chiplet top
//
// Architecture:
//   FSM (controller) handles only LOAD/WRITE phases (boundary I/O)
//   stream_pipeline runs autonomously between START and DONE,
//   with no intermediate FSM states. This is true fusion: matmul output
//   flows directly to activation to output buffer with no SRAM round-trips.
//
// Buffer interconnect:
//   tile_buffer exposes its full memory (mem_out) so stream_pipeline can
//   issue parallel reads for the systolic feeder. The FSM still uses the
//   linear write port to load tiles row by row.
module accel_top
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Host command interface
  input  cmd_pkt_t    cmd_in,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  // DMA: host writes data to scratchpad (BEFORE running)
  input  logic        dma_wr_valid,
  input  logic [15:0] dma_wr_addr,
  input  logic [31:0] dma_wr_data,
  output logic        dma_wr_ready,

  // DMA: host reads data from scratchpad (AFTER running)
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

  localparam int TILE_DIM = 64;

  // ====================================================================
  // Internal signals
  // ====================================================================

  logic [7:0]  ctrl_tile_m, ctrl_tile_n, ctrl_tile_k;
  fused_op_t   fused_sel;

  // Controller <-> SRAM port
  logic        ctrl_sram_req, ctrl_sram_we;
  logic [15:0] ctrl_sram_addr;
  logic [31:0] ctrl_sram_wdata, ctrl_sram_rdata;
  logic        ctrl_sram_rvalid;

  // Controller <-> input buffers (linear write)
  logic        buf_a_wr_en, buf_b_wr_en, buf_aux_wr_en;
  logic [11:0] buf_wr_idx;
  logic [31:0] buf_wr_data;

  // Pipeline <-> input buffers (parallel read via mem_out)
  logic signed [31:0] a_mem   [TILE_DIM][TILE_DIM];
  logic signed [31:0] b_mem   [TILE_DIM][TILE_DIM];
  logic signed [31:0] aux_mem [TILE_DIM][TILE_DIM];   // h_pre for FFN_BWD

  // Pipeline <-> output buffer (write)
  logic               out_wr_en;
  logic [11:0]        out_wr_idx;
  logic signed [31:0] out_wr_data;
  // Output buffer drain (FSM linear read)
  logic [11:0]        out_rd_idx;
  logic signed [31:0] out_rd_data;

  // Unused tile_buffer ports (tied off)
  logic signed [31:0] unused_buf_a_2d, unused_buf_b_2d, unused_buf_aux_2d;
  logic signed [31:0] unused_buf_a_lin, unused_buf_b_lin, unused_buf_aux_lin;
  logic signed [31:0] unused_out_2d;
  logic signed [31:0] unused_out_mem [TILE_DIM][TILE_DIM];

  // Pipeline boundary
  logic pipeline_start, pipeline_done;

  // DMA <-> SRAM
  logic        dma_sram_req, dma_sram_we;
  logic [15:0] dma_sram_addr;
  logic [31:0] dma_sram_wdata, dma_sram_rdata;
  logic        dma_sram_rvalid;

  // ====================================================================
  // Controller (minimal FSM)
  // ====================================================================
  accel_controller u_ctrl (
    .clk            (clk),
    .rst_n          (rst_n),
    .cmd            (cmd_in),
    .cmd_valid      (cmd_valid),
    .cmd_ready      (cmd_ready),
    .cmd_tile_m     (ctrl_tile_m),
    .cmd_tile_n     (ctrl_tile_n),
    .cmd_tile_k     (ctrl_tile_k),
    .fused_sel      (fused_sel),
    .sram_req       (ctrl_sram_req),
    .sram_we        (ctrl_sram_we),
    .sram_addr      (ctrl_sram_addr),
    .sram_wdata     (ctrl_sram_wdata),
    .sram_rdata     (ctrl_sram_rdata),
    .sram_rvalid    (ctrl_sram_rvalid),
    .buf_a_wr_en    (buf_a_wr_en),
    .buf_b_wr_en    (buf_b_wr_en),
    .buf_aux_wr_en  (buf_aux_wr_en),
    .buf_wr_idx     (buf_wr_idx),
    .buf_wr_data    (buf_wr_data),
    .out_rd_idx     (out_rd_idx),
    .out_rd_data    (out_rd_data),
    .pipeline_start (pipeline_start),
    .pipeline_done  (pipeline_done),
    .busy           (busy),
    .done           (done)
  );

  // ====================================================================
  // Input buffer A (FSM linear write, pipeline parallel read via mem_out)
  // ====================================================================
  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM)) u_buf_a (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en       (buf_a_wr_en),
    .wr_idx      (buf_wr_idx),
    .wr_data     ($signed(buf_wr_data)),
    .rd_row      (8'd0),
    .rd_col      (8'd0),
    .rd_data     (unused_buf_a_2d),
    .rd_lin_idx  (12'd0),
    .rd_lin_data (unused_buf_a_lin),
    .mem_out     (a_mem)
  );

  // ====================================================================
  // Input buffer B
  // ====================================================================
  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM)) u_buf_b (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en       (buf_b_wr_en),
    .wr_idx      (buf_wr_idx),
    .wr_data     ($signed(buf_wr_data)),
    .rd_row      (8'd0),
    .rd_col      (8'd0),
    .rd_data     (unused_buf_b_2d),
    .rd_lin_idx  (12'd0),
    .rd_lin_data (unused_buf_b_lin),
    .mem_out     (b_mem)
  );

  // ====================================================================
  // Auxiliary buffer (h_pre for FFN_BWD; shape tile_m x tile_n)
  // ====================================================================
  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM)) u_buf_aux (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en       (buf_aux_wr_en),
    .wr_idx      (buf_wr_idx),
    .wr_data     ($signed(buf_wr_data)),
    .rd_row      (8'd0),
    .rd_col      (8'd0),
    .rd_data     (unused_buf_aux_2d),
    .rd_lin_idx  (12'd0),
    .rd_lin_data (unused_buf_aux_lin),
    .mem_out     (aux_mem)
  );

  // ====================================================================
  // Streaming compute pipeline (the fused part)
  // ====================================================================
  stream_pipeline #(.DATA_WIDTH(32), .ARRAY_DIM(TILE_DIM)) u_pipe (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (pipeline_start),
    .done        (pipeline_done),
    .tile_m      (ctrl_tile_m),
    .tile_n      (ctrl_tile_n),
    .tile_k      (ctrl_tile_k),
    .op_sel      (fused_sel),
    .a_mem       (a_mem),
    .b_mem       (b_mem),
    .aux_mem     (aux_mem),
    .out_wr_en   (out_wr_en),
    .out_wr_idx  (out_wr_idx),
    .out_wr_data (out_wr_data)
  );

  // ====================================================================
  // Output buffer (pipeline writes, FSM drains during WRITE phase)
  // ====================================================================
  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM)) u_buf_out (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en       (out_wr_en),
    .wr_idx      (out_wr_idx),
    .wr_data     (out_wr_data),
    .rd_row      (8'd0),
    .rd_col      (8'd0),
    .rd_data     (unused_out_2d),
    .rd_lin_idx  (out_rd_idx),
    .rd_lin_data (out_rd_data),
    .mem_out     (unused_out_mem)
  );

  // ====================================================================
  // DMA engine (host I/O before/after pipeline runs)
  // ====================================================================
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

  // ====================================================================
  // Scratchpad (shared between controller load/write phases and DMA)
  // ====================================================================
  scratchpad_ctrl u_scratchpad (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_req   (ctrl_sram_req && !ctrl_sram_we),  // controller reads
    .a_addr  (ctrl_sram_addr),
    .a_rdata (ctrl_sram_rdata),
    .a_rvalid(ctrl_sram_rvalid),
    .b_req   (ctrl_sram_req && ctrl_sram_we),   // controller writes
    .b_we    (ctrl_sram_we),
    .b_addr  (ctrl_sram_addr),
    .b_wdata (ctrl_sram_wdata),
    .c_req   (dma_sram_req),
    .c_we    (dma_sram_we),
    .c_addr  (dma_sram_addr),
    .c_wdata (dma_sram_wdata),
    .c_rdata (dma_sram_rdata),
    .c_rvalid(dma_sram_rvalid)
  );

  // ====================================================================
  // Performance counters
  // ====================================================================
  perf_counter_block u_perf (
    .clk            (clk),
    .rst_n          (rst_n),
    .clear          (!rst_n),
    .array_active   (pipeline_start || u_pipe.running),
    .array_stall    (busy && !u_pipe.running),
    .tile_complete  (pipeline_done),
    .active_cycles  (perf_active_cycles),
    .stall_cycles   (perf_stall_cycles),
    .total_cycles   (),
    .tiles_completed(perf_tiles_completed)
  );

  assign irq = done;

endmodule
