// tb_gelu_unit.sv — Unit TB for Q16.16 GELU
`timescale 1ns/1ps

module tb_gelu_unit;
  import accel_pkg::*;

  logic               clk, rst_n, en;
  logic signed [31:0] x_in, y_out;
  logic               in_valid, out_valid;

  gelu_unit #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  // Q16.16 conversion helpers
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // Behavioral GELU using doubles for golden reference
  function automatic real golden_gelu(input real x);
    real tanh_arg, t;
    tanh_arg = 0.7978845608 * (x + 0.044715 * x * x * x);
    t = $tanh(tanh_arg);
    return 0.5 * x * (1.0 + t);
  endfunction

  real test_inputs [8] = '{-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0};
  int  pass_cnt, fail_cnt;
  int  out_idx;

  initial begin
    $display("=== tb_gelu_unit: START ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    x_in = '0;
    pass_cnt = 0; fail_cnt = 0; out_idx = 0;

    #10 rst_n = 1;
    #2;

    // Drive test inputs
    for (int i = 0; i < 8; i++) begin
      x_in     = to_q(test_inputs[i]);
      in_valid = 1'b1;
      @(posedge clk); #1;
    end
    in_valid = 0;

    // Wait for pipeline to drain (6 stages + margin)
    repeat (12) @(posedge clk);

    $display("  Final results: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
    $display("=== tb_gelu_unit: DONE ===");
    $finish;
  end

  // Monitor outputs
  always @(posedge clk) begin
    if (out_valid && out_idx < 8) begin
      real got, expected, err;
      got      = from_q(y_out);
      expected = golden_gelu(test_inputs[out_idx]);
      err      = (got > expected) ? (got - expected) : (expected - got);

      // Q16.16 polynomial Pade approximation has more error than $tanh
      // Looser tolerance: 0.1
      if (err < 0.1) begin
        $display("  PASS: GELU(%0.2f) = %0.4f (expected %0.4f, err=%0.4f)",
                 test_inputs[out_idx], got, expected, err);
        pass_cnt++;
      end else begin
        $display("  FAIL: GELU(%0.2f) = %0.4f (expected %0.4f, err=%0.4f)",
                 test_inputs[out_idx], got, expected, err);
        fail_cnt++;
      end
      out_idx++;
    end
  end

endmodule
