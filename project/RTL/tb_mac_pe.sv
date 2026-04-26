// tb_mac_pe.sv — Unit TB for Q16.16 MAC processing element
`timescale 1ns/1ps

module tb_mac_pe;
  import accel_pkg::*;

  logic                clk, rst_n, en, clear_acc;
  logic signed [31:0]  a_in, a_out, b_in, b_out, acc_out;

  mac_pe #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  // Convert real to Q16.16
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  // Convert Q16.16 back to real for display
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  initial begin
    $display("=== tb_mac_pe: START ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    a_in = '0; b_in = '0;

    #10 rst_n = 1;
    #2;

    // Test 1: Clear accumulator
    en = 1; clear_acc = 1;
    a_in = to_q(2.0);
    b_in = to_q(3.0);
    @(posedge clk); #1;
    clear_acc = 0;

    // Test 2: Accumulate 2.0 * 3.0 = 6.0
    a_in = to_q(2.0);
    b_in = to_q(3.0);
    @(posedge clk); #1;

    // Test 3: Accumulate another 1.0 * 4.0 = 4.0, total = 10.0
    a_in = to_q(1.0);
    b_in = to_q(4.0);
    @(posedge clk); #1;

    // Zero inputs to stop accumulation, then wait
    a_in = '0;
    b_in = '0;
    @(posedge clk); #1;

    // Check accumulator
    $display("  acc_out = %f (expect ~10.0)", from_q(acc_out));
    if (from_q(acc_out) > 9.0 && from_q(acc_out) < 11.0)
      $display("  PASS: MAC accumulation correct");
    else
      $display("  FAIL: MAC accumulation incorrect");

    $display("  a_out = %f (expect 0.0, forwarded zero)", from_q(a_out));
    $display("  b_out = %f (expect 0.0, forwarded zero)", from_q(b_out));

    // Test 5: Clear and verify
    a_in = '0;
    b_in = '0;
    clear_acc = 1;
    @(posedge clk); #1;
    clear_acc = 0;
    en = 0;
    @(posedge clk); #1;
    $display("  acc after clear = %f (expect 0.0)", from_q(acc_out));

    $display("=== tb_mac_pe: DONE ===");
    $finish;
  end

endmodule
