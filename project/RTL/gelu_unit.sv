// gelu_unit.sv — Forward GELU activation datapath
// GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
// Pipelined: 5 stages
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
  logic [DATA_WIDTH-1:0] p1_x, p1_x3_term;
  logic                  p1_valid;
  logic [DATA_WIDTH-1:0] p2_tanh_arg;
  logic                  p2_valid;
  logic [DATA_WIDTH-1:0] p2_x;
  logic [DATA_WIDTH-1:0] p3_tanh_val;
  logic                  p3_valid;
  logic [DATA_WIDTH-1:0] p3_x;
  logic [DATA_WIDTH-1:0] p4_sum;
  logic                  p4_valid;
  logic [DATA_WIDTH-1:0] p4_x;

  // Constants (FP32 bit patterns)
  localparam logic [DATA_WIDTH-1:0] HALF       = 32'h3F000000; // 0.5
  localparam logic [DATA_WIDTH-1:0] ONE        = 32'h3F800000; // 1.0
  localparam logic [DATA_WIDTH-1:0] SQRT_2_PI  = 32'h3F4C422A; // sqrt(2/pi) ~ 0.7979
  localparam logic [DATA_WIDTH-1:0] COEFF      = 32'h3D372713; // 0.044715

  // tanh LUT
  logic [LUT_ADDR_W-1:0] tanh_addr;
  logic [DATA_WIDTH-1:0]  tanh_data;

  gelu_lut u_tanh_lut (
    .clk  (clk),
    .addr (tanh_addr),
    .data (tanh_data)
  );

  // Stage 1: compute x + 0.044715 * x^3 → tanh_arg_pre
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p1_valid <= 1'b0;
    end else if (en) begin
      p1_valid    <= in_valid;
      p1_x        <= x_in;
      // x + 0.044715 * x^3 (behavioral FP)
      p1_x3_term  <= $shortrealtobits(
        $bitstoshortreal(x_in) +
        shortreal'(0.044715) * $bitstoshortreal(x_in) *
        $bitstoshortreal(x_in) * $bitstoshortreal(x_in)
      );
    end
  end

  // Stage 2: multiply by sqrt(2/pi), compute LUT address
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p2_valid <= 1'b0;
    end else if (en) begin
      p2_valid    <= p1_valid;
      p2_x        <= p1_x;
      p2_tanh_arg <= $shortrealtobits(
        shortreal'(0.7978845608) * $bitstoshortreal(p1_x3_term)
      );
    end
  end

  // Map tanh_arg to LUT address: [-4, 4] → [0, 255]
  assign tanh_addr = LUT_ADDR_W'(
    int'(($bitstoshortreal(p2_tanh_arg) + shortreal'(4.0)) * shortreal'(31.875))
  );

  // Stage 3: read tanh from LUT (1 cycle latency in gelu_lut)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p3_valid <= 1'b0;
    end else if (en) begin
      p3_valid    <= p2_valid;
      p3_x        <= p2_x;
      p3_tanh_val <= tanh_data;
    end
  end

  // Stage 4: 1 + tanh_val
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p4_valid <= 1'b0;
    end else if (en) begin
      p4_valid <= p3_valid;
      p4_x     <= p3_x;
      p4_sum   <= $shortrealtobits(shortreal'(1.0) + $bitstoshortreal(p3_tanh_val));
    end
  end

  // Stage 5: 0.5 * x * (1 + tanh)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else if (en) begin
      out_valid <= p4_valid;
      y_out     <= $shortrealtobits(
        shortreal'(0.5) * $bitstoshortreal(p4_x) * $bitstoshortreal(p4_sum)
      );
    end
  end

endmodule
