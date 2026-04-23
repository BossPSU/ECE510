// tb_softmax_unit.sv — Unit TB for softmax block
// Directed test: drive tiny vector, check normalization
`timescale 1ns/1ps

module tb_softmax_unit;
  import accel_pkg::*;

  localparam int VEC = 4; // tiny vector for test (not full 64)

  logic        clk, rst_n, en, start;
  logic [31:0] scores_in [VEC];
  logic        in_valid;
  logic [31:0] probs_out [VEC];
  logic        out_valid;

  softmax_unit #(.DATA_WIDTH(32), .VEC_LEN(VEC)) dut (.*);

  always #1 clk = ~clk;

  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
  endfunction

  initial begin
    $display("=== tb_softmax_unit: START ===");
    clk = 0; rst_n = 0; en = 1; start = 0; in_valid = 0;
    for (int i = 0; i < VEC; i++) scores_in[i] = '0;

    #10 rst_n = 1;
    #2;

    // Test: scores = [1.0, 2.0, 3.0, 4.0]
    scores_in[0] = $shortrealtobits(shortreal'(1.0));
    scores_in[1] = $shortrealtobits(shortreal'(2.0));
    scores_in[2] = $shortrealtobits(shortreal'(3.0));
    scores_in[3] = $shortrealtobits(shortreal'(4.0));
    in_valid = 1;
    start    = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;  // hold valid for 2 cycles to ensure latch
    in_valid = 0;
    start    = 0;

    // Wait for pipeline (4 stages + margin)
    repeat (20) @(posedge clk);

    // Check output
    if (out_valid) begin
      shortreal sum, p0, p1, p2, p3;
      p0 = fp32(probs_out[0]);
      p1 = fp32(probs_out[1]);
      p2 = fp32(probs_out[2]);
      p3 = fp32(probs_out[3]);
      sum = p0 + p1 + p2 + p3;

      $display("  probs = [%0.4f, %0.4f, %0.4f, %0.4f]", p0, p1, p2, p3);
      $display("  sum   = %0.4f (expect ~1.0)", sum);

      // Golden: softmax([1,2,3,4]) ≈ [0.0321, 0.0871, 0.2369, 0.6439]
      if (sum > 0.99 && sum < 1.01)
        $display("  PASS: probabilities sum to 1.0");
      else
        $display("  FAIL: probabilities do not sum to 1.0");

      if (p3 > p2 && p2 > p1 && p1 > p0)
        $display("  PASS: monotonically increasing as expected");
      else
        $display("  FAIL: ordering incorrect");
    end else begin
      $display("  FAIL: out_valid never asserted");
    end

    $display("=== tb_softmax_unit: DONE ===");
    $finish;
  end

endmodule
