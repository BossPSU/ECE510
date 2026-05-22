/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// accel_engine.v -- hand-flattened from project/m2/rtl/accel_engine.sv
//
// Per-lane compute engine: accel_controller + 4 tile_buffers + stream_pipeline
// + perf_counter_block. TILE_DIM is fixed to the (scoped) M2 TILE_SIZE via a
// localparam at the top of this file -- the M3 OpenLane build sets TILE_DIM=4
// (override via -P at synth time), the cosim path is unchanged.
//
// Conversions:
//   - cmd_pkt_t replaced with a flat 99-bit bus on the cmd port;
//   - per-lane multi-port tile_buffer read interfaces flattened to packed
//     buses (matches tile_buffer.v's mp_rd_* port style);
//   - aux buffer wrapped one-element multi-port shimmed inline;
//   - all in-block declarations hoisted; SV `always_ff` -> `always`.
// =============================================================================
module accel_engine #(
    parameter TILE_DIM = 64
) (
    clk,
    rst_n,
    cmd_in,
    cmd_valid,
    cmd_ready,
    sram_req,
    sram_we,
    sram_addr,
    sram_wdata,
    sram_rdata,
    sram_rvalid,
    busy,
    done,
    perf_active_cycles,
    perf_stall_cycles,
    perf_tiles_completed
);

    localparam CMD_W = 99;

    input  wire             clk;
    input  wire             rst_n;
    input  wire [CMD_W-1:0] cmd_in;
    input  wire             cmd_valid;
    output wire             cmd_ready;
    output wire             sram_req;
    output wire             sram_we;
    output wire [15:0]      sram_addr;
    output wire [31:0]      sram_wdata;
    input  wire [31:0]      sram_rdata;
    input  wire             sram_rvalid;
    output wire             busy;
    output wire             done;
    output wire [31:0]      perf_active_cycles;
    output wire [31:0]      perf_stall_cycles;
    output wire [31:0]      perf_tiles_completed;

    // Controller <-> rest
    wire [7:0]  ctrl_tile_m, ctrl_tile_n, ctrl_tile_k;
    wire [2:0]  fused_sel;

    wire        buf_a_wr_en, buf_b_wr_en, buf_aux_wr_en;
    wire [11:0] buf_wr_idx;
    wire [31:0] buf_wr_data;

    // Tile buffer A: TILE_DIM read ports for the systolic feed.
    wire [(TILE_DIM*8)-1:0]  a_rd_row;
    wire [(TILE_DIM*8)-1:0]  a_rd_col;
    wire [(TILE_DIM*32)-1:0] a_rd_data;

    wire [(TILE_DIM*8)-1:0]  b_rd_row;
    wire [(TILE_DIM*8)-1:0]  b_rd_col;
    wire [(TILE_DIM*32)-1:0] b_rd_data;

    // Aux buffer: single read port. Wrap with the multi-port-of-1 schema
    // that tile_buffer.v exposes (mp_rd_row/col/data each 8/8/32 bits).
    wire [7:0]  aux_rd_row;
    wire [7:0]  aux_rd_col;
    wire [31:0] aux_rd_data;

    // Output buffer drives wr_en/idx/data from the stream_pipeline.
    wire        out_wr_en;
    wire [11:0] out_wr_idx;
    wire [31:0] out_wr_data;
    wire [11:0] out_rd_idx;
    wire [31:0] out_rd_data;

    // Tied-off single-element read ports (multi-port is what stream_pipeline
    // actually consumes; the linear/2D scalar reads are unused on A/B/aux).
    wire [31:0] unused_buf_a_2d;
    wire [31:0] unused_buf_b_2d;
    wire [31:0] unused_buf_aux_2d;
    wire [31:0] unused_buf_a_lin;
    wire [31:0] unused_buf_b_lin;
    wire [31:0] unused_buf_aux_lin;
    wire [31:0] unused_out_2d;
    wire [7:0]  unused_out_mp_row = 8'd0;
    wire [7:0]  unused_out_mp_col = 8'd0;
    wire [31:0] unused_out_mp_data;

    wire pipeline_start, pipeline_done, pipeline_running;

    // ===== Controller =====
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

    // ===== Tile buffers =====
    tile_buffer #(
        .DATA_WIDTH   (32),
        .TILE_DIM     (TILE_DIM),
        .NUM_RD_PORTS (TILE_DIM)
    ) u_buf_a (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (buf_a_wr_en),
        .wr_idx      (buf_wr_idx),
        .wr_data     (buf_wr_data),
        .rd_row      (8'd0),
        .rd_col      (8'd0),
        .rd_data     (unused_buf_a_2d),
        .rd_lin_idx  (12'd0),
        .rd_lin_data (unused_buf_a_lin),
        .mp_rd_row   (a_rd_row),
        .mp_rd_col   (a_rd_col),
        .mp_rd_data  (a_rd_data)
    );

    tile_buffer #(
        .DATA_WIDTH   (32),
        .TILE_DIM     (TILE_DIM),
        .NUM_RD_PORTS (TILE_DIM)
    ) u_buf_b (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (buf_b_wr_en),
        .wr_idx      (buf_wr_idx),
        .wr_data     (buf_wr_data),
        .rd_row      (8'd0),
        .rd_col      (8'd0),
        .rd_data     (unused_buf_b_2d),
        .rd_lin_idx  (12'd0),
        .rd_lin_data (unused_buf_b_lin),
        .mp_rd_row   (b_rd_row),
        .mp_rd_col   (b_rd_col),
        .mp_rd_data  (b_rd_data)
    );

    tile_buffer #(
        .DATA_WIDTH   (32),
        .TILE_DIM     (TILE_DIM),
        .NUM_RD_PORTS (1)
    ) u_buf_aux (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (buf_aux_wr_en),
        .wr_idx      (buf_wr_idx),
        .wr_data     (buf_wr_data),
        .rd_row      (8'd0),
        .rd_col      (8'd0),
        .rd_data     (unused_buf_aux_2d),
        .rd_lin_idx  (12'd0),
        .rd_lin_data (unused_buf_aux_lin),
        .mp_rd_row   (aux_rd_row),
        .mp_rd_col   (aux_rd_col),
        .mp_rd_data  (aux_rd_data)
    );

    // ===== Streaming pipeline =====
    stream_pipeline #(
        .DATA_WIDTH (32),
        .ARRAY_DIM  (TILE_DIM)
    ) u_pipe (
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

    tile_buffer #(
        .DATA_WIDTH   (32),
        .TILE_DIM     (TILE_DIM),
        .NUM_RD_PORTS (1)
    ) u_buf_out (
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
        .mp_rd_row   (unused_out_mp_row),
        .mp_rd_col   (unused_out_mp_col),
        .mp_rd_data  (unused_out_mp_data)
    );

    // ===== Perf counters =====
    perf_counter_block u_perf (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear           (!rst_n),
        .array_active    (pipeline_start || pipeline_running),
        .array_stall     (busy && !pipeline_running),
        .tile_complete   (pipeline_done),
        .active_cycles   (perf_active_cycles),
        .stall_cycles    (perf_stall_cycles),
        .total_cycles    (),
        .tiles_completed (perf_tiles_completed)
    );

endmodule
