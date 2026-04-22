// tb_gelu_unit.sv — Unit TB for forward GELU activation
// Directed test: drive known x values, check against golden GELU
`timescale 1ns/1ps

module tb_gelu_unit;
  import accel_pkg::*;

  logic        clk, rst_n, en;
  logic [31:0] x_in, y_out;
  logic        in_valid, out_valid;

  gelu_unit #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  // Golden GELU: 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715*x^3)))
  function automatic shortreal golden_gelu(shortreal x);
    shortreal tanh_arg, t;
    tanh_arg = 0.7978845608 * (x + 0.044715 * x * x * x);
    t = $tanh(tanh_arg);
    return 0.5 * x * (1.0 + t);
  endfunction

  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
  endfunction

  // Test values
  shortreal test_inputs [8] = '{-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0};
  int pass_cnt, fail_cnt;

  initial begin
    $display("=== tb_gelu_unit: START ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    x_in = '0;
    pass_cnt = 0; fail_cnt = 0;

    #10 rst_n = 1;
    #2;

    // Drive test inputs one per cycle
    for (int i = 0; i < 8; i++) begin
      x_in     = $shortrealtobits(test_inputs[i]);
      in_valid = 1'b1;
      @(posedge clk); #1;
    end
    in_valid = 0;

    // Wait for pipeline to drain (5 stages + margin)
    repeat (10) @(posedge clk);

    $display("=== tb_gelu_unit: DONE ===");
    $finish;
  end

  // Monitor outputs
  int out_idx = 0;
  always @(posedge clk) begin
    if (out_valid && out_idx < 8) begin
      shortreal got, expected;
      real err;
      got      = fp32(y_out);
      expected = golden_gelu(test_inputs[out_idx]);
      err      = (got - expected);
      if (err < 0) err = -err;

      if (err < 0.05) begin
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
