// tile_scheduler.sv — Handles tile loop bounds and traversal
module tile_scheduler
  import accel_pkg::*;
#(
  parameter int TILE_DIM = TILE_SIZE
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic        tile_done,   // current tile completed

  // Matrix dimensions
  input  logic [7:0]  dim_m,       // rows of result
  input  logic [7:0]  dim_n,       // cols of result
  input  logic [7:0]  dim_k,       // shared / reduction dim

  // Current tile indices
  output logic [7:0]  tile_m_idx,
  output logic [7:0]  tile_n_idx,
  output logic [7:0]  tile_k_idx,

  // Control signals
  output logic        tile_start,
  output logic        all_done,
  output logic        active
);

  localparam int TILE_SHIFT = $clog2(TILE_DIM);

  logic [7:0] num_m_tiles, num_n_tiles, num_k_tiles;

  assign num_m_tiles = (dim_m + TILE_DIM - 1) >> TILE_SHIFT;
  assign num_n_tiles = (dim_n + TILE_DIM - 1) >> TILE_SHIFT;
  assign num_k_tiles = (dim_k + TILE_DIM - 1) >> TILE_SHIFT;

  typedef enum logic [1:0] {
    S_IDLE,
    S_ISSUE,
    S_WAIT,
    S_DONE
  } state_t;

  state_t state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      tile_m_idx <= '0;
      tile_n_idx <= '0;
      tile_k_idx <= '0;
      tile_start <= 1'b0;
      all_done   <= 1'b0;
      active     <= 1'b0;
    end else begin
      tile_start <= 1'b0;
      all_done   <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start) begin
            tile_m_idx <= '0;
            tile_n_idx <= '0;
            tile_k_idx <= '0;
            state      <= S_ISSUE;
            active     <= 1'b1;
          end
        end

        S_ISSUE: begin
          tile_start <= 1'b1;
          state      <= S_WAIT;
        end

        S_WAIT: begin
          if (tile_done) begin
            // Advance K (innermost loop)
            if (tile_k_idx < num_k_tiles - 1) begin
              tile_k_idx <= tile_k_idx + 1;
              state      <= S_ISSUE;
            end
            // Advance N
            else if (tile_n_idx < num_n_tiles - 1) begin
              tile_k_idx <= '0;
              tile_n_idx <= tile_n_idx + 1;
              state      <= S_ISSUE;
            end
            // Advance M
            else if (tile_m_idx < num_m_tiles - 1) begin
              tile_k_idx <= '0;
              tile_n_idx <= '0;
              tile_m_idx <= tile_m_idx + 1;
              state      <= S_ISSUE;
            end
            // All tiles done
            else begin
              state    <= S_DONE;
            end
          end
        end

        S_DONE: begin
          all_done <= 1'b1;
          active   <= 1'b0;
          state    <= S_IDLE;
        end
      endcase
    end
  end

endmodule
