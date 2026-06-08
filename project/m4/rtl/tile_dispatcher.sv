// tile_dispatcher.sv — Multi-lane tile orchestrator with tile slots.
//
// Static round-robin dispatch:
//   tile_idx       in [0, num_m_tiles * num_n_tiles)
//   lane_id        = tile_idx mod N_LANES
//   slot_id        = tile_idx div N_LANES   (in [0, N_SLOTS))
//
// This deterministic mapping (vs the older "first-idle wins" priority
// encoder) lets multiple tiles per lane coexist: each tile gets its own
// slot in the lane bank at slot_id * SLOT_STRIDE, so no two tiles
// dispatched to the same lane alias on the output address. Up to
// N_LANES * N_SLOTS tiles fit in one macro_cmd; beyond that the host
// loops with smaller batches.
//
// Per-tile addresses fed to the engine:
//   addr_a   = macro.addr_a   + slot_id * SLOT_STRIDE
//   addr_b   = macro.addr_b   + slot_id * SLOT_STRIDE
//   addr_aux = macro.addr_aux + slot_id * SLOT_STRIDE
//   addr_out = macro.addr_out + slot_id * SLOT_STRIDE
// The host preloads each (lane, slot) before issuing the macro.
module tile_dispatcher
  import accel_pkg::*;
#(
  parameter int N_LANES  = 16,
  parameter int TILE_DIM = TILE_SIZE
)(
  input  logic        clk,
  input  logic        rst_n,

  // Macro command in
  input  macro_cmd_t  macro_cmd,
  input  logic        macro_valid,
  output logic        macro_ready,
  output logic        macro_done,

  // Per-lane outputs
  output cmd_pkt_t    lane_cmd      [N_LANES],
  output logic        lane_cmd_valid[N_LANES],
  input  logic        lane_cmd_ready[N_LANES],
  input  logic        lane_done     [N_LANES]
);

  localparam int LANE_ID_W  = (N_LANES <= 1) ? 1 : $clog2(N_LANES);
  localparam int SLOT_ID_W  = (N_SLOTS <= 1) ? 1 : $clog2(N_SLOTS);

  typedef enum logic [1:0] {
    S_IDLE,
    S_DISPATCH,
    S_DRAIN,
    S_DONE
  } state_t;

  state_t state;

  macro_cmd_t  cmd_reg;
  logic [7:0]  m_idx, n_idx;
  logic [15:0] tiles_issued, tiles_completed, total_tiles;

  logic in_flight [N_LANES];

  // Sum simultaneous lane completions so they all count
  logic                 completion_pulse [N_LANES];
  logic [LANE_ID_W:0]   num_completed;
  always_comb begin
    num_completed = '0;
    for (int l = 0; l < N_LANES; l++) begin
      completion_pulse[l] = in_flight[l] && lane_done[l];
      if (completion_pulse[l])
        num_completed = num_completed + 1;
    end
  end

  // Static round-robin: tile_idx = tiles_issued, lane = mod, slot = div.
  // The dispatcher waits for THIS specific lane to be free instead of
  // taking the first available — that is what guarantees no two tiles
  // ever dispatched to the same lane share a slot.
  logic [LANE_ID_W-1:0] target_lane;
  logic [SLOT_ID_W-1:0] target_slot;
  assign target_lane = tiles_issued[LANE_ID_W-1:0];
  assign target_slot = tiles_issued[LANE_ID_W +: SLOT_ID_W];

  logic               can_dispatch;
  assign can_dispatch = (state == S_DISPATCH) &&
                        (tiles_issued < total_tiles) &&
                        !in_flight[target_lane];

  // Slot offset (per-tile address contribution)
  logic [15:0] slot_offset;
  assign slot_offset = 16'(target_slot) * 16'(SLOT_STRIDE);

  // Per-lane cmd outputs — only the targeted lane sees valid this cycle
  always_comb begin
    for (int l = 0; l < N_LANES; l++) begin
      lane_cmd_valid[l] = 1'b0;
      lane_cmd[l]       = '0;
    end
    if (can_dispatch) begin
      lane_cmd_valid[target_lane] = 1'b1;
      lane_cmd[target_lane].mode     = cmd_reg.mode;
      lane_cmd[target_lane].addr_a   = cmd_reg.addr_a   + slot_offset;
      lane_cmd[target_lane].addr_b   = cmd_reg.addr_b   + slot_offset;
      lane_cmd[target_lane].addr_aux = cmd_reg.addr_aux + slot_offset;
      lane_cmd[target_lane].addr_out = cmd_reg.addr_out + slot_offset;
      lane_cmd[target_lane].tile_m   = cmd_reg.tile_m;
      lane_cmd[target_lane].tile_n   = cmd_reg.tile_n;
      lane_cmd[target_lane].tile_k   = cmd_reg.tile_k;
      lane_cmd[target_lane].seq_len  = 8'd0;
    end
  end

  assign macro_ready = (state == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= S_IDLE;
      cmd_reg         <= '0;
      m_idx           <= '0;
      n_idx           <= '0;
      tiles_issued    <= '0;
      tiles_completed <= '0;
      total_tiles     <= '0;
      macro_done      <= 1'b0;
      for (int l = 0; l < N_LANES; l++)
        in_flight[l] <= 1'b0;
    end else begin
      macro_done <= 1'b0;

      // Count completions every cycle (state-independent)
      tiles_completed <= tiles_completed + 16'(num_completed);
      for (int l = 0; l < N_LANES; l++)
        if (completion_pulse[l])
          in_flight[l] <= 1'b0;

      case (state)
        S_IDLE: begin
          if (macro_valid) begin
            cmd_reg         <= macro_cmd;
            m_idx           <= '0;
            n_idx           <= '0;
            tiles_issued    <= '0;
            tiles_completed <= '0;
            total_tiles     <= 16'(macro_cmd.num_m_tiles) *
                                16'(macro_cmd.num_n_tiles);
            state           <= S_DISPATCH;
          end
        end

        S_DISPATCH: begin
          // Issue this tile to its statically-assigned lane if free and
          // the lane is ready to accept (cmd_ready)
          if (can_dispatch && lane_cmd_ready[target_lane]) begin
            in_flight[target_lane] <= 1'b1;
            tiles_issued           <= tiles_issued + 16'd1;
            // Advance (m_idx, n_idx) row-major; not strictly needed for
            // address generation (which uses slot_offset), but kept for
            // observability / debug.
            if (n_idx + 8'd1 >= cmd_reg.num_n_tiles) begin
              n_idx <= '0;
              m_idx <= m_idx + 8'd1;
            end else begin
              n_idx <= n_idx + 8'd1;
            end
          end
          // Move to drain once all tiles have been issued (counted with
          // the just-completed dispatch this cycle).
          if (tiles_issued >= total_tiles ||
              (can_dispatch && lane_cmd_ready[target_lane] &&
               tiles_issued + 16'd1 >= total_tiles)) begin
            state <= S_DRAIN;
          end
        end

        S_DRAIN: begin
          if (tiles_completed + 16'(num_completed) >= total_tiles) begin
            state <= S_DONE;
          end
        end

        S_DONE: begin
          macro_done <= 1'b1;
          state      <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
