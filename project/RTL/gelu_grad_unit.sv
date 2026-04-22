// gelu_grad_unit.sv — Backward GELU gradient datapath
// Shares tanh LUT with gelu_unit
// gelu'(x) = 0.5*(1+tanh) + 0.5*x*(1-tanh^2)*sqrt(2/pi)*(1+3*0.044715*x^2)
// Pipelined: 5 stages
module gelu_grad_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   en,

  input  logic [DATA_WIDTH-1:0]  x_in,
  input  logic                   in_valid,
  output logic [DATA_WIDTH-1:0]  grad_out,
  output logic                   out_valid
);

  // Pipeline registers
  logic [DATA_WIDTH-1:0] p1_x, p1_x3_term;
  logic                  p1_valid;
  logic [DATA_WIDTH-1:0] p2_tanh_arg, p2_x;
  logic                  p2_valid;
  logic [DATA_WIDTH-1:0] p3_tanh_val, p3_x;
  logic                  p3_valid;
  logic [DATA_WIDTH-1:0] p4_dtanh, p4_inner, p4_tanh_val, p4_x;
  logic                  p4_valid;

  // tanh LUT
  logic [LUT_ADDR_W-1:0] tanh_addr;
  logic [DATA_WIDTH-1:0]  tanh_data;

  gelu_lut u_tanh_lut (
    .clk  (clk),
    .addr (tanh_addr),
    .data (tanh_data)
  );

  // Stage 1: x + 0.044715 * x^3
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) p1_valid <= 1'b0;
    else if (en) begin
      p1_valid   <= in_valid;
      p1_x       <= x_in;
      p1_x3_term <= $shortrealtobits(
        $bitstoshortreal(x_in) +
        shortreal'(0.044715) * $bitstoshortreal(x_in) *
        $bitstoshortreal(x_in) * $bitstoshortreal(x_in)
      );
    end
  end

  // Stage 2: tanh_arg = sqrt(2/pi) * x3_term
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) p2_valid <= 1'b0;
    else if (en) begin
      p2_valid    <= p1_valid;
      p2_x        <= p1_x;
      p2_tanh_arg <= $shortrealtobits(
        shortreal'(0.7978845608) * $bitstoshortreal(p1_x3_term)
      );
    end
  end

  assign tanh_addr = LUT_ADDR_W'(
    int'(($bitstoshortreal(p2_tanh_arg) + shortreal'(4.0)) * shortreal'(31.875))
  );

  // Stage 3: read tanh
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) p3_valid <= 1'b0;
    else if (en) begin
      p3_valid    <= p2_valid;
      p3_x        <= p2_x;
      p3_tanh_val <= tanh_data;
    end
  end

  // Stage 4: compute dtanh = 1 - tanh^2, inner_grad = sqrt(2/pi)*(1 + 3*0.044715*x^2)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) p4_valid <= 1'b0;
    else if (en) begin
      p4_valid    <= p3_valid;
      p4_x        <= p3_x;
      p4_tanh_val <= p3_tanh_val;
      p4_dtanh    <= $shortrealtobits(
        shortreal'(1.0) - $bitstoshortreal(p3_tanh_val) * $bitstoshortreal(p3_tanh_val)
      );
      p4_inner    <= $shortrealtobits(
        shortreal'(0.7978845608) * (shortreal'(1.0) +
        shortreal'(3.0) * shortreal'(0.044715) *
        $bitstoshortreal(p3_x) * $bitstoshortreal(p3_x))
      );
    end
  end

  // Stage 5: 0.5*(1+tanh) + 0.5*x*dtanh*inner_grad
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) out_valid <= 1'b0;
    else if (en) begin
      out_valid <= p4_valid;
      grad_out  <= $shortrealtobits(
        shortreal'(0.5) * (shortreal'(1.0) + $bitstoshortreal(p4_tanh_val)) +
        shortreal'(0.5) * $bitstoshortreal(p4_x) *
        $bitstoshortreal(p4_dtanh) * $bitstoshortreal(p4_inner)
      );
    end
  end

endmodule
