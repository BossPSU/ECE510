// accel_engine.sv — Single-tile compute lane.
//
// Contains the full intra-tile fusion pipeline (controller + 4 tile buffers
// + stream_pipeline + per-lane perf counters), but no DMA and no scratchpad.
// SRAM port is exposed so the multi-lane top can pair the engine with a
// private (or arbitrated) scratchpad.
//
// One micro-command (cmd_pkt_t) drives one full output tile: LOAD_A, LOAD_B,
// optional LOAD_AUX, autonomous compute, WRITE. cmd_ready pulses high when
// the engine is idle and ready for the next tile.
module accel_engine
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Per-tile command
  input  cmd_pkt_t    cmd_in,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  // Private SRAM port (paired externally with one scratchpad bank)
  output logic        sram_req,
  output logic        sram_we,
  output logic [15:0] sram_addr,
  output logic [31:0] sram_wdata,
  input  logic [31:0] sram_rdata,
  input  logic        sram_rvalid,

  // Status
  output logic        busy,
  output logic        done,

  // Per-lane performance counters
  output logic [31:0] perf_active_cycles,
  output logic [31:0] perf_stall_cycles,
  output logic [31:0] perf_tiles_completed
);

  localparam int TILE_DIM = 64;

  // Controller <-> rest
  logic [7:0]  ctrl_tile_m, ctrl_tile_n, ctrl_tile_k;
  fused_op_t   fused_sel;

  // Linear write paths to input buffers (shared idx/data, per-buffer wr_en)
  logic        buf_a_wr_en, buf_b_wr_en, buf_aux_wr_en;
  logic [11:0] buf_wr_idx;
  logic [31:0] buf_wr_data;

  // Multi-port read interface between buffers and streaming pipeline.
  // Each input buffer (a, b) exposes TILE_DIM scattered read ports for the
  // skewed systolic feed; aux exposes one port for the per-cycle elemwise
  // gradient multiplier.
  logic [7:0]         a_rd_row  [TILE_DIM];
  logic [7:0]         a_rd_col  [TILE_DIM];
  logic signed [31:0] a_rd_data [TILE_DIM];
  logic [7:0]         b_rd_row  [TILE_DIM];
  logic [7:0]         b_rd_col  [TILE_DIM];
  logic signed [31:0] b_rd_data [TILE_DIM];
  logic [7:0]         aux_rd_row;
  logic [7:0]         aux_rd_col;
  logic signed [31:0] aux_rd_data;

  // Pipeline -> output buffer
  logic               out_wr_en;
  logic [11:0]        out_wr_idx;
  logic signed [31:0] out_wr_data;
  logic [11:0]        out_rd_idx;
  logic signed [31:0] out_rd_data;

  // Tied-off single-element read ports on buffers (multi-port interface
  // is the active one for the streaming pipeline)
  logic signed [31:0] unused_buf_a_2d, unused_buf_b_2d, unused_buf_aux_2d;
  logic signed [31:0] unused_buf_a_lin, unused_buf_b_lin, unused_buf_aux_lin;
  logic signed [31:0] unused_out_2d;

  // Output buffer has a one-port read interface tied off (FSM uses the
  // linear read for drain, no scattered reads needed).
  logic [7:0]         unused_out_mp_row [1];
  logic [7:0]         unused_out_mp_col [1];
  logic signed [31:0] unused_out_mp_data [1];
  assign unused_out_mp_row[0] = 8'd0;
  assign unused_out_mp_col[0] = 8'd0;

  // Pipeline boundary
  logic pipeline_start, pipeline_done, pipeline_running;

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
    .sram_req       (sram_req),
    .sram_we        (sram_we),
    .sram_addr      (sram_addr),
    .sram_wdata     (sram_wdata),
    .sram_rdata     (sram_rdata),
    .sram_rvalid    (sram_rvalid),
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

  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM), .NUM_RD_PORTS(TILE_DIM)) u_buf_a (
    .clk(clk), .rst_n(rst_n),
    .wr_en(buf_a_wr_en), .wr_idx(buf_wr_idx), .wr_data($signed(buf_wr_data)),
    .rd_row(8'd0), .rd_col(8'd0), .rd_data(unused_buf_a_2d),
    .rd_lin_idx(12'd0), .rd_lin_data(unused_buf_a_lin),
    .mp_rd_row(a_rd_row), .mp_rd_col(a_rd_col), .mp_rd_data(a_rd_data)
  );

  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM), .NUM_RD_PORTS(TILE_DIM)) u_buf_b (
    .clk(clk), .rst_n(rst_n),
    .wr_en(buf_b_wr_en), .wr_idx(buf_wr_idx), .wr_data($signed(buf_wr_data)),
    .rd_row(8'd0), .rd_col(8'd0), .rd_data(unused_buf_b_2d),
    .rd_lin_idx(12'd0), .rd_lin_data(unused_buf_b_lin),
    .mp_rd_row(b_rd_row), .mp_rd_col(b_rd_col), .mp_rd_data(b_rd_data)
  );

  // Aux buffer only needs one parallel-read port (per-cycle elemwise read).
  // Wrap the scalar pipeline ports into 1-element arrays for the buffer.
  logic [7:0]         aux_mp_row [1];
  logic [7:0]         aux_mp_col [1];
  logic signed [31:0] aux_mp_data [1];
  assign aux_mp_row[0]  = aux_rd_row;
  assign aux_mp_col[0]  = aux_rd_col;
  assign aux_rd_data    = aux_mp_data[0];

  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM), .NUM_RD_PORTS(1)) u_buf_aux (
    .clk(clk), .rst_n(rst_n),
    .wr_en(buf_aux_wr_en), .wr_idx(buf_wr_idx), .wr_data($signed(buf_wr_data)),
    .rd_row(8'd0), .rd_col(8'd0), .rd_data(unused_buf_aux_2d),
    .rd_lin_idx(12'd0), .rd_lin_data(unused_buf_aux_lin),
    .mp_rd_row(aux_mp_row), .mp_rd_col(aux_mp_col), .mp_rd_data(aux_mp_data)
  );

  stream_pipeline #(.DATA_WIDTH(32), .ARRAY_DIM(TILE_DIM)) u_pipe (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (pipeline_start),
    .done        (pipeline_done),
    .tile_m      (ctrl_tile_m),
    .tile_n      (ctrl_tile_n),
    .tile_k      (ctrl_tile_k),
    .op_sel      (fused_sel),
    .a_rd_row    (a_rd_row),
    .a_rd_col    (a_rd_col),
    .a_rd_data   (a_rd_data),
    .b_rd_row    (b_rd_row),
    .b_rd_col    (b_rd_col),
    .b_rd_data   (b_rd_data),
    .aux_rd_row  (aux_rd_row),
    .aux_rd_col  (aux_rd_col),
    .aux_rd_data (aux_rd_data),
    .out_wr_en   (out_wr_en),
    .out_wr_idx  (out_wr_idx),
    .out_wr_data (out_wr_data),
    .running_o   (pipeline_running)
  );

  tile_buffer #(.DATA_WIDTH(32), .TILE_DIM(TILE_DIM), .NUM_RD_PORTS(1)) u_buf_out (
    .clk(clk), .rst_n(rst_n),
    .wr_en(out_wr_en), .wr_idx(out_wr_idx), .wr_data(out_wr_data),
    .rd_row(8'd0), .rd_col(8'd0), .rd_data(unused_out_2d),
    .rd_lin_idx(out_rd_idx), .rd_lin_data(out_rd_data),
    .mp_rd_row(unused_out_mp_row), .mp_rd_col(unused_out_mp_col),
    .mp_rd_data(unused_out_mp_data)
  );

  perf_counter_block u_perf (
    .clk            (clk),
    .rst_n          (rst_n),
    .clear          (!rst_n),
    .array_active   (pipeline_start || pipeline_running),
    .array_stall    (busy && !pipeline_running),
    .tile_complete  (pipeline_done),
    .active_cycles  (perf_active_cycles),
    .stall_cycles   (perf_stall_cycles),
    .total_cycles   (),
    .tiles_completed(perf_tiles_completed)
  );

endmodule
