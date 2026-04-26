// mac_pe.sv — Synthesizable Q16.16 fixed-point MAC processing element
// Performs multiply-accumulate with register forwarding
module mac_pe
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            clear_acc,

  // West (row) input/output
  input  logic signed [DATA_WIDTH-1:0]    a_in,
  output logic signed [DATA_WIDTH-1:0]    a_out,

  // North (column) input/output
  input  logic signed [DATA_WIDTH-1:0]    b_in,
  output logic signed [DATA_WIDTH-1:0]    b_out,

  // Accumulator
  output logic signed [DATA_WIDTH-1:0]    acc_out
);

  logic signed [DATA_WIDTH-1:0] acc_r;

  // Q16.16 multiply: 32x32 -> 64, take middle bits for Q16.16 result
  logic signed [63:0] product;
  logic signed [DATA_WIDTH-1:0] product_q;

  assign product   = a_in * b_in;
  assign product_q = product[31+FRAC_BITS:FRAC_BITS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc_r <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      if (clear_acc)
        acc_r <= '0;
      else
        acc_r <= acc_r + product_q;
    end
  end

  assign acc_out = acc_r;

endmodule
