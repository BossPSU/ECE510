// exp_lut.sv — Lookup table for exponential approximation (softmax)
module exp_lut
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

  // exp LUT — covers input range [-8.0, 0.0] mapped to [0, 255]
  // Used after subtracting max in softmax (values always <= 0)
  logic [DATA_WIDTH-1:0] lut_mem [DEPTH];

  initial begin
    for (int i = 0; i < DEPTH; i++) begin
      real x, e;
      x = -8.0 + 8.0 * real'(i) / real'(DEPTH - 1);
      e = $exp(x);
      lut_mem[i] = $shortrealtobits(shortreal'(e));
    end
  end

  always_ff @(posedge clk) begin
    data <= lut_mem[addr];
  end

endmodule
