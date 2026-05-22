// synth_top.sv -- OpenLane 2 synthesis target for CF07.
//
// This is the mixed-precision Q4.4/Q16.16 MAC processing element from
// project/RTL/mac_pe.sv, inlined into a single self-contained file with
// the parameter set hardcoded as localparams (so OpenLane does not need
// to read project/RTL/accel_pkg.sv).
//
// Quantize Q16.16 inputs to Q4.4, multiply 8x8 -> Q8.8, promote to
// Q16.16, accumulate. See ../../../project/RTL/mac_pe.sv for the
// fully-parameterized version and ../../../project/RTL/timing_analysis.md
// for the Cadence Genus characterization of the same RTL on SAED32.

module mac_pe #(
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

  // ----- Mixed-precision MAC parameters (inlined from accel_pkg) -----
  // Q4.4 multiplier-input format
  localparam int MULT_W         = 8;                 // multiplier-input bit width
  localparam int MULT_FRAC      = 4;                 // fractional bits in Q4.4
  localparam int FRAC_BITS      = 16;                // Q16.16 fractional bits
  localparam int Q44_ALIGN_SH   = FRAC_BITS - MULT_FRAC;     // 12
  localparam int Q88_PROMOTE_SH = FRAC_BITS - 2*MULT_FRAC;   //  8

  // --------------------------------------------------------------------
  // Quantize Q16.16 -> Q4.4 at the multiplier inputs (with saturation)
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
  // Promote Q8.8 -> Q16.16 for accumulation
  // --------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] product_q;
  assign product_q = {
      { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88[2*MULT_W-1]} },
      product_q88,
      { Q88_PROMOTE_SH{1'b0} }
  };

  // --------------------------------------------------------------------
  // Accumulator + west/north forwarding registers
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
