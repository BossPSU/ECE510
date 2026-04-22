// gelu_unit.sv — Forward GELU activation datapath
// GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
// Pipelined: 3 stages (behavioral FP for simulation)
module gelu_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   en,

  input  logic [DATA_WIDTH-1:0]  x_in,
  input  logic                   in_valid,
  output logic [DATA_WIDTH-1:0]  y_out,
  output logic                   out_valid
);

  // Pipeline registers
  logic [DATA_WIDTH-1:0] p1_x;
  logic [DATA_WIDTH-1:0] p1_tanh_arg;
  logic                  p1_valid;

  logic [DATA_WIDTH-1:0] p2_x;
  logic [DATA_WIDTH-1:0] p2_tanh_val;
  logic                  p2_valid;

  // Stage 1: compute tanh_arg = sqrt(2/pi) * (x + 0.044715 * x^3)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p1_valid <= 1'b0;
    end else if (en) begin
      p1_valid <= in_valid;
      if (in_valid) begin
        shortreal x_r, arg;
        x_r = $bitstoshortreal(x_in);
        arg = shortreal'(0.7978845608) * (x_r + shortreal'(0.044715) * x_r * x_r * x_r);
        p1_x        <= x_in;
        p1_tanh_arg <= $shortrealtobits(arg);
      end
    end
  end

  // Stage 2: compute tanh (behavioral)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p2_valid <= 1'b0;
    end else if (en) begin
      p2_valid <= p1_valid;
      if (p1_valid) begin
        p2_x        <= p1_x;
        p2_tanh_val <= $shortrealtobits($tanh($bitstoshortreal(p1_tanh_arg)));
      end
    end
  end

  // Stage 3: compute 0.5 * x * (1 + tanh)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else if (en) begin
      out_valid <= p2_valid;
      if (p2_valid) begin
        shortreal x_r, t, result;
        x_r    = $bitstoshortreal(p2_x);
        t      = $bitstoshortreal(p2_tanh_val);
        result = shortreal'(0.5) * x_r * (shortreal'(1.0) + t);
        y_out  <= $shortrealtobits(result);
      end
    end
  end

endmodule
