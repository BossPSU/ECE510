// perf_counter_block.sv — Hardware performance counters
// Tracks active cycles, stall cycles, tiles completed, utilization
module perf_counter_block
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        clear,

  // Activity signals
  input  logic        array_active,
  input  logic        array_stall,
  input  logic        tile_complete,

  // Counter outputs
  output logic [31:0] active_cycles,
  output logic [31:0] stall_cycles,
  output logic [31:0] total_cycles,
  output logic [31:0] tiles_completed
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || clear) begin
      active_cycles   <= '0;
      stall_cycles    <= '0;
      total_cycles    <= '0;
      tiles_completed <= '0;
    end else begin
      total_cycles <= total_cycles + 1;

      if (array_active)
        active_cycles <= active_cycles + 1;

      if (array_stall)
        stall_cycles <= stall_cycles + 1;

      if (tile_complete)
        tiles_completed <= tiles_completed + 1;
    end
  end

endmodule
