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
    // M5 option D: mac_pe_piped4 adds +3 cycles of MAC latency vs legacy.
    // M6 Tier 1.5 (option B) adds +1 for registered systolic-array
    // input stage. M6 Tier 1.6 (extended option B) adds +1 for the
    // registered tile_buffer address ports.
    //   legacy mac_pe        -> 6
    //   mac_pe_piped (+1)    -> 7
    //   mac_pe_piped4 (+3)   -> 9  (current v_hand selection)
    localparam DRAIN_CYCLES = 9;
    // M6 Tier 2: +2 vs M5 (one for the new fused_postproc output reg,
    // one for the gelu LUT stage-3 split).
    localparam FUSED_DEPTH  = 9;
    // M6 Tier 3: softmax_unit_lut latency now 8 + N_PHASES (was 7 + N_PHASES)
    // -- +1 from the new s5 multiplier-output register.
    localparam LUT_N_BANKS  = (ARRAY_DIM < 8) ? ARRAY_DIM : 8;
    localparam LUT_N_PHASES = (ARRAY_DIM + LUT_N_BANKS - 1) / LUT_N_BANKS;
    localparam SOFTMAX_LAT  = 8 + LUT_N_PHASES;

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

    // ===== Tile-dim shadow registers (Option F) =====
    // Local flops shadowing tile_m / tile_n / tile_k. All downstream
    // logic reads the _r versions so every path that previously
    // launched from a primary input pin now launches from a flop.
    // FSM assumption: tile_m / tile_n / tile_k stable for at least 2
    // cycles before `start` is pulsed.
    reg [7:0] tile_m_r, tile_n_r, tile_k_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_m_r <= 8'd0;
            tile_n_r <= 8'd0;
            tile_k_r <= 8'd0;
        end else begin
            tile_m_r <= tile_m;
            tile_n_r <= tile_n;
            tile_k_r <= tile_k;
        end
    end

    // M6 Tier 1 + Option F: register the per-tile cycle bounds at `start`,
    // and source the bound combinational from tile_m_r / tile_n_r /
    // tile_k_r so the 8x8 multiplier launches from local flops instead
    // of primary input ports.
    wire [15:0] feed_end_c       = {8'b0, tile_m_r} + {8'b0, tile_n_r}
                                                     + {8'b0, tile_k_r} + 16'd2;
    wire [15:0] output_start_c   = feed_end_c + DRAIN_CYCLES;
    wire [15:0] output_end_c     = output_start_c +
                                   ({8'b0, tile_m_r} * {8'b0, tile_n_r});
    wire [15:0] elemwise_end_c   = output_end_c + FUSED_DEPTH;
    // M3-fix: softmax backpressure widens the feed window. SM_ROW_PERIOD
    // = 64 cycles/row (covers the ~48-cycle iterative divider + LUT
    // phases + sideband). Without backpressure the divider couldn't
    // keep up and silently dropped 56/64 rows per tile.
    localparam SM_ROW_PERIOD = 16'd64;
    wire [15:0] sm_feed_end_c      = output_start_c +
                                     ({8'b0, tile_m_r} * SM_ROW_PERIOD);
    wire [15:0] sm_capture_start_c = output_start_c + SOFTMAX_LAT;
    wire [15:0] sm_capture_end_c   = sm_feed_end_c + SM_ROW_PERIOD;
    wire [15:0] sm_walk_start_c    = sm_capture_end_c;
    wire [15:0] sm_walk_end_c      = sm_walk_start_c +
                                     ({8'b0, tile_m_r} * {8'b0, tile_n_r});

    reg [15:0] feed_end;
    reg [15:0] output_start;
    reg [15:0] output_end;
    reg [15:0] elemwise_end;
    reg [15:0] sm_feed_end;
    reg [15:0] sm_capture_start;
    reg [15:0] sm_capture_end;
    reg [15:0] sm_walk_start;
    reg [15:0] sm_walk_end;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_end         <= 16'd0;
            output_start     <= 16'd0;
            output_end       <= 16'd0;
            elemwise_end     <= 16'd0;
            sm_feed_end      <= 16'd0;
            sm_capture_start <= 16'd0;
            sm_capture_end   <= 16'd0;
            sm_walk_start    <= 16'd0;
            sm_walk_end      <= 16'd0;
        end else if (start && !running) begin
            feed_end         <= feed_end_c;
            output_start     <= output_start_c;
            output_end       <= output_end_c;
            elemwise_end     <= elemwise_end_c;
            sm_feed_end      <= sm_feed_end_c;
            sm_capture_start <= sm_capture_start_c;
            sm_capture_end   <= sm_capture_end_c;
            sm_walk_start    <= sm_walk_start_c;
            sm_walk_end      <= sm_walk_end_c;
        end
    end

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

    // ===== Stage 1: skewed-feed combinational =====
    wire feed_active  = running && (cycle_cnt < feed_end);
    wire array_clear  = running && (cycle_cnt == 16'd0);

    // Per-row combinational feed_valid + tile_buffer-address candidates.
    // Option F: comparators read tile_m_r / tile_n_r / tile_k_r (local
    // flops) instead of input ports -- collapses the 400 ps input_delay
    // charge on every per-row feed_valid.
    wire [ARRAY_DIM-1:0]       feed_valid_a_pkt;
    wire [ARRAY_DIM-1:0]       feed_valid_b_pkt;
    wire [(ARRAY_DIM*8)-1:0]   a_rd_col_int_pkt;
    wire [(ARRAY_DIM*8)-1:0]   b_rd_row_int_pkt;

    genvar gr, gc;
    generate
        for (gr = 0; gr < ARRAY_DIM; gr = gr + 1) begin : gen_feed_a
            wire [15:0] feed_idx_a = cycle_cnt - 16'd1 - gr;
            assign feed_valid_a_pkt[gr] =
                feed_active && (cycle_cnt > gr) &&
                (gr < {8'b0, tile_m_r}) &&
                (feed_idx_a < {8'b0, tile_k_r});
            assign a_rd_col_int_pkt[(gr*8) +: 8] =
                feed_valid_a_pkt[gr] ? feed_idx_a[7:0] : 8'd0;
        end
        for (gc = 0; gc < ARRAY_DIM; gc = gc + 1) begin : gen_feed_b
            wire [15:0] feed_idx_b = cycle_cnt - 16'd1 - gc;
            assign feed_valid_b_pkt[gc] =
                feed_active && (cycle_cnt > gc) &&
                (gc < {8'b0, tile_n_r}) &&
                (feed_idx_b < {8'b0, tile_k_r});
            assign b_rd_row_int_pkt[(gc*8) +: 8] =
                feed_valid_b_pkt[gc] ? feed_idx_b[7:0] : 8'd0;
        end
    endgenerate

    // ===== Stage 1.5a: register tile_buffer address + feed_valid =====
    // M6 Tier 1.6 (extended option B). The c06bfee run had 5 of the top
    // 20 violators on a_rd_col / b_rd_row primary output ports at
    // ~-330 ps slack. Registering the address ports collapses the
    // output-port comb path to 0 ps. The qualifier (feed_valid) is
    // registered alongside so the data side AND-gates against the
    // address-aligned bit one cycle later.
    reg  [ARRAY_DIM-1:0]       feed_valid_a_r_pkt;
    reg  [ARRAY_DIM-1:0]       feed_valid_b_r_pkt;
    reg  [(ARRAY_DIM*8)-1:0]   a_rd_col_r_pkt;
    reg  [(ARRAY_DIM*8)-1:0]   b_rd_row_r_pkt;
    reg                        feed_active_p1;
    reg                        array_clear_p1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_valid_a_r_pkt <= {ARRAY_DIM{1'b0}};
            feed_valid_b_r_pkt <= {ARRAY_DIM{1'b0}};
            a_rd_col_r_pkt     <= {(ARRAY_DIM*8){1'b0}};
            b_rd_row_r_pkt     <= {(ARRAY_DIM*8){1'b0}};
            feed_active_p1     <= 1'b0;
            array_clear_p1     <= 1'b0;
        end else begin
            feed_valid_a_r_pkt <= feed_valid_a_pkt;
            feed_valid_b_r_pkt <= feed_valid_b_pkt;
            a_rd_col_r_pkt     <= a_rd_col_int_pkt;
            b_rd_row_r_pkt     <= b_rd_row_int_pkt;
            feed_active_p1     <= feed_active;
            array_clear_p1     <= array_clear;
        end
    end

    // Drive tile_buffer address output ports from registered values.
    assign a_rd_col = a_rd_col_r_pkt;
    assign b_rd_row = b_rd_row_r_pkt;
    generate
        for (gr = 0; gr < ARRAY_DIM; gr = gr + 1) begin : gen_a_rd_row
            assign a_rd_row[(gr*8) +: 8] = gr[7:0];
        end
        for (gc = 0; gc < ARRAY_DIM; gc = gc + 1) begin : gen_b_rd_col
            assign b_rd_col[(gc*8) +: 8] = gc[7:0];
        end
    endgenerate

    // tile_buffer combinationally reads a_rd_data / b_rd_data from the
    // registered addresses. AND-gate against the registered feed_valid
    // to produce a_in_array_pkt / b_in_array_pkt.
    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] a_in_array_pkt;
    wire [(ARRAY_DIM*DATA_WIDTH)-1:0] b_in_array_pkt;
    generate
        for (gr = 0; gr < ARRAY_DIM; gr = gr + 1) begin : gen_a_in_pkt
            assign a_in_array_pkt[(gr*DATA_WIDTH) +: DATA_WIDTH] =
                feed_valid_a_r_pkt[gr]
                    ? a_rd_data[(gr*DATA_WIDTH) +: DATA_WIDTH]
                    : {DATA_WIDTH{1'b0}};
        end
        for (gc = 0; gc < ARRAY_DIM; gc = gc + 1) begin : gen_b_in_pkt
            assign b_in_array_pkt[(gc*DATA_WIDTH) +: DATA_WIDTH] =
                feed_valid_b_r_pkt[gc]
                    ? b_rd_data[(gc*DATA_WIDTH) +: DATA_WIDTH]
                    : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    // ===== Stage 1.5b: pipeline register between feeder and systolic array =====
    // M6 Tier 1.5 (original option B). Captures a_in_array / b_in_array
    // and the aligned feed_active / array_clear (sourced from the p1
    // stage above so the array sees them aligned with the data path).
    reg                                  feed_active_r;
    reg                                  array_clear_r;
    reg  [(ARRAY_DIM*DATA_WIDTH)-1:0]    a_in_array_pkt_r;
    reg  [(ARRAY_DIM*DATA_WIDTH)-1:0]    b_in_array_pkt_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_active_r    <= 1'b0;
            array_clear_r    <= 1'b0;
            a_in_array_pkt_r <= {(ARRAY_DIM*DATA_WIDTH){1'b0}};
            b_in_array_pkt_r <= {(ARRAY_DIM*DATA_WIDTH){1'b0}};
        end else begin
            feed_active_r    <= feed_active_p1;
            array_clear_r    <= array_clear_p1;
            a_in_array_pkt_r <= a_in_array_pkt;
            b_in_array_pkt_r <= b_in_array_pkt;
        end
    end

    // ===== Stage 2: systolic array =====
    wire [(ARRAY_DIM*ARRAY_DIM*DATA_WIDTH)-1:0] c_out_pkt;

    systolic_array_64x64 #(
        .ROWS       (ARRAY_DIM),
        .COLS       (ARRAY_DIM),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (feed_active_r),
        .clear_acc (array_clear_r),
        .a_in      (a_in_array_pkt_r),
        .b_in      (b_in_array_pkt_r),
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
            if (out_col_cnt + 8'd1 >= tile_n_r) begin
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
            if (coll_col_cnt + 8'd1 >= tile_n_r) begin
                coll_col_cnt <= 8'd0;
                coll_row_cnt <= coll_row_cnt + 8'd1;
            end else begin
                coll_col_cnt <= coll_col_cnt + 8'd1;
            end
        end
    end

    // ===== Stage 3b: softmax path =====
    // M3-fix: ready-gated feed driven by an in_row counter (was cycle-
    // derived; broke under backpressure). Replaces the original
    // (cycle_cnt >= output_start) && (cycle_cnt < sm_feed_end) gate
    // with a handshake that respects the softmax divider's ~48-cycle
    // cadence.
    wire        sm_ready;
    reg  [7:0]  sm_in_row_r;
    wire        sm_feed_phase = softmax_mode && running &&
                                (cycle_cnt >= output_start) &&
                                (sm_in_row_r < tile_m_r);
    wire        sm_in_valid   = sm_feed_phase && sm_ready;
    wire [7:0]  sm_in_row     = sm_in_row_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_in_row_r <= 8'd0;
        end else if (start && !running) begin
            sm_in_row_r <= 8'd0;
        end else if (sm_in_valid) begin
            sm_in_row_r <= sm_in_row_r + 8'd1;
        end
    end

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
        .vec_len   (tile_n_r),
        .scores_in (sm_scores_in_pkt),
        .in_valid  (sm_in_valid),
        .probs_out (sm_probs_out_pkt),
        .out_valid (sm_out_valid),
        .ready     (sm_ready)        // M3-fix: backpressure handshake
    );

    // M3-fix: capture is data-driven on sm_out_valid (was cycle-window;
    // outputs no longer arrive at fixed cadences under backpressure).
    // Count outputs as they fire; index sm_row_buf by the counter.
    reg  [7:0]  sm_cap_row_r;
    wire        sm_capture_active = softmax_mode && running && sm_out_valid;
    wire [7:0]  sm_capture_row    = sm_cap_row_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_cap_row_r <= 8'd0;
        end else if (start && !running) begin
            sm_cap_row_r <= 8'd0;
        end else if (sm_capture_active) begin
            sm_cap_row_r <= sm_cap_row_r + 8'd1;
        end
    end

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

    // M3-fix: walk gated on capture-done flag, not cycle window. Old
    // window assumed captures finished at a fixed time; with
    // backpressure captures finish at variable times.
    reg         sm_capture_done_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_capture_done_r <= 1'b0;
        end else if (start && !running) begin
            sm_capture_done_r <= 1'b0;
        end else if (sm_capture_active &&
                     (sm_cap_row_r + 8'd1 >= tile_m_r)) begin
            sm_capture_done_r <= 1'b1;
        end
    end
    reg [15:0]  sm_walk_cnt;
    wire        sm_walk_active = softmax_mode && running &&
                                 sm_capture_done_r &&
                                 (sm_walk_cnt < ({8'b0, tile_m_r} *
                                                 {8'b0, tile_n_r}));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_walk_cnt <= 16'd0;
        end else if (start && !running) begin
            sm_walk_cnt <= 16'd0;
        end else if (sm_walk_active) begin
            sm_walk_cnt <= sm_walk_cnt + 16'd1;
        end
    end
    reg [7:0]   sm_walk_row_cnt, sm_walk_col_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sm_walk_row_cnt <= 8'd0;
            sm_walk_col_cnt <= 8'd0;
        end else if (start && !running) begin
            sm_walk_row_cnt <= 8'd0;
            sm_walk_col_cnt <= 8'd0;
        end else if (sm_walk_active) begin
            if (sm_walk_col_cnt + 8'd1 >= tile_n_r) begin
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
