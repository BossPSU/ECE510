// gelu_lut.sv — Lookup table for GELU / tanh approximation
// Used by both gelu_unit and gelu_grad_unit
module gelu_lut
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = LUT_DEPTH,
  parameter int ADDR_W     = LUT_ADDR_W
)(
  input  logic                   clk,
  input  logic [ADDR_W-1:0]      addr,
  output logic [DATA_WIDTH-1:0]  data
);

  // tanh LUT — covers input range [-4.0, 4.0] mapped to [0, 255]
  // Output is tanh(x) in FP32
  logic [DATA_WIDTH-1:0] lut_mem [DEPTH];

  // Initialize LUT with tanh values (behavioral — replaced by ROM in synthesis)
  initial begin
    for (int i = 0; i < DEPTH; i++) begin
      real x, t;
      x = -4.0 + 8.0 * real'(i) / real'(DEPTH - 1);
      t = $tanh(x);
      lut_mem[i] = $shortrealtobits(shortreal'(t));
    end
  end

  // Synchronous read
  always_ff @(posedge clk) begin
    data <= lut_mem[addr];
  end

endmodule
