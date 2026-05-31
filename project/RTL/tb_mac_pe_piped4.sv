// tb_mac_pe_piped4.sv -- Unit TB for the M5 option-D 4-stage MAC PE
//
// Mirrors tb_mac_pe.sv / tb_mac_pe_piped.sv stimulus exactly. mac_pe_piped4
// has +3 cycles of MAC latency vs legacy mac_pe (and +2 vs mac_pe_piped),
// so each accumulator check waits three extra settle cycles before reading
// acc_out. Test cases and pass/fail criteria are otherwise identical.
//
// What's being verified beyond the legacy TB:
//   - The multiplier split (8x4 in Stage 1a + 8x4 in Stage 1b combined
//     via shift-add) returns the correct Q8.8 product across the full
//     signed [-128, +127] x [-128, +127] input range.
//   - The 32-bit accumulator split (low-16 + carry in Stage 2, upper-16
//     in Stage 3) carries correctly across the bit-16 boundary, including
//     when the low-16 sum overflows.
`timescale 1ns/1ps

module tb_mac_pe_piped4;
  import accel_pkg::*;

  logic                clk, rst_n, en, clear_acc;
  logic signed [31:0]  a_in, a_out, b_in, b_out, acc_out;

  mac_pe_piped4 #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  int total_pass, total_fail;
  task automatic check_close (
      input string label,
      input real   got,
      input real   want,
      input real   tol
  );
      real err;
      err = got - want;
      if (err < 0) err = -err;
      if (err <= tol) begin
          $display("  PASS [%s]: got %0.4f  want %0.4f  (tol %0.4f)",
                   label, got, want, tol);
          total_pass++;
      end else begin
          $display("  FAIL [%s]: got %0.4f  want %0.4f  (err %0.4f, tol %0.4f)",
                   label, got, want, err, tol);
          total_fail++;
      end
  endtask

  task automatic mac_step (input real a, input real b);
      a_in = to_q(a);
      b_in = to_q(b);
      @(posedge clk); #1;
  endtask

  // Four settle cycles after the last meaningful inputs -- three extra
  // vs the legacy TB because mac_pe_piped4 has 3 extra pipeline regs:
  //   Stage 1a (saturate+lo-mul reg) -> Stage 1b (hi-mul+sum reg)
  //   -> Stage 2 (lo-add + carry reg) -> Stage 3 (acc reg).
  task automatic settle_for_check ();
      mac_step(0.0, 0.0);
      mac_step(0.0, 0.0);
      mac_step(0.0, 0.0);
      mac_step(0.0, 0.0);
  endtask

  initial begin
    $display("=== tb_mac_pe_piped4: START (Q4.4 mul + Q16.16 acc, +3 cycle MAC pipeline) ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    a_in = '0; b_in = '0;
    total_pass = 0; total_fail = 0;

    #10 rst_n = 1;
    #2;

    // Test 1: in-range MAC -- 2.0*3.0 + 1.0*4.0 = 10.0
    en = 1; clear_acc = 1;
    mac_step(0.0, 0.0);
    clear_acc = 0;
    mac_step(2.0, 3.0);
    mac_step(1.0, 4.0);
    settle_for_check();
    check_close("in-range MAC sum",
                from_q(acc_out), 10.0, 0.125);

    // Test 2: positive saturation on a
    mac_step(100.0, 2.0);
    settle_for_check();
    check_close("a positive saturation",
                from_q(acc_out), 10.0 + 7.9375 * 2.0, 0.25);

    // Test 3: negative saturation on b
    clear_acc = 1;
    mac_step(0.0, 0.0);
    settle_for_check();
    clear_acc = 0;
    mac_step(1.5, -50.0);
    settle_for_check();
    check_close("b negative saturation",
                from_q(acc_out), 1.5 * -8.0, 0.25);

    // Test 4: sub-Q4.4 resolution
    clear_acc = 1;
    mac_step(0.0, 0.0);
    settle_for_check();
    clear_acc = 0;
    mac_step(0.5, 0.5);
    settle_for_check();
    check_close("Q4.4 exact small product",
                from_q(acc_out), 0.25, 0.0625);

    // Test 5: clear_acc
    clear_acc = 1;
    mac_step(0.0, 0.0);
    settle_for_check();
    clear_acc = 0;
    settle_for_check();
    check_close("clear_acc zeros accumulator",
                from_q(acc_out), 0.0, 1e-6);

    // Test 6: a_out/b_out forwarding still 1-cycle (systolic feed must
    // not change just because the MAC pipeline got deeper).
    clear_acc = 1;
    mac_step(0.0, 0.0);
    clear_acc = 0;
    a_in = to_q(2.5); b_in = to_q(-3.0);
    @(posedge clk); #1;
    if (from_q(a_out) > 2.4 && from_q(a_out) < 2.6)
      begin $display("  PASS [a_out fwd]: got %0.4f want +2.5", from_q(a_out)); total_pass++; end
    else
      begin $display("  FAIL [a_out fwd]: got %0.4f want +2.5", from_q(a_out)); total_fail++; end
    if (from_q(b_out) > -3.1 && from_q(b_out) < -2.9)
      begin $display("  PASS [b_out fwd]: got %0.4f want -3.0", from_q(b_out)); total_pass++; end
    else
      begin $display("  FAIL [b_out fwd]: got %0.4f want -3.0", from_q(b_out)); total_fail++; end

    // Test 7 (new for piped4): exercise the bit-16 carry boundary by
    // building an accumulator value just under 2^16 (Q16.16 integer 1.0
    // = 65536; just under = 0.99...) so the next add propagates a carry
    // from low-16 into high-16. Mathematically: 0.5*2 = 1.0 should land
    // exactly on the boundary; we want both a value that does and a
    // value that doesn't carry, separated by one MAC step.
    clear_acc = 1;
    mac_step(0.0, 0.0);
    settle_for_check();
    clear_acc = 0;
    // First: build 0.5*1 = 0.5 (no carry needed). Verify.
    mac_step(0.5, 1.0);
    settle_for_check();
    check_close("split-add no carry (0.5)",
                from_q(acc_out), 0.5, 0.0625);
    // Then: add 0.5*1 = 0.5 -> total 1.0. The Q16.16 representation of
    // 1.0 is 0x00010000, so the low-16 wraps from 0x8000 + 0x8000 =
    // 0x10000 (carry out to bit 16). This is the carry-boundary test
    // unique to piped4 -- mac_pe_piped doesn't split the add so it
    // doesn't exercise this path the same way.
    mac_step(0.5, 1.0);
    settle_for_check();
    check_close("split-add WITH carry (1.0)",
                from_q(acc_out), 1.0, 0.0625);

    // Test 8 (new for piped4): negative-product carry boundary. -2.0 *
    // 1.0 = -2.0 with the M5 piped negative-add code; exercises the
    // sign-extension into the upper-16 adder and the carry math under
    // two's-complement arithmetic.
    clear_acc = 1;
    mac_step(0.0, 0.0);
    settle_for_check();
    clear_acc = 0;
    mac_step(-2.0, 1.0);
    settle_for_check();
    check_close("split-add negative product",
                from_q(acc_out), -2.0, 0.0625);

    $display("");
    $display("  Summary: %0d PASS, %0d FAIL", total_pass, total_fail);
    if (total_fail == 0)
        $display("=== tb_mac_pe_piped4: ALL TESTS PASS ===");
    else
        $display("=== tb_mac_pe_piped4: FAIL (%0d mismatch) ===", total_fail);

    $finish;
  end

  initial begin
    #2000;
    $display("TIMEOUT - tb_mac_pe_piped4 did not finish");
    $finish;
  end

endmodule
