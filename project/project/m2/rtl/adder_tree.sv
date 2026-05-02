// adder_tree.sv — Synthesizable Q16.16 reduction tree
module adder_tree
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int NUM_INPUTS = 64
)(
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                en,
  input  logic signed [DATA_WIDTH-1:0]        in_data [NUM_INPUTS],
  input  logic                                in_valid,
  output logic signed [DATA_WIDTH-1:0]        sum_out,
  output logic                                out_valid
);

  localparam int LEVELS = $clog2(NUM_INPUTS);

  logic signed [DATA_WIDTH-1:0] stage [LEVELS+1][NUM_INPUTS];
  logic                         valid_pipe [LEVELS+1];

  // Input stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_pipe[0] <= 1'b0;
      for (int i = 0; i < NUM_INPUTS; i++)
        stage[0][i] <= '0;
    end else if (en) begin
      valid_pipe[0] <= in_valid;
      for (int i = 0; i < NUM_INPUTS; i++)
        stage[0][i] <= in_data[i];
    end
  end

  // Reduction levels: integer adds (Q16.16 + Q16.16 = Q16.16)
  genvar lv;
  generate
    for (lv = 0; lv < LEVELS; lv++) begin : gen_level
      localparam int WIDTH = NUM_INPUTS >> lv;
      localparam int HALF  = WIDTH >> 1;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          valid_pipe[lv+1] <= 1'b0;
          for (int i = 0; i < NUM_INPUTS; i++)
            stage[lv+1][i] <= '0;
        end else if (en) begin
          valid_pipe[lv+1] <= valid_pipe[lv];
          for (int i = 0; i < HALF; i++)
            stage[lv+1][i] <= stage[lv][2*i] + stage[lv][2*i+1];
          if (WIDTH % 2 == 1)
            stage[lv+1][HALF] <= stage[lv][WIDTH-1];
        end
      end
    end
  endgenerate

  assign sum_out   = stage[LEVELS][0];
  assign out_valid = valid_pipe[LEVELS];

endmodule
