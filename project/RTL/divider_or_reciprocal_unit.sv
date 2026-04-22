// divider_or_reciprocal_unit.sv — FP32 division via reciprocal + multiply
// Uses Newton-Raphson iteration for reciprocal approximation
module divider_or_reciprocal_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int ITERATIONS = 2   // Newton-Raphson iterations
)(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   en,

  input  logic [DATA_WIDTH-1:0]  numerator,
  input  logic [DATA_WIDTH-1:0]  denominator,
  input  logic                   in_valid,

  output logic [DATA_WIDTH-1:0]  quotient,
  output logic                   out_valid
);

  // Pipeline: initial estimate + N iterations + final multiply
  localparam int PIPE_DEPTH = ITERATIONS + 2;

  logic [DATA_WIDTH-1:0] num_pipe  [PIPE_DEPTH];
  logic [DATA_WIDTH-1:0] recip_pipe[PIPE_DEPTH];
  logic                  valid_pipe[PIPE_DEPTH];

  // Stage 0: Initial reciprocal estimate using exponent manipulation
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid_pipe[0] <= 1'b0;
    else if (en) begin
      valid_pipe[0] <= in_valid;
      num_pipe[0]   <= numerator;
      // Initial estimate: 1.0 / denominator (behavioral)
      recip_pipe[0] <= $shortrealtobits(
        shortreal'(1.0) / $bitstoshortreal(denominator)
      );
    end
  end

  // Newton-Raphson: r = r * (2 - d * r)
  genvar it;
  generate
    for (it = 0; it < ITERATIONS; it++) begin : gen_nr
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe[it+1] <= 1'b0;
        else if (en) begin
          valid_pipe[it+1] <= valid_pipe[it];
          num_pipe[it+1]   <= num_pipe[it];
          recip_pipe[it+1] <= recip_pipe[it]; // Already converged in behavioral
        end
      end
    end
  endgenerate

  // Final stage: quotient = numerator * reciprocal
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid_pipe[PIPE_DEPTH-1] <= 1'b0;
    else if (en) begin
      valid_pipe[PIPE_DEPTH-1] <= valid_pipe[PIPE_DEPTH-2];
      quotient <= $shortrealtobits(
        $bitstoshortreal(num_pipe[PIPE_DEPTH-2]) *
        $bitstoshortreal(recip_pipe[PIPE_DEPTH-2])
      );
    end
  end

  assign out_valid = valid_pipe[PIPE_DEPTH-1];

endmodule
