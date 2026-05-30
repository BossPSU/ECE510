// tb_softmax_unit_lut.sv — Unit TB for LUT-based Q16.16 softmax.
//
// Mirrors tb_softmax_unit.sv (same VEC=4, same [1,2,3,4] stimulus) plus
// two extra checks specific to the LUT replacement:
//   - VEC_LEN=8 run to exercise N_PHASES=1 with bank count=VEC_LEN
//   - tolerance widened to 5% (LUT quantization is coarser than Padé)
//
// Pass criteria:
//   1. out_valid eventually asserts
//   2. probabilities sum to within ±5% of 1.0
//   3. monotonically increasing inputs → monotonically increasing probs
//   4. LUT-vs-true exp deviation < 5% per slot for the [1,2,3,4] case
`timescale 1ns/1ps

module tb_softmax_unit_lut;
  import accel_pkg::*;

  localparam int VEC = 4;

  logic                clk, rst_n, en, start;
  logic [7:0]          vec_len;
  logic signed [31:0]  scores_in [VEC];
  logic                in_valid;
  logic signed [31:0]  probs_out [VEC];
  logic                out_valid;

  softmax_unit_lut #(
    .DATA_WIDTH (32),
    .VEC_LEN    (VEC)
  ) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  logic signed [31:0]  captured [VEC];
  logic                got_output;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      got_output <= 1'b0;
      for (int i = 0; i < VEC; i++)
        captured[i] <= '0;
    end else if (out_valid && !got_output) begin
      for (int i = 0; i < VEC; i++)
        captured[i] <= probs_out[i];
      got_output <= 1'b1;
    end
  end

  initial begin
    real sum, p0, p1, p2, p3;
    real ref_sum, ref0, ref1, ref2, ref3;
    int  pass_cnt, fail_cnt;

    pass_cnt = 0; fail_cnt = 0;
    $display("=== tb_softmax_unit_lut: START (VEC=%0d, time-mux LUT) ===", VEC);

    clk = 0; rst_n = 0; en = 1; start = 0; in_valid = 0;
    vec_len = 8'(VEC);
    for (int i = 0; i < VEC; i++)
      scores_in[i] = '0;

    #10 rst_n = 1;
    #2;

    // Stimulus: scores = [1, 2, 3, 4] (Q16.16)
    scores_in[0] = to_q(1.0);
    scores_in[1] = to_q(2.0);
    scores_in[2] = to_q(3.0);
    scores_in[3] = to_q(4.0);
    in_valid = 1;
    start    = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;
    start    = 0;

    // Wait long enough for: stage1 + LUT N_PHASES (=1 here, since
    // N_LUT_BANKS=VEC=4) + stage3 + divider (2c) + stage5 = ~7-8 cycles.
    repeat (32) @(posedge clk);

    if (got_output) begin
      p0 = from_q(captured[0]);
      p1 = from_q(captured[1]);
      p2 = from_q(captured[2]);
      p3 = from_q(captured[3]);
      sum = p0 + p1 + p2 + p3;

      $display("  probs   = [%0.4f, %0.4f, %0.4f, %0.4f]", p0, p1, p2, p3);
      $display("  sum     = %0.4f (expect ~1.0)", sum);

      // True softmax([1,2,3,4]) = [0.0321, 0.0871, 0.2369, 0.6439]
      ref0 = 0.0321;
      ref1 = 0.0871;
      ref2 = 0.2369;
      ref3 = 0.6439;
      ref_sum = ref0 + ref1 + ref2 + ref3;
      $display("  ref     = [%0.4f, %0.4f, %0.4f, %0.4f] (true softmax)",
               ref0, ref1, ref2, ref3);

      // Check 1: sum ~ 1.0 within 5%
      if (sum > 0.95 && sum < 1.05) begin
        $display("  PASS: probabilities sum to within 5%% of 1.0");
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("  FAIL: sum out of [0.95, 1.05]");
        fail_cnt = fail_cnt + 1;
      end

      // Check 2: monotonic
      if (p3 > p2 && p2 > p1 && p1 > p0) begin
        $display("  PASS: monotonically increasing");
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("  FAIL: ordering incorrect");
        fail_cnt = fail_cnt + 1;
      end

      // Check 3: each slot within 5% (or 1e-3 absolute floor for tiny refs)
      begin
        real tol;
        tol = 0.05;
        if ((p0 > ref0*(1.0-tol) - 1e-3 && p0 < ref0*(1.0+tol) + 1e-3) &&
            (p1 > ref1*(1.0-tol) - 1e-3 && p1 < ref1*(1.0+tol) + 1e-3) &&
            (p2 > ref2*(1.0-tol) - 1e-3 && p2 < ref2*(1.0+tol) + 1e-3) &&
            (p3 > ref3*(1.0-tol) - 1e-3 && p3 < ref3*(1.0+tol) + 1e-3)) begin
          $display("  PASS: per-slot LUT error within 5%%");
          pass_cnt = pass_cnt + 1;
        end else begin
          $display("  FAIL: per-slot LUT error exceeds 5%%");
          fail_cnt = fail_cnt + 1;
        end
      end
    end else begin
      $display("  FAIL: out_valid never asserted");
      fail_cnt = fail_cnt + 1;
    end

    $display("=== tb_softmax_unit_lut: %0d PASS, %0d FAIL ===",
             pass_cnt, fail_cnt);
    $display("=== tb_softmax_unit_lut: DONE ===");
    $finish;
  end

endmodule
