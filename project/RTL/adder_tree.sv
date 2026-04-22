// adder_tree.sv — Reusable pipelined reduction tree
// Used for softmax denominator, bias gradient reductions
module adder_tree
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int NUM_INPUTS = 64
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    en,
  input  logic [DATA_WIDTH-1:0]   in_data [NUM_INPUTS],
  input  logic                    in_valid,
  output logic [DATA_WIDTH-1:0]   sum_out,
  output logic                    out_valid
);

  localparam int LEVELS = $clog2(NUM_INPUTS);

  // Pipeline registers for each level
  logic [DATA_WIDTH-1:0] stage [LEVELS+1][NUM_INPUTS];
  logic                  valid_pipe [LEVELS+1];

  // Input stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_pipe[0] <= 1'b0;
    end else if (en) begin
      valid_pipe[0] <= in_valid;
      for (int i = 0; i < NUM_INPUTS; i++)
        stage[0][i] <= in_data[i];
    end
  end

  // Reduction levels
  genvar lv;
  generate
    for (lv = 0; lv < LEVELS; lv++) begin : gen_level
      localparam int WIDTH = NUM_INPUTS >> lv;
      localparam int HALF  = WIDTH >> 1;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          valid_pipe[lv+1] <= 1'b0;
        end else if (en) begin
          valid_pipe[lv+1] <= valid_pipe[lv];
          for (int i = 0; i < HALF; i++) begin
            // FP32 add (behavioral)
            stage[lv+1][i] <= $shortrealtobits(
              $bitstoshortreal(stage[lv][2*i]) +
              $bitstoshortreal(stage[lv][2*i+1])
            );
          end
          // If odd width, pass through last element
          if (WIDTH % 2 == 1)
            stage[lv+1][HALF] <= stage[lv][WIDTH-1];
        end
      end
    end
  endgenerate

  assign sum_out   = stage[LEVELS][0];
  assign out_valid = valid_pipe[LEVELS];

endmodule
