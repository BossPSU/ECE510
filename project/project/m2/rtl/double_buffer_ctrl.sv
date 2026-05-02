// double_buffer_ctrl.sv — Ping-pong between two SRAM regions
// Overlaps load/compute/store for future enhancement
module double_buffer_ctrl
  import accel_pkg::*;
#(
  parameter int ADDR_WIDTH  = 16,
  parameter int REGION_SIZE = 16'h1000  // words per buffer region
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    swap,        // trigger buffer swap

  output logic                    active_buf,  // 0 or 1
  output logic [ADDR_WIDTH-1:0]   compute_base,
  output logic [ADDR_WIDTH-1:0]   load_base
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_buf <= 1'b0;
    end else if (swap) begin
      active_buf <= ~active_buf;
    end
  end

  // Buffer 0 starts at 0x0000, Buffer 1 at REGION_SIZE
  assign compute_base = active_buf ? REGION_SIZE : '0;
  assign load_base    = active_buf ? '0 : REGION_SIZE;

endmodule
