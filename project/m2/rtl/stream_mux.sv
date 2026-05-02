// stream_mux.sv — Select between fused output modes
module stream_mux
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int NUM_INPUTS = 4
)(
  input  logic                         sel_valid,
  input  logic [$clog2(NUM_INPUTS)-1:0] sel,

  input  logic [DATA_WIDTH-1:0]        in_data  [NUM_INPUTS],
  input  logic                         in_valid [NUM_INPUTS],
  output logic                         in_ready [NUM_INPUTS],

  output logic [DATA_WIDTH-1:0]        out_data,
  output logic                         out_valid,
  input  logic                         out_ready
);

  assign out_data  = in_data[sel];
  assign out_valid = sel_valid && in_valid[sel];

  always_comb begin
    for (int i = 0; i < NUM_INPUTS; i++) begin
      in_ready[i] = (int'(sel) == i) && out_ready && sel_valid;
    end
  end

endmodule
