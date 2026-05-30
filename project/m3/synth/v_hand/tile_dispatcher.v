/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// tile_dispatcher.v -- hand-flattened from project/m2/rtl/tile_dispatcher.sv
//
// Multi-lane orchestrator. Static round-robin tile_idx ->
// (lane = mod N_LANES, slot = div N_LANES) with per-tile slot_offset baked
// into per-lane addr_a/b/aux/out.
//
// Packed-bus port layout:
//   macro_cmd:  107 bits (= $bits(macro_cmd_t))
//   lane_cmd:   N_LANES * 99 bits (= N_LANES * $bits(cmd_pkt_t))
//
// macro_cmd_t fields (LSB->MSB):
//   [  0 +:  3] mode
//   [  3 +: 16] addr_a
//   [ 19 +: 16] addr_b
//   [ 35 +: 16] addr_aux
//   [ 51 +: 16] addr_out
//   [ 67 +:  8] num_m_tiles
//   [ 75 +:  8] num_n_tiles
//   [ 83 +:  8] tile_m
//   [ 91 +:  8] tile_n
//   [ 99 +:  8] tile_k
// =============================================================================
module tile_dispatcher (
    clk,
    rst_n,
    macro_cmd,
    macro_valid,
    macro_ready,
    macro_done,
    lane_cmd,
    lane_cmd_valid,
    lane_cmd_ready,
    lane_done
);

    parameter N_LANES  = 16;
    parameter TILE_DIM = 64;

    localparam MACRO_W       = 107;
    localparam CMD_W         = 99;
    localparam N_SLOTS       = 2;
    localparam SLOT_STRIDE   = 4 * TILE_DIM * TILE_DIM;
    localparam LANE_ID_W     = (N_LANES <= 1) ? 1 : clog2_f(N_LANES);
    localparam SLOT_ID_W     = (N_SLOTS <= 1) ? 1 : clog2_f(N_SLOTS);

    localparam [1:0] S_IDLE     = 2'd0;
    localparam [1:0] S_DISPATCH = 2'd1;
    localparam [1:0] S_DRAIN    = 2'd2;
    localparam [1:0] S_DONE     = 2'd3;

    input  wire                          clk;
    input  wire                          rst_n;
    input  wire [MACRO_W-1:0]            macro_cmd;
    input  wire                          macro_valid;
    output wire                          macro_ready;
    output reg                           macro_done;

    output reg  [(N_LANES*CMD_W)-1:0]    lane_cmd;
    output reg  [N_LANES-1:0]            lane_cmd_valid;
    input  wire [N_LANES-1:0]            lane_cmd_ready;
    input  wire [N_LANES-1:0]            lane_done;

    reg [1:0]         state;
    reg [MACRO_W-1:0] cmd_reg;
    reg [7:0]         m_idx, n_idx;
    reg [15:0]        tiles_issued, tiles_completed, total_tiles;
    reg [N_LANES-1:0] in_flight;

    // macro_cmd_reg field slices.
    wire [2:0]  cm_mode       = cmd_reg[2:0];
    wire [15:0] cm_addr_a     = cmd_reg[3 +: 16];
    wire [15:0] cm_addr_b     = cmd_reg[19 +: 16];
    wire [15:0] cm_addr_aux   = cmd_reg[35 +: 16];
    wire [15:0] cm_addr_out   = cmd_reg[51 +: 16];
    wire [7:0]  cm_num_m      = cmd_reg[67 +: 8];
    wire [7:0]  cm_num_n      = cmd_reg[75 +: 8];
    wire [7:0]  cm_tile_m     = cmd_reg[83 +: 8];
    wire [7:0]  cm_tile_n     = cmd_reg[91 +: 8];
    wire [7:0]  cm_tile_k     = cmd_reg[99 +: 8];

    // Completion-counting (sum of lane_done & in_flight pulses this cycle)
    // Per-block iterator names to avoid the "multiple conflicting drivers"
    // pattern that yosys flags when one module-scope integer is written
    // from both a combinational always block and a clocked always block.
    integer cnt_ci;             // combinational loop iterator
    integer clr_ci;             // clocked always block iterator
    reg [N_LANES-1:0] completion_pulse;
    reg [LANE_ID_W:0] num_completed;
    always @* begin
        num_completed = {(LANE_ID_W+1){1'b0}};
        for (cnt_ci = 0; cnt_ci < N_LANES; cnt_ci = cnt_ci + 1) begin
            completion_pulse[cnt_ci] = in_flight[cnt_ci] && lane_done[cnt_ci];
            if (completion_pulse[cnt_ci])
                num_completed = num_completed + 1'b1;
        end
    end

    // Static round-robin: tile_idx = tiles_issued
    wire [LANE_ID_W-1:0] target_lane = tiles_issued[LANE_ID_W-1:0];
    wire [SLOT_ID_W-1:0] target_slot = tiles_issued[LANE_ID_W +: SLOT_ID_W];

    wire can_dispatch = (state == S_DISPATCH) &&
                        (tiles_issued < total_tiles) &&
                        !in_flight[target_lane];

    wire [15:0] slot_offset = {{(16-SLOT_ID_W){1'b0}}, target_slot}
                              * SLOT_STRIDE;

    // Per-lane cmd assembly (combinational mux on target_lane).
    integer li;
    reg [CMD_W-1:0] one_lane_cmd;
    always @* begin
        // Default-assign every signal first to avoid latch inference on
        // one_lane_cmd when can_dispatch is low.
        one_lane_cmd = {CMD_W{1'b0}};
        for (li = 0; li < N_LANES; li = li + 1) begin
            lane_cmd_valid[li]                   = 1'b0;
            lane_cmd[(li*CMD_W) +: CMD_W]        = {CMD_W{1'b0}};
        end
        if (can_dispatch) begin
            // Pack per-lane cmd_pkt_t fields in the same LSB->MSB order
            // as accel_pkg::cmd_pkt_t.
            one_lane_cmd                   = {CMD_W{1'b0}};
            one_lane_cmd[2:0]              = cm_mode;
            one_lane_cmd[3 +: 16]          = cm_addr_a   + slot_offset;
            one_lane_cmd[19 +: 16]         = cm_addr_b   + slot_offset;
            one_lane_cmd[35 +: 16]         = cm_addr_aux + slot_offset;
            one_lane_cmd[51 +: 16]         = cm_addr_out + slot_offset;
            one_lane_cmd[67 +: 8]          = cm_tile_m;
            one_lane_cmd[75 +: 8]          = cm_tile_n;
            one_lane_cmd[83 +: 8]          = cm_tile_k;
            one_lane_cmd[91 +: 8]          = 8'd0;  // seq_len
            // The dispatched cmd_pkt_t has no seq_len bits beyond [91+:8];
            // [99] does not exist in cmd_pkt_t (it's 99 bits wide).

            lane_cmd_valid[target_lane]                = 1'b1;
            lane_cmd[(target_lane*CMD_W) +: CMD_W]     = one_lane_cmd;
        end
    end

    assign macro_ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            cmd_reg         <= {MACRO_W{1'b0}};
            m_idx           <= 8'd0;
            n_idx           <= 8'd0;
            tiles_issued    <= 16'd0;
            tiles_completed <= 16'd0;
            total_tiles     <= 16'd0;
            macro_done      <= 1'b0;
            in_flight       <= {N_LANES{1'b0}};
        end else begin
            macro_done <= 1'b0;

            tiles_completed <= tiles_completed +
                               {{(16-LANE_ID_W-1){1'b0}}, num_completed};

            for (clr_ci = 0; clr_ci < N_LANES; clr_ci = clr_ci + 1)
                if (completion_pulse[clr_ci])
                    in_flight[clr_ci] <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (macro_valid) begin
                        cmd_reg         <= macro_cmd;
                        m_idx           <= 8'd0;
                        n_idx           <= 8'd0;
                        tiles_issued    <= 16'd0;
                        tiles_completed <= 16'd0;
                        total_tiles     <= {8'b0, macro_cmd[67 +: 8]} *
                                           {8'b0, macro_cmd[75 +: 8]};
                        state           <= S_DISPATCH;
                    end
                end
                S_DISPATCH: begin
                    if (can_dispatch && lane_cmd_ready[target_lane]) begin
                        in_flight[target_lane] <= 1'b1;
                        tiles_issued           <= tiles_issued + 16'd1;
                        if (n_idx + 8'd1 >= cm_num_n) begin
                            n_idx <= 8'd0;
                            m_idx <= m_idx + 8'd1;
                        end else begin
                            n_idx <= n_idx + 8'd1;
                        end
                    end
                    if (tiles_issued >= total_tiles ||
                        (can_dispatch && lane_cmd_ready[target_lane] &&
                         tiles_issued + 16'd1 >= total_tiles))
                        state <= S_DRAIN;
                end
                S_DRAIN: begin
                    if (tiles_completed +
                        {{(16-LANE_ID_W-1){1'b0}}, num_completed}
                        >= total_tiles)
                        state <= S_DONE;
                end
                S_DONE: begin
                    macro_done <= 1'b1;
                    state      <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    function integer clog2_f;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2_f = 0;
            while (v > 0) begin v = v >> 1; clog2_f = clog2_f + 1; end
        end
    endfunction

endmodule
