// mac_pe.sv — Processing element for one systolic cell
// Performs multiply-accumulate with register forwarding
module mac_pe
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    en,
  input  logic                    clear_acc,

  // Data from west (row)
  input  logic [DATA_WIDTH-1:0]   a_in,
  output logic [DATA_WIDTH-1:0]   a_out,

  // Data from north (column)
  input  logic [DATA_WIDTH-1:0]   b_in,
  output logic [DATA_WIDTH-1:0]   b_out,

  // Accumulated result
  output logic [DATA_WIDTH-1:0]   acc_out
);

  // Internal accumulator
  logic [DATA_WIDTH-1:0] acc_r;

  // FP32 multiply-accumulate (behavioral — synthesis tool maps to DSP)
  // In real silicon: use a fused multiply-add (FMA) unit
  real a_real, b_real, acc_real, mac_real;

  always_comb begin
    a_real   = $bitstoreal({32'b0, a_in});
    b_real   = $bitstoreal({32'b0, b_in});
    acc_real = $bitstoreal({32'b0, acc_r});
    mac_real = acc_real + (a_real * b_real);
  end

  // Register forwarding + accumulation
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out  <= '0;
      b_out  <= '0;
      acc_r  <= '0;
    end else if (en) begin
      // Forward operands to neighbors (systolic flow)
      a_out <= a_in;
      b_out <= b_in;

      // Accumulate or clear
      if (clear_acc)
        acc_r <= '0;
      else
        acc_r <= $shortrealtobits($bitstoshortreal(acc_r) +
                                  ($bitstoshortreal(a_in) * $bitstoshortreal(b_in)));
    end
  end

  assign acc_out = acc_r;

endmodule
