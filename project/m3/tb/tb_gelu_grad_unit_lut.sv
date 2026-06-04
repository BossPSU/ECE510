// =============================================================================
// tb_gelu_grad_unit_lut.sv -- unit test for M6 Tier 2B in GELU' path
// =============================================================================
//
// Drives gelu_grad_unit_lut standalone with a sweep of x values spanning
// the LUT range and verifies:
//
//   1. grad_out = GELU'(x_in) within LUT+interp tolerance
//   2. Latency = 4 cycles (was 3 in M4; Tier 2B added s3a register)
//   3. Saturation tails:
//        x > +4 -> grad_out ~= 1.0
//        x < -4 -> grad_out ~= 0.0
//   4. Sign handling correct on both halves of the curve (the ff_backward
//      e2e cosim's scenario C tests this end-to-end; this TB pinpoints
//      to the leaf)
//
// This is the HIGHEST RISK leaf in the M6 changeset because
// fused_postproc_unit pairs its output with a data_delay'd dh from the
// systolic array via q_mul. Any timing or sign error here propagates
// directly into ff_backward's dh1 output.
//
// Final summary line: "=== TB_GELU_GRAD_LUT: PASS ===" or "FAIL ...".
// =============================================================================
`timescale 1ns/1ps

module tb_gelu_grad_unit_lut;
  import accel_pkg::*;

  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;

  logic               en;
  logic signed [31:0] x_in, grad_out;
  logic               in_valid, out_valid;

  gelu_grad_unit_lut #(.DATA_WIDTH(32)) duv (
    .clk(clk), .rst_n(rst_n), .en(en),
    .x_in(x_in), .in_valid(in_valid),
    .grad_out(grad_out), .out_valid(out_valid)
  );

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction
  function automatic real ref_gelu_prime(input real x);
    real t, u, du_dx;
    u     = 0.7978845608 * (x + 0.044715 * x * x * x);
    t     = $tanh(u);
    du_dx = 0.7978845608 * (1.0 + 3.0 * 0.044715 * x * x);
    return 0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * du_dx;
  endfunction

  localparam int LATENCY = 4;
  localparam real TOL    = 0.02;  // GELU' interpolation a bit looser than GELU

  int test_failures = 0;

  task automatic check_at(input real x_val, input real expected_override,
                          input bit  use_override, input string label);
    real expected, got;
    bit  saw_valid;

    x_in     <= to_q(x_val);
    in_valid <= 1'b1;
    @(posedge clk);
    in_valid <= 1'b0;
    x_in     <= '0;
    repeat (LATENCY - 1) @(posedge clk);
    saw_valid = out_valid;
    got       = from_q($signed(grad_out));
    @(posedge clk);

    expected = use_override ? expected_override : ref_gelu_prime(x_val);

    if (!saw_valid) begin
      $display("  FAIL: %s out_valid not asserted at latency %0d",
               label, LATENCY);
      test_failures++;
    end else if ((got - expected) > TOL || (got - expected) < -TOL) begin
      $display("  FAIL: %s G'(%0.4f) = %0.4f (expected %0.4f, err %0.5f)",
               label, x_val, got, expected, got - expected);
      test_failures++;
    end else
      $display("  PASS: %s G'(%0.4f) = %0.4f (expected %0.4f)",
               label, x_val, got, expected);
    repeat (4) @(posedge clk);
  endtask

  initial begin
    $display("=== tb_gelu_grad_unit_lut: START ===");
    en       = 1;
    x_in     = '0;
    in_valid = 0;
    #20 rst_n = 1;
    #4;

    // Saturation tails (override paths)
    check_at(-10.0, 0.0, 1'b1, "T1: deep negative -> 0");
    check_at( -4.5, 0.0, 1'b1, "T2: just-below -4 -> 0");
    check_at(  5.0, 1.0, 1'b1, "T3: deep positive -> 1");

    // LUT-active region (no override)
    check_at(-4.0, 0.0, 1'b0, "T4: LUT boundary -4");
    check_at(-2.0, 0.0, 1'b0, "T5: G'(-2.0)");
    check_at(-1.0, 0.0, 1'b0, "T6: G'(-1.0) -- sign-handling key test");
    check_at(-0.5, 0.0, 1'b0, "T7: G'(-0.5)");
    check_at( 0.0, 0.0, 1'b0, "T8: G'(0.0)=0.5 -- inflection point");
    check_at( 0.5, 0.0, 1'b0, "T9: G'(0.5)");
    check_at( 1.0, 0.0, 1'b0, "T10: G'(1.0)");
    check_at( 2.0, 0.0, 1'b0, "T11: G'(2.0)");
    check_at( 3.9375, 0.0, 1'b0, "T12: near positive boundary");

    $display("");
    if (test_failures == 0)
      $display("=== TB_GELU_GRAD_LUT: PASS ===");
    else
      $display("=== TB_GELU_GRAD_LUT: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  initial begin
    #100000;
    $display("WATCHDOG: simulation timed out");
    $display("=== TB_GELU_GRAD_LUT: FAIL (timeout) ===");
    $finish;
  end

endmodule
