// pipeline_stage.sv — Generic valid/ready register slice
module pipeline_stage
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // Upstream
  input  logic [DATA_WIDTH-1:0]  in_data,
  input  logic                   in_valid,
  output logic                   in_ready,

  // Downstream
  output logic [DATA_WIDTH-1:0]  out_data,
  output logic                   out_valid,
  input  logic                   out_ready
);

  logic [DATA_WIDTH-1:0] buf_data;
  logic                  buf_valid;

  assign in_ready  = !buf_valid || out_ready;
  assign out_data  = buf_data;
  assign out_valid = buf_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_valid <= 1'b0;
      buf_data  <= '0;
    end else begin
      if (in_ready) begin
        buf_valid <= in_valid;
        buf_data  <= in_data;
      end
    end
  end

endmodule
