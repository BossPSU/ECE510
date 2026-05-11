// tb_mac_pe.sv -- Unit TB for the mixed-precision MAC PE
//
// Covers:
//   1. Basic in-range MAC (2.0*3.0 + 1.0*4.0 = 10.0, Q4.4 exact)
//   2. Positive saturation (operand > +7.9375 clamps to +7.9375)
//   3. Negative saturation (operand < -8.0 clamps to -8.0)
//   4. Sub-resolution rounding (Q4.4 step = 0.0625)
//   5. clear_acc behaviour
`timescale 1ns/1ps

module tb_mac_pe;
  import accel_pkg::*;

  logic                clk, rst_n, en, clear_acc;
  logic signed [31:0]  a_in, a_out, b_in, b_out, acc_out;

  mac_pe #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  // ----- Q16.16 <-> real helpers -----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // ----- in-line check helper -----
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

  // ----- one-cycle MAC step -----
  task automatic mac_step (input real a, input real b);
      a_in = to_q(a);
      b_in = to_q(b);
      @(posedge clk); #1;
  endtask

  initial begin
    $display("=== tb_mac_pe: START (mixed precision Q4.4 mul, Q16.16 acc) ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    a_in = '0; b_in = '0;
    total_pass = 0; total_fail = 0;

    #10 rst_n = 1;
    #2;

    // ---- Test 1: in-range MAC ----
    // 2.0 and 3.0 are exact in Q4.4 (multiples of 0.0625), no saturation.
    en = 1; clear_acc = 1;
    mac_step(0.0, 0.0);                  // clear cycle
    clear_acc = 0;
    mac_step(2.0, 3.0);                  // acc += 6.0
    mac_step(1.0, 4.0);                  // acc += 4.0   -> 10.0
    mac_step(0.0, 0.0);                  // settle (no further accumulation)
    check_close("in-range MAC sum",
                from_q(acc_out), 10.0, 0.125);   // 2 LSBs of Q4.4 each

    // ---- Test 2: positive saturation on a ----
    // Feed a = 100.0 (way beyond Q4.4 range +7.9375) and b = 2.0.
    // Expected: a saturates to +7.9375, product = 7.9375 * 2.0 = 15.875.
    // Add on top of the previous 10.0 -> ~25.875.
    mac_step(100.0, 2.0);
    mac_step(0.0, 0.0);
    check_close("a positive saturation",
                from_q(acc_out), 10.0 + 7.9375 * 2.0, 0.25);

    // ---- Test 3: negative saturation on b ----
    // Reset accumulator, then b = -50.0 saturates to -8.0; a = 1.5.
    clear_acc = 1; mac_step(0.0, 0.0);
    clear_acc = 0;
    mac_step(1.5, -50.0);
    mac_step(0.0, 0.0);
    check_close("b negative saturation",
                from_q(acc_out), 1.5 * -8.0, 0.25);

    // ---- Test 4: sub-Q4.4 resolution ----
    // 0.5 * 0.5 = 0.25 (Q4.4 exact since 0.5 = 8/16, 0.25 = 4/16).
    clear_acc = 1; mac_step(0.0, 0.0);
    clear_acc = 0;
    mac_step(0.5, 0.5);
    mac_step(0.0, 0.0);
    check_close("Q4.4 exact small product",
                from_q(acc_out), 0.25, 0.0625);

    // ---- Test 5: clear_acc ----
    clear_acc = 1; mac_step(0.0, 0.0);
    clear_acc = 0;
    mac_step(0.0, 0.0);
    check_close("clear_acc zeros accumulator",
                from_q(acc_out), 0.0, 1e-6);

    // ---- Summary ----
    $display("");
    $display("  Summary: %0d PASS, %0d FAIL", total_pass, total_fail);
    if (total_fail == 0)
        $display("=== tb_mac_pe: ALL TESTS PASS ===");
    else
        $display("=== tb_mac_pe: FAIL (%0d mismatch) ===", total_fail);

    $finish;
  end

  // Watchdog
  initial begin
    #2000;
    $display("TIMEOUT - tb_mac_pe did not finish");
    $finish;
  end

endmodule
