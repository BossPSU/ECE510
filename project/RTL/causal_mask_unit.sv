// causal_mask_unit.sv — Applies causal mask for attention
// Forces upper-triangle elements to large negative value
module causal_mask_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int VEC_LEN    = 64
)(
  input  logic signed [DATA_WIDTH-1:0]   data_in [VEC_LEN],
  input  logic [7:0]                     row_idx,
  input  logic                           in_valid,
  output logic signed [DATA_WIDTH-1:0]   data_out [VEC_LEN],
  output logic                    out_valid
);

  // Large negative value for masked positions in Q16.16 (~-32767)
  localparam logic signed [DATA_WIDTH-1:0] NEG_INF = 32'sh80010000;

  assign out_valid = in_valid;

  // Mask: zero out positions where col > row (future tokens)
  always_comb begin
    for (int c = 0; c < VEC_LEN; c++) begin
      if (c > int'(row_idx))
        data_out[c] = NEG_INF;
      else
        data_out[c] = data_in[c];
    end
  end

endmodule
