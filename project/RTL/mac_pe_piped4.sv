// mac_pe_piped4.sv -- Mixed-precision Q4.4 / Q16.16 MAC, 4-stage pipeline (M5 option D)
//
// Drop-in port-compatible replacement for mac_pe.sv and mac_pe_piped.sv.
// Same Q4.4*Q4.4 -> Q8.8 -> Q16.16 arithmetic and same systolic
// forwarding behavior as the legacy mac_pe; ONLY the pipeline depth
// differs.
//
// Pipeline split (3 extra registers vs legacy mac_pe.sv):
//
//   Stage 1a:  in -> sat -> 8x4 partial mul (a * b[3:0])
//                                                      -> [reg]
//   Stage 1b:  [reg] -> 8x4 partial mul (a * b[7:4]) + shift-add
//                                                      -> [reg product_q88_r]
//   Stage 2:   [reg] -> Q8.8 -> Q16.16 align + lower 16-bit acc add
//                                                      -> [reg lo_sum_r, carry_r]
//   Stage 3:   [reg] -> upper 16-bit acc add with carry-in
//                                                      -> [reg acc_r]
//
// vs. the M5 mac_pe_piped (2 stages): the multiplier is split across
// cycles 1a/1b (no single stage carries the full 8x8 array reduction),
// and the 32-bit accumulator add is split across cycles 2/3 at bit 16
// (the carry from the low half is registered into the high half).
//
// At Sky130 SS the longest stage drops from ~7-8 ns (mac_pe_piped) to
// ~3-3.5 ns; on SAED32 SS it drops to ~1.5-2 ns. Projected f_max at
// SAED32 SS: ~500-600 MHz (vs ~285 MHz for mac_pe_piped).
//
// Cost:
//   - +3 cycles MAC latency vs legacy mac_pe (K-long dot product is now
//     K+3 cycles instead of K), +2 cycles vs mac_pe_piped.
//   - Per-PE flops: ~50 extra vs legacy (~33 more than mac_pe_piped),
//     ~5 % more area per PE.
//   - clear_acc must be delayed 3 cycles to align with the accumulator
//     add in Stage 3 (vs 1 cycle in mac_pe_piped).
//   - Caller (stream_pipeline.sv / accel_engine.sv) MUST bump
//     DRAIN_CYCLES by 3 vs legacy (or by 2 vs mac_pe_piped); the
//     systolic array still issues one MAC per cycle, but each output
//     value settles 3 cycles later than legacy.
//
// West/north operand forwarding (a_out, b_out) stays 1-cycle (matches
// mac_pe.sv and mac_pe_piped.sv) so systolic feed timing is independent
// of the internal pipeline depth.
//
// Implementation choice for the multiplier split: decompose the 8x8 mul
// into a 8x4 partial on b[3:0] (lower nibble) computed in Stage 1a, and
// a 8x4 partial on b[7:4] (upper nibble, signed) computed in Stage 1b
// then shift-added to the registered lower partial. This is the same
// algebraic split a Wallace-tree mul uses at its midpoint, but kept
// explicit at the SV level so the synthesis tool sees a clean cut and
// can balance retiming without inserting a midpoint flop on its own
// (which would have been timing-equivalent but harder to verify).
module mac_pe_piped4
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

  // ----- Combinational: quantize to Q4.4 (saturation only, no mul yet) -----
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

  // ----- Stage 1a comb: lower-nibble partial product (a * b[3:0]) -----
  // b_lo treated as UNSIGNED 4-bit; sign-extension is handled by the
  // upper-nibble term in Stage 1b. Result is 12-bit signed (8-bit signed
  // a * 4-bit unsigned b_lo -> 12-bit signed).
  logic [3:0]         b_lo;
  logic signed [11:0] prod_lower_comb;
  assign b_lo            = b_q44[3:0];
  assign prod_lower_comb = a_q44 * $signed({1'b0, b_lo});

  // ----- Stage 1a register: partial product + forwarded operands -----
  logic signed [11:0]       prod_lower_r;
  logic signed [MULT_W-1:0] a_q44_r;
  logic signed [3:0]        b_hi_r;     // SIGNED upper nibble of b
  logic                     clear_acc_r1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prod_lower_r <= '0;
      a_q44_r      <= '0;
      b_hi_r       <= '0;
      clear_acc_r1 <= 1'b0;
    end else if (en) begin
      prod_lower_r <= prod_lower_comb;
      a_q44_r      <= a_q44;
      b_hi_r       <= b_q44[7:4];   // signed 4-bit, sign-extends naturally
      clear_acc_r1 <= clear_acc;
    end
  end

  // ----- Stage 1b comb: upper-nibble partial product + shift-add -----
  // 8x4 signed*signed -> 12-bit signed, shifted left 4, plus registered
  // lower partial -> full Q8.8 product (16-bit signed).
  logic signed [11:0] prod_upper_comb;
  logic signed [15:0] product_q88_comb;

  assign prod_upper_comb  = a_q44_r * b_hi_r;
  assign product_q88_comb = ({{4{prod_upper_comb[11]}}, prod_upper_comb} <<< 4)
                          +  {{4{prod_lower_r[11]}},   prod_lower_r};

  // ----- Stage 1b register: full Q8.8 product -----
  logic signed [15:0] product_q88_r;
  logic               clear_acc_r2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      product_q88_r <= '0;
      clear_acc_r2  <= 1'b0;
    end else if (en) begin
      product_q88_r <= product_q88_comb;
      clear_acc_r2  <= clear_acc_r1;
    end
  end

  // ----- Stage 2 comb: Q8.8 -> Q16.16 align + lower 16-bit acc add -----
  // The accumulator is 32-bit signed Q16.16. We split the add at bit 16:
  // Stage 2 computes the low-16 sum + carry-out; Stage 3 adds the carry
  // into the upper 16 bits.
  logic signed [DATA_WIDTH-1:0] product_q;
  assign product_q = {
      { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88_r[2*MULT_W-1]} },
      product_q88_r,
      { Q88_PROMOTE_SH{1'b0} }
  };

  // Split-add: lower-16 + carry to upper-16.
  // Pre-clear logic: if clear_acc_r2 is high, treat the accumulator as 0
  // for this iteration's add. Done in the operand path (not by zeroing
  // the registered acc) so the carry-and-upper path stays straight.
  logic [15:0] acc_lo_operand;
  logic [15:0] acc_hi_operand;
  logic [16:0] lo_sum_comb;     // 17-bit to capture carry-out

  // Forward-declare the stage-3 accumulator (assigned at line ~190) so that
  // Questa's strict elaborator accepts the stage-2 operand reads below.
  logic signed [DATA_WIDTH-1:0] acc_r;

  assign acc_lo_operand = clear_acc_r2 ? 16'h0 : acc_r[15:0];
  assign acc_hi_operand = clear_acc_r2 ? 16'h0 : acc_r[31:16];
  assign lo_sum_comb    = {1'b0, acc_lo_operand} + {1'b0, product_q[15:0]};

  // ----- Stage 2 register: lower-16 sum + carry + upper-16 operands -----
  // Carry is the bit-16 of the 17-bit lo_sum_comb.
  logic [15:0]        lo_sum_r;
  logic               carry_r;
  logic signed [15:0] product_hi_r;       // upper 16 bits of product_q
  logic [15:0]        acc_hi_r2;          // upper 16 bits of acc_r (post-clear)
  logic               clear_acc_r3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lo_sum_r     <= 16'h0;
      carry_r      <= 1'b0;
      product_hi_r <= 16'sh0;
      acc_hi_r2    <= 16'h0;
      clear_acc_r3 <= 1'b0;
    end else if (en) begin
      lo_sum_r     <= lo_sum_comb[15:0];
      carry_r      <= lo_sum_comb[16];
      product_hi_r <= product_q[31:16];
      acc_hi_r2    <= acc_hi_operand;
      clear_acc_r3 <= clear_acc_r2;
    end
  end

  // ----- Stage 3 comb: upper 16-bit acc add with carry-in -----
  logic signed [15:0] hi_sum_comb;
  assign hi_sum_comb = product_hi_r + $signed({15'h0, carry_r}) + $signed(acc_hi_r2);

  // ----- Stage 3 register (the accumulator itself) -----
  // (acc_r declared above at the stage-2 operand read site.)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out <= '0;
      b_out <= '0;
      acc_r <= '0;
    end else if (en) begin
      // West/north forwarding stays 1-cycle (matches mac_pe.sv and the
      // mac_pe_piped DRAIN behavior).
      a_out <= a_in;
      b_out <= b_in;
      // Accumulator: assemble from the two halves. clear_acc_r3 zeroes
      // the entire accumulator; otherwise both halves accumulate.
      if (clear_acc_r3)
        acc_r <= '0;
      else
        acc_r <= {hi_sum_comb, lo_sum_r};
    end
  end

  assign acc_out = acc_r;

endmodule
