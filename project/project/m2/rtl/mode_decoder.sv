// mode_decoder.sv — Converts host command into local enable/config signals
module mode_decoder
  import accel_pkg::*;
(
  input  cmd_pkt_t     cmd,
  input  logic         cmd_valid,

  output mode_t        mode,
  output fused_op_t    fused_sel,
  output logic [7:0]   dim_m,
  output logic [7:0]   dim_n,
  output logic [7:0]   dim_k,
  output logic [15:0]  addr_a,
  output logic [15:0]  addr_b,
  output logic [15:0]  addr_out,
  output logic         valid
);

  assign valid    = cmd_valid;
  assign mode     = cmd.mode;
  assign addr_a   = cmd.addr_a;
  assign addr_b   = cmd.addr_b;
  assign addr_out = cmd.addr_out;
  assign dim_m    = cmd.tile_m;
  assign dim_n    = cmd.tile_n;
  assign dim_k    = cmd.tile_k;

  // Select fused operation based on mode
  always_comb begin
    case (cmd.mode)
      MODE_FFN_FWD:  fused_sel = FUSED_GELU;
      MODE_FFN_BWD:  fused_sel = FUSED_GELU_GRAD;
      MODE_ATTN_FWD: fused_sel = FUSED_SOFTMAX;
      MODE_ATTN_BWD: fused_sel = FUSED_BYPASS;
      default:       fused_sel = FUSED_BYPASS;
    endcase
  end

endmodule
