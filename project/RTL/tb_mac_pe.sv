// tb_mac_pe.sv — Unit TB for single MAC processing element
// Directed test: feed known values, check accumulation
`timescale 1ns/1ps

module tb_mac_pe;
  import accel_pkg::*;

  logic        clk, rst_n, en, clear_acc;
  logic [31:0] a_in, a_out, b_in, b_out, acc_out;

  mac_pe #(.DATA_WIDTH(32)) dut (.*);

  // Clock: 500 MHz = 2ns period
  always #1 clk = ~clk;

  // Golden model: simple FP32 MAC
  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
  endfunction

  initial begin
    $display("=== tb_mac_pe: START ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    a_in = '0; b_in = '0;

    // Reset
    #10 rst_n = 1;
    #2;

    // Test 1: Clear accumulator
    en = 1; clear_acc = 1;
    a_in = $shortrealtobits(shortreal'(2.0));
    b_in = $shortrealtobits(shortreal'(3.0));
    @(posedge clk); #1;
    clear_acc = 0;

    // Test 2: Accumulate 2.0 * 3.0 = 6.0
    a_in = $shortrealtobits(shortreal'(2.0));
    b_in = $shortrealtobits(shortreal'(3.0));
    @(posedge clk); #1;

    // Test 3: Accumulate another 1.0 * 4.0 = 4.0, total = 10.0
    a_in = $shortrealtobits(shortreal'(1.0));
    b_in = $shortrealtobits(shortreal'(4.0));
    @(posedge clk); #1;

    // Wait for pipeline
    @(posedge clk); #1;

    // Check accumulator
    $display("  acc_out = %f (expect ~10.0)", fp32(acc_out));
    if (fp32(acc_out) > 9.0 && fp32(acc_out) < 11.0)
      $display("  PASS: MAC accumulation correct");
    else
      $display("  FAIL: MAC accumulation incorrect");

    // Test 4: Check forwarding — a_out should be delayed a_in
    $display("  a_out = %f (expect 1.0)", fp32(a_out));
    $display("  b_out = %f (expect 4.0)", fp32(b_out));

    // Test 5: Clear and verify
    clear_acc = 1;
    @(posedge clk); #1;
    clear_acc = 0;
    @(posedge clk); #1;
    $display("  acc after clear = %f (expect 0.0)", fp32(acc_out));

    $display("=== tb_mac_pe: DONE ===");
    $finish;
  end

endmodule
