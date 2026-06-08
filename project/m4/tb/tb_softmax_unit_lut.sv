// =============================================================================
// tb_softmax_unit_lut.sv -- unit test for M6 Tier 3 (s2 shifted scores +
//                           s5 multiplier register)
// =============================================================================
//
// Drives softmax_unit_lut with several test vectors and verifies:
//
//   1. probs_out sums to ~1.0 (mass conservation)
//   2. Constant-input vector -> uniform 1/vec_len distribution
//   3. One-hot input (dominant element) -> probability ~= 1 at the
//      dominant lane, ~0 everywhere else
//   4. Negative-input vector -> still produces valid probability
//      distribution (no overflow in exp_lut)
//   5. Latency = SOFTMAX_LAT = 8 + N_PHASES + ~divider cycles
//      For VEC_LEN = 64, N_LUT_BANKS = 8, N_PHASES = 8 -> base 16
//      + 48-cycle iterative divider = ~64 cycles.
//      Test uses a generous 200-cycle wait window with timeout fallback.
//
// What this catches specifically:
//   - M6 Tier 3 s2_shifted_scores precomputation didn't change the
//     numerical result (just moved it earlier in the pipeline)
//   - M6 Tier 3 s5 multiplier register correctly captures q_mul products
//     of (sum reciprocal) * (per-lane exp)
//   - vec_len masking still zeros out elements beyond active length
//
// Final summary line: "=== TB_SOFTMAX_LUT: PASS ===" or "FAIL ...".
// =============================================================================
`timescale 1ns/1ps

module tb_softmax_unit_lut;
  import accel_pkg::*;

  localparam int VEC_LEN = 64;

  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;

  logic               en, start;
  logic [7:0]         vec_len;
  logic signed [31:0] scores_in [VEC_LEN];
  logic               in_valid, out_valid;
  logic signed [31:0] probs_out [VEC_LEN];

  softmax_unit_lut #(
    .DATA_WIDTH  (32),
    .VEC_LEN     (VEC_LEN),
    .USE_PIPELINED_DIVIDER (1)
  ) duv (
    .clk(clk), .rst_n(rst_n), .en(en),
    .start(start), .vec_len(vec_len),
    .scores_in(scores_in), .in_valid(in_valid),
    .probs_out(probs_out), .out_valid(out_valid)
  );

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  int test_failures = 0;

  // Drive a vector + wait for out_valid (or timeout).
  // Returns the sum of probs and the max lane index + max value.
  task automatic drive_vector(input string label,
                              input int  vlen,
                              ref logic signed [31:0] vec [VEC_LEN],
                              output real prob_sum,
                              output int  max_idx,
                              output real max_val,
                              output bit  saw_valid);
    int   cyc = 0;
    real  vmax = -1e9;
    int   imax = 0;

    vec_len   <= 8'(vlen);
    for (int i = 0; i < VEC_LEN; i++)
      scores_in[i] <= vec[i];
    in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;
    for (int i = 0; i < VEC_LEN; i++)
      scores_in[i] <= '0;

    // Wait up to 200 cycles for out_valid
    saw_valid = 1'b0;
    while (cyc < 200 && !saw_valid) begin
      @(posedge clk);
      cyc++;
      if (out_valid) saw_valid = 1'b1;
    end

    if (!saw_valid) begin
      $display("  FAIL: %s -- out_valid never asserted in 200 cycles",
               label);
      prob_sum = 0.0;
      max_idx  = 0;
      max_val  = 0.0;
      return;
    end

    prob_sum = 0.0;
    for (int i = 0; i < vlen; i++) begin
      real p = from_q($signed(probs_out[i]));
      prob_sum += p;
      if (p > vmax) begin
        vmax = p;
        imax = i;
      end
    end
    max_val = vmax;
    max_idx = imax;

    $display("    %s: latency=%0d probs_sum=%0.4f max@%0d=%0.4f",
             label, cyc, prob_sum, imax, vmax);
  endtask

  task automatic check_uniform_distribution(input int vlen,
                                            input string label);
    logic signed [31:0] vec [VEC_LEN];
    real prob_sum, max_val;
    int  max_idx;
    bit  saw_valid;
    real expected_p;

    for (int i = 0; i < VEC_LEN; i++)
      vec[i] = (i < vlen) ? to_q(2.0) : '0;   // constant input

    drive_vector(label, vlen, vec, prob_sum, max_idx, max_val, saw_valid);

    if (!saw_valid) begin
      test_failures++;
      return;
    end

    expected_p = 1.0 / real'(vlen);
    if ((prob_sum - 1.0) > 0.02 || (prob_sum - 1.0) < -0.02) begin
      $display("  FAIL: %s -- probs sum %0.4f != 1.0", label, prob_sum);
      test_failures++;
    end else if ((max_val - expected_p) > 0.02
                 || (max_val - expected_p) < -0.02) begin
      $display("  FAIL: %s -- uniform expected %0.4f got max %0.4f",
               label, expected_p, max_val);
      test_failures++;
    end else
      $display("  PASS: %s -- uniform 1/%0d, sum=1.0",
               label, vlen);
  endtask

  task automatic check_one_hot(input int vlen,
                               input int hot_idx,
                               input string label);
    logic signed [31:0] vec [VEC_LEN];
    real prob_sum, max_val;
    int  max_idx;
    bit  saw_valid;

    for (int i = 0; i < VEC_LEN; i++)
      vec[i] = (i == hot_idx) ? to_q(6.0)
             : ((i < vlen)    ? to_q(-2.0) : '0);

    drive_vector(label, vlen, vec, prob_sum, max_idx, max_val, saw_valid);

    if (!saw_valid) begin
      test_failures++;
      return;
    end

    if ((prob_sum - 1.0) > 0.02 || (prob_sum - 1.0) < -0.02) begin
      $display("  FAIL: %s -- probs sum %0.4f != 1.0", label, prob_sum);
      test_failures++;
    end else if (max_idx != hot_idx) begin
      $display("  FAIL: %s -- expected dominant @%0d got @%0d",
               label, hot_idx, max_idx);
      test_failures++;
    end else if (max_val < 0.9) begin
      $display("  FAIL: %s -- dominant prob %0.4f < 0.9",
               label, max_val);
      test_failures++;
    end else
      $display("  PASS: %s -- dominant @%0d = %0.4f",
               label, hot_idx, max_val);
  endtask

  initial begin
    logic signed [31:0] neg_vec [VEC_LEN];
    real prob_sum, max_val;
    int  max_idx;
    bit  saw_valid;

    $display("=== tb_softmax_unit_lut: START ===");
    en       = 1;
    start    = 0;
    vec_len  = 8'd0;
    in_valid = 0;
    for (int i = 0; i < VEC_LEN; i++) scores_in[i] = '0;
    #20 rst_n = 1;
    #4;

    // ----- Test 1: vec_len = 64 uniform -----
    check_uniform_distribution(64, "T1: vec_len=64 uniform");

    // ----- Test 2: vec_len = 16 uniform (verifies vec_len masking) -----
    check_uniform_distribution(16, "T2: vec_len=16 uniform");

    // ----- Test 3: One-hot dominant at index 17 -----
    check_one_hot(64, 17, "T3: one-hot @17");

    // ----- Test 4: One-hot dominant at lane 0 (edge case) -----
    check_one_hot(64, 0, "T4: one-hot @0 edge");

    // ----- Test 5: One-hot at last lane (edge case) -----
    check_one_hot(64, 63, "T5: one-hot @63 edge");

    // ----- Test 6: Negative-input vector (verifies exp_lut doesn't overflow) -----
    for (int i = 0; i < VEC_LEN; i++)
      neg_vec[i] = to_q(-1.0 - 0.1 * real'(i));    // -1, -1.1, -1.2, ...
    drive_vector("T6: descending negatives", 64, neg_vec,
                 prob_sum, max_idx, max_val, saw_valid);
    if (!saw_valid) test_failures++;
    else if ((prob_sum - 1.0) > 0.02 || (prob_sum - 1.0) < -0.02) begin
      $display("  FAIL: T6 -- probs sum %0.4f != 1.0", prob_sum);
      test_failures++;
    end else if (max_idx != 0) begin
      $display("  FAIL: T6 -- dominant should be index 0 (least negative)");
      test_failures++;
    end else
      $display("  PASS: T6 -- descending negatives -> dominant @0");

    $display("");
    if (test_failures == 0)
      $display("=== TB_SOFTMAX_LUT: PASS ===");
    else
      $display("=== TB_SOFTMAX_LUT: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  initial begin
    #500000;
    $display("WATCHDOG: simulation timed out");
    $display("=== TB_SOFTMAX_LUT: FAIL (timeout) ===");
    $finish;
  end

endmodule
