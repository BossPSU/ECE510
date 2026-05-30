// gelu_grad_direct_lut.sv — Synthesizable direct GELU-derivative LUT (M4 update)
//
// 256-entry x 32-bit Q16.16 ROM holding GELU'(x) for x in [-4, +4),
// where GELU'(x) = Phi(x) + x * phi(x). Two registered read ports
// (addr_lo, addr_hi) emit data on the next clock edge — used by
// gelu_grad_unit_lut for linear interpolation in a single LUT cycle.
//
// Contents are produced by gen_lut_mem.py and live in
// gelu_grad_lut_direct.mem (half-open grid: entry[i] = GELU'(-4 + i/32)).
module gelu_grad_direct_lut
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = 256,
  parameter int ADDR_W     = 8
)(
  input  logic                            clk,
  input  logic [ADDR_W-1:0]               addr_lo,
  input  logic [ADDR_W-1:0]               addr_hi,
  output logic signed [DATA_WIDTH-1:0]    data_lo,
  output logic signed [DATA_WIDTH-1:0]    data_hi
);

  (* rom_style = "block" *) logic signed [DATA_WIDTH-1:0] lut_mem [DEPTH];

  initial begin
    $readmemh("gelu_grad_lut_direct.mem", lut_mem);
  end

  always_ff @(posedge clk) begin
    data_lo <= lut_mem[addr_lo];
    data_hi <= lut_mem[addr_hi];
  end

endmodule
