// exp_lut.sv — Synthesizable exp ROM (Q16.16)
// LUT contents loaded from exp_lut.mem (256 entries)
// Maps input range [-8, 0] to e^x values (used after subtracting max in softmax)
module exp_lut
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = LUT_DEPTH,
  parameter int ADDR_W     = LUT_ADDR_W
)(
  input  logic                            clk,
  input  logic [ADDR_W-1:0]               addr,
  output logic signed [DATA_WIDTH-1:0]    data
);

  (* rom_style = "block" *) logic signed [DATA_WIDTH-1:0] lut_mem [DEPTH];

  initial begin
    $readmemh("exp_lut.mem", lut_mem);
  end

  always_ff @(posedge clk) begin
    data <= lut_mem[addr];
  end

endmodule
