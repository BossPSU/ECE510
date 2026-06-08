// mac_pe_piped.sv — Mixed-precision Q4.4 / Q16.16 MAC with mid-MAC pipeline (M5)
//
// Drop-in replacement for mac_pe.sv. Same port list, same Q16.16
// arithmetic, same systolic forwarding behavior. The ONLY structural
// difference is one extra register between the 8x8 Q4.4 multiplier
// output and the Q16.16 alignment+accumulator add. The change splits
// the leaf critical path roughly in half:
//
//   Original:
//     in -> sat(5) -> 8x8 mul(15-20) -> align(3) -> Q16.16 add(25-30) -> reg
//     ~50-60 gate levels total -> 14.5 ns at Sky130 SS corner (cf07 leaf)
//
//   This module:
//     in -> sat(5) -> 8x8 mul(15-20) -> [reg]
//     [reg] -> align(3) -> Q16.16 add(25-30) -> reg
//     ~25-30 gate levels per stage -> ~7-8 ns at Sky130 SS
//
// Cost: +1 cycle of MAC latency (the K-long dot product takes K+1
// cycles instead of K). No throughput change -- the systolic array
// still issues one MAC per cycle; the new register just delays each
// accumulation by 1 cycle, which propagates uniformly along the array.
//
// The west/north operand forwarding registers (a_out, b_out) are
// unchanged -- they're already 1-cycle delays of a_in/b_in, so the
// systolic feed timing is not affected by mac_pe's internal pipeline
// depth.
//
// Stream_pipeline / accel_engine MUST bump DRAIN_CYCLES by 1 when this
// module is selected (gated by the USE_PIPED_MAC parameter in the
// caller).
module mac_pe_piped
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            clear_acc,

  input  logic signed [DATA_WIDTH-1:0]    a_in,
  output logic signed [DATA_WIDTH-1:0]    a_out,

  input  logic signed [DATA_WIDTH-1:0]    b_in,
  output logic signed [DATA_WIDTH-1:0]    b_out,

  output logic signed [DATA_WIDTH-1:0]    acc_out
);

  // ----- Combinational stage 1: quantize to Q4.4, 8x8 multiply -----
  logic signed [DATA_WIDTH-1:0] a_shifted, b_shifted;
  logic signed [MULT_W-1:0]     a_q44, b_q44;
  logic signed [2*MULT_W-1:0]   product_q88_comb;

  assign a_shifted = a_in >>> Q44_ALIGN_SH;
  assign b_shifted = b_in >>> Q44_ALIGN_SH;

  assign a_q44 = (a_shifted >  32'sd127) ?  8'sd127 :
                 (a_shifted < -32'sd128) ? -8'sd128 :
                                            a_shifted[MULT_W-1:0];
  assign b_q44 = (b_shifted >  32'sd127) ?  8'sd127 :
                 (b_shifted < -32'sd128) ? -8'sd128 :
                                            b_shifted[MULT_W-1:0];

  assign product_q88_comb = a_q44 * b_q44;

  // ----- Pipeline register (NEW vs mac_pe.sv) -----
  // Q8.8 product (16-bit signed) + delayed clear_acc handshake.
  logic signed [2*MULT_W-1:0]   product_q88_r;
  logic                         clear_acc_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      product_q88_r <= '0;
      clear_acc_r   <= 1'b0;
    end else if (en) begin
      product_q88_r <= product_q88_comb;
      clear_acc_r   <= clear_acc;
    end
  end

  // ----- Combinational stage 2: Q8.8 -> Q16.16, accumulator add -----
  logic signed [DATA_WIDTH-1:0] product_q;
  assign product_q = {
      { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88_r[2*MULT_W-1]} },
      product_q88_r,
      { Q88_PROMOTE_SH{1'b0} }
  };

  // ----- Forwarding + accumulator registers -----
  logic signed [DATA_WIDTH-1:0] acc_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc_r <= '0;
    end else if (en) begin
      // West/north forwarding stays 1-cycle (matches original mac_pe).
      a_out <= a_in;
      b_out <= b_in;
      // Accumulator update uses the registered product (1 cycle behind
      // the inputs), and the registered clear_acc that aligns with it.
      if (clear_acc_r)
        acc_r <= '0;
      else
        acc_r <= acc_r + product_q;
    end
  end

  assign acc_out = acc_r;

endmodule
