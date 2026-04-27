// tb_softmax_unit.sv — Unit TB for Q16.16 softmax
`timescale 1ns/1ps

module tb_softmax_unit;
  import accel_pkg::*;

  localparam int VEC = 4;

  logic                clk, rst_n, en, start;
  logic signed [31:0]  scores_in [VEC];
  logic                in_valid;
  logic signed [31:0]  probs_out [VEC];
  logic                out_valid;

  softmax_unit #(.DATA_WIDTH(32), .VEC_LEN(VEC)) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // Latched results — captured when out_valid pulses
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
    $display("=== tb_softmax_unit: START ===");
    clk = 0; rst_n = 0; en = 1; start = 0; in_valid = 0;
    for (int i = 0; i < VEC; i++)
      scores_in[i] = '0;

    #10 rst_n = 1;
    #2;

    // Test: scores = [1.0, 2.0, 3.0, 4.0]
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

    repeat (20) @(posedge clk);

    if (got_output) begin
      real sum, p0, p1, p2, p3;
      p0 = from_q(captured[0]);
      p1 = from_q(captured[1]);
      p2 = from_q(captured[2]);
      p3 = from_q(captured[3]);
      sum = p0 + p1 + p2 + p3;

      $display("  probs = [%0.4f, %0.4f, %0.4f, %0.4f]", p0, p1, p2, p3);
      $display("  sum   = %0.4f (expect ~1.0)", sum);

      if (sum > 0.9 && sum < 1.1)
        $display("  PASS: probabilities sum to ~1.0");
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
