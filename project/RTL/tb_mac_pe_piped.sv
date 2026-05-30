// tb_mac_pe_piped.sv -- Unit TB for the M5 mid-MAC pipelined PE
//
// Mirrors tb_mac_pe.sv stimulus exactly. The piped version has +1
// cycle of MAC latency, so each accumulator check waits one extra
// settle cycle before reading acc_out. Otherwise the test cases and
// pass/fail criteria are identical to the legacy mac_pe TB.
`timescale 1ns/1ps

module tb_mac_pe_piped;
  import accel_pkg::*;

  logic                clk, rst_n, en, clear_acc;
  logic signed [31:0]  a_in, a_out, b_in, b_out, acc_out;

  mac_pe_piped #(.DATA_WIDTH(32)) dut (.*);

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

  // Two settle cycles after the last meaningful inputs -- one extra vs
  // the legacy TB because mac_pe_piped's mid-MAC register adds 1 cycle.
  task automatic settle_for_check ();
      mac_step(0.0, 0.0);
      mac_step(0.0, 0.0);
  endtask

  initial begin
    $display("=== tb_mac_pe_piped: START (Q4.4 mul + Q16.16 acc, +1 cycle MAC pipeline) ===");
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

    // Test 6 (new): a_out/b_out forwarding still 1-cycle (systolic feed
    // must not change just because the MAC pipeline got deeper).
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

    $display("");
    $display("  Summary: %0d PASS, %0d FAIL", total_pass, total_fail);
    if (total_fail == 0)
        $display("=== tb_mac_pe_piped: ALL TESTS PASS ===");
    else
        $display("=== tb_mac_pe_piped: FAIL (%0d mismatch) ===", total_fail);

    $finish;
  end

  initial begin
    #2000;
    $display("TIMEOUT - tb_mac_pe_piped did not finish");
    $finish;
  end

endmodule
