/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// stream_pipeline.v -- hand-flattened from project/m2/rtl/stream_pipeline.sv
//
// Streaming fused compute pipeline: feeder -> systolic -> (elemwise or
// softmax) -> output. Once `start` pulses, runs autonomously until `done`.
//
// Conversions:
//   - unpacked-array ports (a_rd_row/col/data, b_rd_row/col/data) flattened
//     to packed buses to match the upstream tile_buffer.v port layout;
//   - c_out_array (was logic[31:0] [ARRAY_DIM][ARRAY_DIM]) replaced with a
//     flat packed wire matching systolic_array_64x64.v c_out output;
//   - sm_row_buf 2D array replaced with a flat memory indexed by
//     (row*ARRAY_DIM + col).
//   - generate blocks for skewed feed kept;
//   - fused_op_t enum encoded as 3-bit localparams.
// =============================================================================
module stream_pipeline (
    clk,
    rst_n,
    start,
    done,
    tile_m,
    tile_n,
    tile_k,
    op_sel,
    a_rd_row,
    a_rd_col,
    a_rd_data,
    b_rd_row,
    b_rd_col,
    b_rd_data,
    aux_rd_row,
    aux_rd_col,
    aux_rd_data,
    out_wr_en,
    out_wr_idx,
    out_wr_data,
    running_o
);

    parameter DATA_WIDTH = 32;
    parameter ARRAY_DIM  = 64;

    localparam [2:0] FUSED_SOFTMAX = 3'd3;
    // M5 Item B: mac_pe_piped adds +1 cycle of MAC latency, so the
    // systolic array needs one more cycle to drain its last accumulator.
    // 5 instead of the legacy 4 -- back to 4 if mac_pe (not _piped) is
    // restored in v_hand/systolic_array_64x64.v.
    localparam DRAIN_CYCLES = 5;
    localparam FUSED_DEPTH  = 7;
    // M4: softmax_unit_lut latency = 7 + N_PHASES, where
    // N_PHASES = ceil(ARRAY_DIM / min(ARRAY_DIM, 8)). At default
    // top_small scope ARRAY_DIM=2 -> N_PHASES=1 -> SOFTMAX_LAT=8.
    // At ARRAY_DIM=64 -> N_PHASES=8 -> SOFTMAX_LAT=15.
    localparam LUT_N_BANKS  = (ARRAY_DIM < 8) ? ARRAY_DIM : 8;
    localparam LUT_N_PHASES = (ARRAY_DIM + LUT_N_BANKS - 1) / LUT_N_BANKS;
    localparam SOFTMAX_LAT  = 7 + LUT_N_PHASES;

    input  wire                                  clk;
    input  wire                                  rst_n;
    input  wire                                  start;
    output reg                                   done;
    input  wire [7:0]                            tile_m;
    input  wire [7:0]                            tile_n;
    input  wire [7:0]                            tile_k;
    input  wire [2:0]                            op_sel;

    output wire [(ARRAY_DIM*8)-1:0]              a_rd_row;
    output wire [(ARRAY_DIM*8)-1:0]              a_rd_col;
    input  wire [(ARRAY_DIM*DATA_WIDTH)-1:0]     a_rd_data;

    output wire [(ARRAY_DIM*8)-1:0]              b_rd_row;
    output wire [(ARRAY_DIM*8)-1:0]              b_rd_col;
    input  wire [(ARRAY_DIM*DATA_WIDTH)-1:0]     b_rd_data;

    output wire [7:0]                            aux_rd_row;
    output wire [7:0]                            aux_rd_col;
    input  wire signed [DATA_WIDTH-1:0]          aux_rd_data;

    output wire                                  out_wr_en;
    output wire [11:0]                           out_wr_idx;
    output wire signed [DATA_WIDTH-1:0]          out_wr_data;

    output wire                                  running_o;

    // ===== Phase counter =====
    reg [15:0] cycle_cnt;
    reg        running;
    assign running_o = running;

    wire softmax_mode = (op_sel == FUSED_SOFTMAX);

    wire [15:0] feed_end       = {8'b0, tile_m} + {8'b0, tile_n}
                                                + {8'b0, tile_k} + 16'd2;
    wire [15:0] output_start   = feed_end + DRAIN_CYCLES;
    wire [15:0] output_end     = output_start +
                                 ({8'b0, tile_m} * {8'b0, tile_n});
    wire [15:0] elemwise_end   = output_end + FUSED_DEPTH;

    wire [15:0] sm_feed_end      = output_start + {8'b0, tile_m};
    wire [15:0] sm_capture_start = output_start + SOFTMAX_LAT;
    wire [15:0] sm_capture_end   = sm_capture_start + {8'b0, tile_m};
    wire [15:0] sm_walk_start    = sm_capture_end;
    wire [15:0] sm_walk_end      = sm_walk_start +
                                   ({8'b0, tile_m} * {8'b0, tile_n});

    wire [15:0] all_end = softmax_mode ? sm_walk_end : elemwise_end;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_cnt <= 16'd0;
            running   <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !running) begin
                running   <= 1'b1;
                cycle_cnt <= 16'd0;
            end else if (running) begin
                cycle_cnt <= cycle_cnt + 16'd1;
                if (cycle_cnt >= all_end) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                end
            end
        end
    end

    // ===== Stage 1: skewed-feed driving tile_buffer multi-port reads =====
    wire feed_active  = running && (cycle_cnt < feed_end);
    wire array_clear  = running && (cycle_cnt == 16'd0);

    // Packed forms of the systolic input vectors.
    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] a_in_array_pkt;
    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] b_in_array_pkt;

    genvar gr, gc;
    generate
        for (gr = 0; gr < ARRAY_DIM; gr = gr + 1) begin : gen_feed_a
            wire [15:0] feed_idx_a = cycle_cnt - 16'd1 - gr;
            wire feed_valid_a = feed_active &&
                                (cycle_cnt > gr) &&
                                (gr < {8'b0, tile_m}) &&
                                (feed_idx_a < {8'b0, tile_k});

            assign a_rd_row[(gr*8) +: 8] = gr[7:0];
            assign a_rd_col[(gr*8) +: 8] =
                feed_valid_a ? feed_idx_a[7:0] : 8'd0;

            assign a_in_array_pkt[(gr*DATA_WIDTH) +: DATA_WIDTH] =
                feed_valid_a ? a_rd_data[(gr*DATA_WIDTH) +: DATA_WIDTH]
                             : {DATA_WIDTH{1'b0}};
        end
        for (gc = 0; gc < ARRAY_DIM; gc = gc + 1) begin : gen_feed_b
            wire [15:0] feed_idx_b = cycle_cnt - 16'd1 - gc;
            wire feed_valid_b = feed_active &&
                                (cycle_cnt > gc) &&
                                (gc < {8'b0, tile_n}) &&
                                (feed_idx_b < {8'b0, tile_k});

            assign b_rd_row[(gc*8) +: 8] =
                feed_valid_b ? feed_idx_b[7:0] : 8'd0;
            assign b_rd_col[(gc*8) +: 8] = gc[7:0];

            assign b_in_array_pkt[(gc*DATA_WIDTH) +: DATA_WIDTH] =
                feed_valid_b ? b_rd_data[(gc*DATA_WIDTH) +: DATA_WIDTH]
                             : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    // ===== Stage 2: systolic array =====
    wire [(ARRAY_DIM*ARRAY_DIM*DATA_WIDTH)-1:0] c_out_pkt;

    systolic_array_64x64 #(
        .ROWS       (ARRAY_DIM),
        .COLS       (ARRAY_DIM),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (feed_active),
        .clear_acc (array_clear),
        .a_in      (a_in_array_pkt),
        .b_in      (b_in_array_pkt),
        .c_out     (c_out_pkt)
    );

    // ===== Stage 3a: elemwise output mux + fused unit =====
    wire out_active = !softmax_mode && running &&
                      (cycle_cnt >= output_start) &&
                      (cycle_cnt <  output_end);

    reg [7:0] out_row_cnt, out_col_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_row_cnt <= 8'd0;
            out_col_cnt <= 8'd0;
        end else if (start && !running) begin
            out_row_cnt <= 8'd0;
            out_col_cnt <= 8'd0;
        end else if (out_active) begin
            if (out_col_cnt + 8'd1 >= tile_n) begin
                out_col_cnt <= 8'd0;
                out_row_cnt <= out_row_cnt + 8'd1;
            end else begin
                out_col_cnt <= out_col_cnt + 8'd1;
            end
        end
    end

    wire [31:0] mux_data =
        c_out_pkt[((({8'b0, out_row_cnt[5:0]} * ARRAY_DIM)
                    + {8'b0, out_col_cnt[5:0]}) * DATA_WIDTH) +: DATA_WIDTH];

    assign aux_rd_row = out_row_cnt;
    assign aux_rd_col = out_col_cnt;
    wire signed [31:0] aux_data = aux_rd_data;

    wire signed [31:0] fused_out;
    wire               fused_valid;

    fused_postproc_unit #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_fused (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .op_sel    (op_sel),
        .data_in   (mux_data),
        .in_valid  (out_active),
        .aux_in    (aux_data),
        .data_out  (fused_out),
        .out_valid (fused_valid)
    );

    reg [7:0] coll_row_cnt, coll_col_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coll_row_cnt <= 8'd0;
            coll_col_cnt <= 8'd0;
        end else if (start && !running) begin
            coll_row_cnt <= 8'd0;
            coll_col_cnt <= 8'd0;
        end else if (fused_valid && running && !softmax_mode) begin
            if (coll_col_cnt + 8'd1 >= tile_n) begin
                coll_col_cnt <= 8'd0;
                coll_row_cnt <= coll_row_cnt + 8'd1;
            end else begin
                coll_col_cnt <= coll_col_cnt + 8'd1;
            end
        end
    end

    // ===== Stage 3b: softmax path =====
    wire [15:0] sm_in_offset      = cycle_cnt - output_start;
    wire [15:0] sm_capture_offset = cycle_cnt - sm_capture_start;

    wire        sm_in_valid = softmax_mode && running &&
                              (cycle_cnt >= output_start) &&
                              (cycle_cnt <  sm_feed_end);
    wire [7:0]  sm_in_row   = sm_in_offset[7:0];

    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] sm_scores_in_pkt;
    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] sm_probs_out_pkt;
    wire                              sm_out_valid;

    genvar gsi;
    generate
        for (gsi = 0; gsi < ARRAY_DIM; gsi = gsi + 1) begin : gen_sm_scores
            assign sm_scores_in_pkt[(gsi*DATA_WIDTH) +: DATA_WIDTH] =
                sm_in_valid
                    ? c_out_pkt[(({8'b0, sm_in_row[5:0]} * ARRAY_DIM + gsi)
                                  * DATA_WIDTH) +: DATA_WIDTH]
                    : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    // M4 Option C: LUT exp + sequential 1/sum (drop-in port-compatible).
    // N_LUT_BANKS defaults to min(VEC_LEN, 8) per the module; no override
    // needed at this instance.
    softmax_unit_lut #(
        .DATA_WIDTH (DATA_WIDTH),
        .VEC_LEN    (ARRAY_DIM)
    ) u_softmax (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .start     (1'b0),
        .vec_len   (tile_n),
        .scores_in (sm_scores_in_pkt),
        .in_valid  (sm_in_valid),
        .probs_out (sm_probs_out_pkt),
        .out_valid (sm_out_valid)
    );

    wire        sm_capture_active = softmax_mode && sm_out_valid &&
                                    (cycle_cnt >= sm_capture_start) &&
                                    (cycle_cnt <  sm_capture_end);
    wire [7:0]  sm_capture_row    = sm_capture_offset[7:0];

    // Flat 2D row-buffer for softmax results.
    reg [DATA_WIDTH-1:0] sm_row_buf [0:(ARRAY_DIM*ARRAY_DIM)-1];

    integer init_r, init_c, cap_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (init_r = 0; init_r < ARRAY_DIM; init_r = init_r + 1)
                for (init_c = 0; init_c < ARRAY_DIM; init_c = init_c + 1)
                    sm_row_buf[init_r*ARRAY_DIM + init_c]
                        <= {DATA_WIDTH{1'b0}};
        end else if (sm_capture_active) begin
            for (cap_c = 0; cap_c < ARRAY_DIM; cap_c = cap_c + 1)
                sm_row_buf[sm_capture_row[5:0]*ARRAY_DIM + cap_c] <=
                    sm_probs_out_pkt[(cap_c*DATA_WIDTH) +: DATA_WIDTH];
        end
    end

    wire        sm_walk_active = softmax_mode && running &&
                                 (cycle_cnt >= sm_walk_start) &&
                                 (cycle_cnt <  sm_walk_end);
    reg [7:0]   sm_walk_row_cnt, sm_walk_col_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_walk_row_cnt <= 8'd0;
            sm_walk_col_cnt <= 8'd0;
        end else if (start && !running) begin
            sm_walk_row_cnt <= 8'd0;
            sm_walk_col_cnt <= 8'd0;
        end else if (sm_walk_active) begin
            if (sm_walk_col_cnt + 8'd1 >= tile_n) begin
                sm_walk_col_cnt <= 8'd0;
                sm_walk_row_cnt <= sm_walk_row_cnt + 8'd1;
            end else begin
                sm_walk_col_cnt <= sm_walk_col_cnt + 8'd1;
            end
        end
    end

    // ===== Stage 4: output write mux =====
    wire        wr_en_em  = !softmax_mode && fused_valid && running;
    wire [11:0] wr_idx_em = {coll_row_cnt[5:0], coll_col_cnt[5:0]};
    wire signed [31:0] wr_data_em = fused_out;

    wire        wr_en_sm  = sm_walk_active;
    wire [11:0] wr_idx_sm = {sm_walk_row_cnt[5:0], sm_walk_col_cnt[5:0]};
    wire signed [31:0] wr_data_sm =
        sm_row_buf[sm_walk_row_cnt[5:0]*ARRAY_DIM + sm_walk_col_cnt[5:0]];

    assign out_wr_en   = softmax_mode ? wr_en_sm   : wr_en_em;
    assign out_wr_idx  = softmax_mode ? wr_idx_sm  : wr_idx_em;
    assign out_wr_data = softmax_mode ? wr_data_sm : wr_data_em;

endmodule
