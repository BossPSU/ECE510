// stream_pipeline.sv — Streaming fused compute pipeline
// Once `start` asserts, runs autonomously to completion. No FSM micromanagement.
//
// Internal stages (all continuously active during `running`):
//   feeder -> systolic -> [elemwise path | softmax path] -> output buffer
//
// Intermediates flow through registers, NEVER materialize in SRAM.
// This is the "fusion" — the FSM only sees start/done at the boundaries.
//
// FULL M x N x K SUPPORT:
//   Input buffers expose their full memory (a_mem, b_mem). The feeder
//   constructs the proper output-stationary skewed feed:
//     a_in[r] at cycle (s+1) = A[r][s-r]   if r < tile_m and s-r in [0, tile_k)
//     b_in[c] at cycle (s+1) = B[s-c][c]   if c < tile_n and s-c in [0, tile_k)
//   PE[r][c] then accumulates A[r][k]*B[k][c] for k in [0, tile_k).
//
// TWO POST-PROCESSING PATHS:
//   Elemwise (GELU, GELU_GRAD, BYPASS, MASK):
//     Output mux walks all tile_m * tile_n cells through the fused unit.
//   Softmax:
//     Feed entire c_out row to softmax_unit in parallel (one row/cycle).
//     After SOFTMAX_LAT cycles, capture probs_out rows into a 2D buffer.
//     Then walk the buffer to the output buffer one element/cycle.
module stream_pipeline
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int ARRAY_DIM  = ARRAY_ROWS  // square array
)(
  input  logic                            clk,
  input  logic                            rst_n,

  // Boundary control
  input  logic                            start,        // pulse to begin
  output logic                            done,         // pulse when complete
  input  logic [7:0]                      tile_m,       // result rows
  input  logic [7:0]                      tile_n,       // result cols
  input  logic [7:0]                      tile_k,       // shared dim
  input  fused_op_t                       op_sel,       // GELU / GELU' / softmax / bypass

  // Full input-buffer memories (combinational, for parallel feed)
  input  logic signed [DATA_WIDTH-1:0]    a_mem [ARRAY_DIM][ARRAY_DIM],
  input  logic signed [DATA_WIDTH-1:0]    b_mem [ARRAY_DIM][ARRAY_DIM],

  // Write interface to output buffer ({row[5:0], col[5:0]})
  output logic                            out_wr_en,
  output logic [11:0]                     out_wr_idx,
  output logic signed [DATA_WIDTH-1:0]    out_wr_data
);

  // ==========================================================
  // Phase counter — drives all internal stages without an FSM
  // ==========================================================

  logic [15:0] cycle_cnt;
  logic        running;

  localparam int DRAIN_CYCLES   = 4;
  localparam int FUSED_DEPTH    = 7;
  localparam int SOFTMAX_LAT    = 4;  // softmax_unit pipeline depth

  logic        softmax_mode;
  assign softmax_mode = (op_sel == FUSED_SOFTMAX);

  logic [15:0] feed_end, output_start, output_end, elemwise_end;
  assign feed_end     = {8'b0, tile_m} + {8'b0, tile_n} + {8'b0, tile_k} + 16'd2;
  assign output_start = feed_end + 16'(DRAIN_CYCLES);
  assign output_end   = output_start + ({8'b0, tile_m} * {8'b0, tile_n});
  assign elemwise_end = output_end + 16'(FUSED_DEPTH);

  // Softmax phase boundaries
  logic [15:0] sm_feed_end, sm_capture_start, sm_capture_end;
  logic [15:0] sm_walk_start, sm_walk_end;
  assign sm_feed_end      = output_start + {8'b0, tile_m};
  assign sm_capture_start = output_start + 16'(SOFTMAX_LAT);
  assign sm_capture_end   = sm_capture_start + {8'b0, tile_m};
  assign sm_walk_start    = sm_capture_end;
  assign sm_walk_end      = sm_walk_start + ({8'b0, tile_m} * {8'b0, tile_n});

  // all_end picks the longer path
  logic [15:0] all_end;
  assign all_end = softmax_mode ? sm_walk_end : elemwise_end;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt <= '0;
      running   <= 1'b0;
      done      <= 1'b0;
    end else begin
      done <= 1'b0;
      if (start && !running) begin
        running   <= 1'b1;
        cycle_cnt <= '0;
      end else if (running) begin
        cycle_cnt <= cycle_cnt + 16'd1;
        if (cycle_cnt >= all_end) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end

  // ==========================================================
  // Stage 1: Feeder — skewed input streams
  // ==========================================================
  logic feed_active;
  assign feed_active = running && (cycle_cnt < feed_end);

  // Clear accumulators at cycle_cnt == 0 (with en=1 and a/b=0 -> acc cleared)
  logic array_clear;
  assign array_clear = running && (cycle_cnt == 16'd0);

  logic signed [31:0] a_in_array [ARRAY_DIM];
  logic signed [31:0] b_in_array [ARRAY_DIM];

  logic        feed_valid_a [ARRAY_DIM];
  logic        feed_valid_b [ARRAY_DIM];
  logic [15:0] feed_idx_a   [ARRAY_DIM];  // s - r
  logic [15:0] feed_idx_b   [ARRAY_DIM];  // s - c

  genvar gr, gc;
  generate
    for (gr = 0; gr < ARRAY_DIM; gr++) begin : gen_feed_a
      assign feed_idx_a[gr]   = cycle_cnt - 16'd1 - 16'(gr);
      assign feed_valid_a[gr] = feed_active &&
                                (cycle_cnt > 16'(gr)) &&
                                (16'(gr) < {8'b0, tile_m}) &&
                                (feed_idx_a[gr] < {8'b0, tile_k});
      assign a_in_array[gr]   = feed_valid_a[gr] ? a_mem[gr][feed_idx_a[gr][5:0]]
                                                 : 32'sd0;
    end
    for (gc = 0; gc < ARRAY_DIM; gc++) begin : gen_feed_b
      assign feed_idx_b[gc]   = cycle_cnt - 16'd1 - 16'(gc);
      assign feed_valid_b[gc] = feed_active &&
                                (cycle_cnt > 16'(gc)) &&
                                (16'(gc) < {8'b0, tile_n}) &&
                                (feed_idx_b[gc] < {8'b0, tile_k});
      assign b_in_array[gc]   = feed_valid_b[gc] ? b_mem[feed_idx_b[gc][5:0]][gc]
                                                 : 32'sd0;
    end
  endgenerate

  // ==========================================================
  // Stage 2: Systolic array — output-stationary, full ARRAY_DIM x ARRAY_DIM
  // ==========================================================
  logic signed [31:0] c_out_array [ARRAY_DIM][ARRAY_DIM];

  systolic_array_64x64 #(
    .ROWS       (ARRAY_DIM),
    .COLS       (ARRAY_DIM),
    .DATA_WIDTH (32)
  ) u_array (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (feed_active),
    .clear_acc (array_clear),
    .a_in      (a_in_array),
    .b_in      (b_in_array),
    .c_out     (c_out_array)
  );

  // ==========================================================
  // Stage 3a: Elemwise output mux + fused unit
  //   Active for non-softmax modes only.
  // ==========================================================
  logic       out_active;
  logic [7:0] out_row_cnt, out_col_cnt;

  assign out_active = !softmax_mode && running &&
                      (cycle_cnt >= output_start) &&
                      (cycle_cnt <  output_end);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_row_cnt <= '0;
      out_col_cnt <= '0;
    end else if (start && !running) begin
      out_row_cnt <= '0;
      out_col_cnt <= '0;
    end else if (out_active) begin
      if (out_col_cnt + 8'd1 >= tile_n) begin
        out_col_cnt <= '0;
        out_row_cnt <= out_row_cnt + 8'd1;
      end else begin
        out_col_cnt <= out_col_cnt + 8'd1;
      end
    end
  end

  logic signed [31:0] mux_data;
  assign mux_data = c_out_array[out_row_cnt[5:0]][out_col_cnt[5:0]];

  // Fused activation (GELU, GELU_GRAD, BYPASS, MASK)
  logic signed [31:0] fused_out;
  logic               fused_valid;

  fused_postproc_unit #(.DATA_WIDTH(32)) u_fused (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (1'b1),
    .op_sel    (op_sel),
    .data_in   (mux_data),
    .in_valid  (out_active),
    .aux_in    (mux_data),         // pre-activation = c_out itself for GELU_GRAD
    .data_out  (fused_out),
    .out_valid (fused_valid)
  );

  // Elemwise collector (independent counter to absorb fused-pipe latency)
  logic [7:0] coll_row_cnt, coll_col_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      coll_row_cnt <= '0;
      coll_col_cnt <= '0;
    end else if (start && !running) begin
      coll_row_cnt <= '0;
      coll_col_cnt <= '0;
    end else if (fused_valid && running && !softmax_mode) begin
      if (coll_col_cnt + 8'd1 >= tile_n) begin
        coll_col_cnt <= '0;
        coll_row_cnt <= coll_row_cnt + 8'd1;
      end else begin
        coll_col_cnt <= coll_col_cnt + 8'd1;
      end
    end
  end

  // ==========================================================
  // Stage 3b: Softmax path
  //   Feed c_out rows in parallel (one row/cycle for tile_m cycles).
  //   Capture probs_out rows after SOFTMAX_LAT into a 2D buffer.
  //   Walk the buffer out one element/cycle.
  // ==========================================================
  logic [15:0] sm_in_offset, sm_capture_offset;
  assign sm_in_offset      = cycle_cnt - output_start;
  assign sm_capture_offset = cycle_cnt - sm_capture_start;

  logic       sm_in_valid;
  logic [7:0] sm_in_row;
  assign sm_in_valid = softmax_mode && running &&
                       (cycle_cnt >= output_start) &&
                       (cycle_cnt <  sm_feed_end);
  assign sm_in_row   = sm_in_offset[7:0];

  logic signed [31:0] sm_scores_in [ARRAY_DIM];
  logic signed [31:0] sm_probs_out [ARRAY_DIM];
  logic               sm_out_valid;

  genvar gsi;
  generate
    for (gsi = 0; gsi < ARRAY_DIM; gsi++) begin : gen_sm_scores
      assign sm_scores_in[gsi] = sm_in_valid ? c_out_array[sm_in_row[5:0]][gsi]
                                             : 32'sd0;
    end
  endgenerate

  softmax_unit #(
    .DATA_WIDTH (32),
    .VEC_LEN    (ARRAY_DIM)
  ) u_softmax (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (1'b1),
    .start     (1'b0),  // unused inside softmax_unit
    .vec_len   (tile_n),
    .scores_in (sm_scores_in),
    .in_valid  (sm_in_valid),
    .probs_out (sm_probs_out),
    .out_valid (sm_out_valid)
  );

  // Capture softmax output rows
  logic       sm_capture_active;
  logic [7:0] sm_capture_row;
  assign sm_capture_active = softmax_mode && sm_out_valid &&
                             (cycle_cnt >= sm_capture_start) &&
                             (cycle_cnt <  sm_capture_end);
  assign sm_capture_row    = sm_capture_offset[7:0];

  logic signed [31:0] sm_row_buf [ARRAY_DIM][ARRAY_DIM];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int r = 0; r < ARRAY_DIM; r++)
        for (int c = 0; c < ARRAY_DIM; c++)
          sm_row_buf[r][c] <= '0;
    end else if (sm_capture_active) begin
      for (int c = 0; c < ARRAY_DIM; c++)
        sm_row_buf[sm_capture_row[5:0]][c] <= sm_probs_out[c];
    end
  end

  // Walk softmax output buffer out one elem/cycle
  logic       sm_walk_active;
  logic [7:0] sm_walk_row_cnt, sm_walk_col_cnt;

  assign sm_walk_active = softmax_mode && running &&
                          (cycle_cnt >= sm_walk_start) &&
                          (cycle_cnt <  sm_walk_end);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sm_walk_row_cnt <= '0;
      sm_walk_col_cnt <= '0;
    end else if (start && !running) begin
      sm_walk_row_cnt <= '0;
      sm_walk_col_cnt <= '0;
    end else if (sm_walk_active) begin
      if (sm_walk_col_cnt + 8'd1 >= tile_n) begin
        sm_walk_col_cnt <= '0;
        sm_walk_row_cnt <= sm_walk_row_cnt + 8'd1;
      end else begin
        sm_walk_col_cnt <= sm_walk_col_cnt + 8'd1;
      end
    end
  end

  // ==========================================================
  // Stage 4: Output buffer write port — mux between elemwise and softmax
  // ==========================================================
  logic               wr_en_em, wr_en_sm;
  logic [11:0]        wr_idx_em, wr_idx_sm;
  logic signed [31:0] wr_data_em, wr_data_sm;

  assign wr_en_em   = !softmax_mode && fused_valid && running;
  assign wr_idx_em  = {coll_row_cnt[5:0], coll_col_cnt[5:0]};
  assign wr_data_em = fused_out;

  assign wr_en_sm   = sm_walk_active;
  assign wr_idx_sm  = {sm_walk_row_cnt[5:0], sm_walk_col_cnt[5:0]};
  assign wr_data_sm = sm_row_buf[sm_walk_row_cnt[5:0]][sm_walk_col_cnt[5:0]];

  assign out_wr_en   = softmax_mode ? wr_en_sm   : wr_en_em;
  assign out_wr_idx  = softmax_mode ? wr_idx_sm  : wr_idx_em;
  assign out_wr_data = softmax_mode ? wr_data_sm : wr_data_em;

endmodule
