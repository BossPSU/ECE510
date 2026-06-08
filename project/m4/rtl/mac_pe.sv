// mac_pe.sv — Mixed-precision Q4.4 / Q16.16 MAC processing element
//
// Per-PE precision policy:
//   * Forwarded west/north operands stay Q16.16 so the systolic feed
//     and any inter-PE plumbing remain at full precision.
//   * Each operand is quantized to Q4.4 (8-bit signed) immediately
//     before the multiplier, with saturation to +/-7.9375 / -8.0.
//   * The multiplier itself is 8x8 -> 16-bit signed (Q8.8). Area scales
//     as O(MULT_W^2), so this is ~16x smaller than the original 32x32
//     Q16.16 multiplier.
//   * The Q8.8 product is sign-extended and left-shifted into Q16.16
//     so the accumulator keeps full headroom and resolution across
//     long dot products. No saturation needed on the accumulator add
//     beyond what the existing 32-bit width provides.
//
// This mirrors NVIDIA's NVFP4-style flow (low-precision multiply,
// high-precision accumulator) at fixed point. The MULT_W / MULT_FRAC
// knobs in accel_pkg let you trade quantization error for multiplier
// area without touching this file.
module mac_pe
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            clear_acc,

  // West (row) input/output -- Q16.16, propagated unchanged
  input  logic signed [DATA_WIDTH-1:0]    a_in,
  output logic signed [DATA_WIDTH-1:0]    a_out,

  // North (column) input/output -- Q16.16, propagated unchanged
  input  logic signed [DATA_WIDTH-1:0]    b_in,
  output logic signed [DATA_WIDTH-1:0]    b_out,

  // Accumulator (Q16.16)
  output logic signed [DATA_WIDTH-1:0]    acc_out
);

  // --------------------------------------------------------------------
  // Quantize Q16.16 -> Q4.4 at the multiplier inputs (with saturation)
  //
  // Arithmetic-shift right by Q44_ALIGN_SH (= FRAC_BITS - MULT_FRAC) to
  // re-align the binary point, then clamp to the 8-bit signed range.
  // Clamping after the shift makes the saturation thresholds simple
  // integer constants (+127 and -128).
  // --------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] a_shifted, b_shifted;
  logic signed [MULT_W-1:0]     a_q44, b_q44;

  assign a_shifted = a_in >>> Q44_ALIGN_SH;
  assign b_shifted = b_in >>> Q44_ALIGN_SH;

  assign a_q44 = (a_shifted >  32'sd127) ?  8'sd127 :
                 (a_shifted < -32'sd128) ? -8'sd128 :
                                            a_shifted[MULT_W-1:0];
  assign b_q44 = (b_shifted >  32'sd127) ?  8'sd127 :
                 (b_shifted < -32'sd128) ? -8'sd128 :
                                            b_shifted[MULT_W-1:0];

  // --------------------------------------------------------------------
  // 8x8 -> 16-bit Q8.8 multiply
  // --------------------------------------------------------------------
  logic signed [2*MULT_W-1:0] product_q88;
  assign product_q88 = a_q44 * b_q44;

  // --------------------------------------------------------------------
  // Promote Q8.8 -> Q16.16 for accumulation.
  // Q8.8 has MULT_FRAC*2 fractional bits; Q16.16 has FRAC_BITS. Shift
  // left by the difference (Q88_PROMOTE_SH = 8 with defaults) and
  // sign-extend to DATA_WIDTH.
  // --------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] product_q;
  assign product_q = {
      { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88[2*MULT_W-1]} },
      product_q88,
      { Q88_PROMOTE_SH{1'b0} }
  };

  // --------------------------------------------------------------------
  // Accumulator + west/north forwarding registers
  // (unchanged from the original Q16.16-only flow)
  // --------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] acc_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc_r <= '0;
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      if (clear_acc)
        acc_r <= '0;
      else
        acc_r <= acc_r + product_q;
    end
  end

  assign acc_out = acc_r;

endmodule
