// tb_gelu_grad_unit_lut.sv — Unit TB for LUT+linear-interp Q16.16 GELU'
//
// Verifies the 256-entry direct GELU'(x) LUT + adjacent-entry linear
// interpolation against a true-erf reference. Tolerance 1e-3 absolute.
`timescale 1ns/1ps

module tb_gelu_grad_unit_lut;
  import accel_pkg::*;

  logic               clk, rst_n, en;
  logic signed [31:0] x_in, grad_out;
  logic               in_valid, out_valid;

  gelu_grad_unit_lut #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // True GELU' = Phi(x) + x * phi(x), with Phi via Abramowitz-Stegun erf.
  function automatic real true_gelu_grad(input real x);
    real a, sign_x, t, erf_val, phi_cdf, phi_pdf;
    real p, a1, a2, a3, a4, a5;
    p  = 0.3275911;
    a1 = 0.254829592;
    a2 = -0.284496736;
    a3 = 1.421413741;
    a4 = -1.453152027;
    a5 = 1.061405429;
    sign_x = (x < 0) ? -1.0 : 1.0;
    a = (x < 0) ? -x : x;
    a = a / 1.4142135623730951;
    t = 1.0 / (1.0 + p * a);
    erf_val = 1.0 - (((((a5*t + a4)*t) + a3)*t + a2)*t + a1) * t
                  * $exp(-a * a);
    erf_val = sign_x * erf_val;
    phi_cdf = 0.5 * (1.0 + erf_val);
    phi_pdf = $exp(-0.5 * x * x) / 2.5066282746310002;  // sqrt(2*pi)
    return phi_cdf + x * phi_pdf;
  endfunction

  real test_inputs [10] = '{-5.0, -3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 5.0};
  int  pass_cnt, fail_cnt;
  int  out_idx;
  real worst_err;

  initial begin
    $display("=== tb_gelu_grad_unit_lut: START (256-entry LUT + linear interp) ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    x_in = '0;
    pass_cnt = 0; fail_cnt = 0; out_idx = 0;
    worst_err = 0.0;

    #10 rst_n = 1;
    #2;

    for (int i = 0; i < 10; i++) begin
      x_in     = to_q(test_inputs[i]);
      in_valid = 1'b1;
      @(posedge clk); #1;
    end
    in_valid = 0;

    repeat (12) @(posedge clk);

    $display("  Worst observed error: %0.6f (Q16.16 LSB = 0.0000153)", worst_err);
    $display("  Final results: %0d PASS, %0d FAIL (tolerance 1e-3)", pass_cnt, fail_cnt);
    $display("=== tb_gelu_grad_unit_lut: DONE ===");
    $finish;
  end

  always @(posedge clk) begin
    if (out_valid && out_idx < 10) begin
      real got, expected, err;
      got      = from_q(grad_out);
      expected = true_gelu_grad(test_inputs[out_idx]);
      err      = (got > expected) ? (got - expected) : (expected - got);
      if (err > worst_err) worst_err = err;

      if (err < 0.001) begin
        $display("  PASS: GELU'(%+0.2f) = %+0.5f  (true %+0.5f, err=%0.6f)",
                 test_inputs[out_idx], got, expected, err);
        pass_cnt++;
      end else begin
        $display("  FAIL: GELU'(%+0.2f) = %+0.5f  (true %+0.5f, err=%0.6f)",
                 test_inputs[out_idx], got, expected, err);
        fail_cnt++;
      end
      out_idx++;
    end
  end

endmodule
