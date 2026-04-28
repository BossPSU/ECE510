// tile_dispatcher.sv — Multi-lane tile orchestrator.
//
// Takes one macro_cmd_t describing a full operation
//   (num_m_tiles x num_n_tiles output tiles, each tile_m x tile_n result),
// breaks it into per-tile cmd_pkt_t micro-commands, and dispatches each to
// whichever lane is currently idle. This gives data-parallel execution
// across N_LANES while preserving the existing intra-tile fusion (each
// engine still runs LOAD -> autonomous compute -> WRITE per micro-command).
//
// Tile address layout (assumes contiguous TILE_SIZE x TILE_SIZE blocks per
// tile, ordered as A by row of m_idx, B by col of n_idx, output and aux
// in row-major tile order):
//   tile_a   = addr_a   + m_idx * (TILE_SIZE * tile_k)
//   tile_b   = addr_b   + n_idx * (tile_k * TILE_SIZE)
//   tile_out = addr_out + (m_idx*num_n_tiles + n_idx) * (TILE_SIZE * TILE_SIZE)
//   tile_aux = addr_aux + (m_idx*num_n_tiles + n_idx) * (TILE_SIZE * TILE_SIZE)
//
// No K-accumulation: each output tile is one independent matmul.
module tile_dispatcher
  import accel_pkg::*;
#(
  parameter int N_LANES  = 2,
  parameter int TILE_DIM = TILE_SIZE
)(
  input  logic        clk,
  input  logic        rst_n,

  // Macro command in
  input  macro_cmd_t  macro_cmd,
  input  logic        macro_valid,
  output logic        macro_ready,
  output logic        macro_done,

  // Per-lane outputs (one cmd_pkt_t per lane, gated by per-lane valid)
  output cmd_pkt_t    lane_cmd      [N_LANES],
  output logic        lane_cmd_valid[N_LANES],
  input  logic        lane_cmd_ready[N_LANES],
  input  logic        lane_done     [N_LANES]
);

  // Per-tile element count = TILE_SIZE * TILE_SIZE
  localparam logic [15:0] TILE_OUT_STRIDE = 16'(TILE_DIM) * 16'(TILE_DIM);

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

  // Per-lane "currently has a tile in flight" flag
  logic in_flight [N_LANES];

  // Completions this cycle (sum across lanes — handles simultaneous done)
  logic                completion_pulse [N_LANES];
  logic [$clog2(N_LANES+1)-1:0] num_completed;
  always_comb begin
    num_completed = '0;
    for (int l = 0; l < N_LANES; l++) begin
      completion_pulse[l] = in_flight[l] && lane_done[l];
      if (completion_pulse[l])
        num_completed = num_completed + 1;
    end
  end

  // Find first idle lane (priority encoder, lane 0 wins ties)
  logic              dispatch_now;
  logic [$clog2(N_LANES+1)-1:0] dispatch_lane;
  always_comb begin
    dispatch_now  = 1'b0;
    dispatch_lane = '0;
    for (int l = 0; l < N_LANES; l++) begin
      if (!dispatch_now && !in_flight[l]) begin
        dispatch_now  = 1'b1;
        dispatch_lane = ($clog2(N_LANES+1))'(l);
      end
    end
  end

  // Per-lane cmd outputs — only the dispatched lane sees valid this cycle
  always_comb begin
    for (int l = 0; l < N_LANES; l++) begin
      lane_cmd_valid[l] = 1'b0;
      lane_cmd[l]       = '0;
    end
    if (state == S_DISPATCH && dispatch_now &&
        tiles_issued < total_tiles) begin
      lane_cmd_valid[dispatch_lane] = 1'b1;
      lane_cmd[dispatch_lane].mode     = cmd_reg.mode;
      lane_cmd[dispatch_lane].addr_a   = cmd_reg.addr_a   +
                                          16'(m_idx) * (16'(TILE_DIM) * 16'(cmd_reg.tile_k));
      lane_cmd[dispatch_lane].addr_b   = cmd_reg.addr_b   +
                                          16'(n_idx) * (16'(cmd_reg.tile_k) * 16'(TILE_DIM));
      lane_cmd[dispatch_lane].addr_aux = cmd_reg.addr_aux +
                                          (16'(m_idx) * 16'(cmd_reg.num_n_tiles) + 16'(n_idx))
                                          * TILE_OUT_STRIDE;
      lane_cmd[dispatch_lane].addr_out = cmd_reg.addr_out +
                                          (16'(m_idx) * 16'(cmd_reg.num_n_tiles) + 16'(n_idx))
                                          * TILE_OUT_STRIDE;
      lane_cmd[dispatch_lane].tile_m   = cmd_reg.tile_m;
      lane_cmd[dispatch_lane].tile_n   = cmd_reg.tile_n;
      lane_cmd[dispatch_lane].tile_k   = cmd_reg.tile_k;
      lane_cmd[dispatch_lane].seq_len  = 8'd0;
    end
  end

  // macro_ready: only when idle and waiting for a new macro_cmd
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

      // Always count completions, regardless of state. Sum is taken once
      // (above, combinational) so simultaneous lane finishes count correctly.
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
            total_tiles     <= 16'(macro_cmd.num_m_tiles) * 16'(macro_cmd.num_n_tiles);
            state           <= S_DISPATCH;
          end
        end

        S_DISPATCH: begin
          // If we issued a tile this cycle, advance indices and mark lane busy
          if (dispatch_now &&
              tiles_issued < total_tiles &&
              lane_cmd_ready[dispatch_lane]) begin
            in_flight[dispatch_lane] <= 1'b1;
            tiles_issued             <= tiles_issued + 16'd1;
            // Advance (m_idx, n_idx) row-major in the (m, n) grid
            if (n_idx + 8'd1 >= cmd_reg.num_n_tiles) begin
              n_idx <= '0;
              m_idx <= m_idx + 8'd1;
            end else begin
              n_idx <= n_idx + 8'd1;
            end
          end
          if (tiles_issued == total_tiles ||
              (dispatch_now && tiles_issued + 16'd1 == total_tiles &&
               lane_cmd_ready[dispatch_lane])) begin
            state <= S_DRAIN;
          end
        end

        S_DRAIN: begin
          if (tiles_completed >= total_tiles) begin
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
