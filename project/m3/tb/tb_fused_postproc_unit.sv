// =============================================================================
// tb_fused_postproc_unit.sv -- unit test for M6 Tier 2A (output register)
// =============================================================================
//
// Drives fused_postproc_unit standalone and verifies:
//
//   1. BYPASS mode: data_out = data_in delayed by 1 cycle (the M6 Tier 2A
//      output register)
//   2. MASK mode:   same as BYPASS at this leaf (causal_mask is upstream)
//   3. GELU mode:   data_out = GELU(data_in) after gelu_unit_lut latency
//      + 1 cycle output reg = 5 cycles total
//   4. GELU_GRAD mode: data_out = data_in * GELU'(aux_in) after
//      gelu_grad_unit_lut latency + 1 cycle output reg + the data_delay
//      alignment that pairs data_in with the LUT result
//
// What this catches:
//   - M6 Tier 2A output register added the right +1 cycle (FUSED_DEPTH = 9)
//   - data_delay alignment between data_in and aux_in still works for
//     GELU_GRAD after M6 Tier 2B added +1 to gelu_grad_unit_lut latency
//   - in_valid -> out_valid handshake matches the new latency
//
// Final summary line: "=== TB_FUSED_PP: PASS ===" or "FAIL ...".
// =============================================================================
`timescale 1ns/1ps

module tb_fused_postproc_unit;
  import accel_pkg::*;

  // ----- Clock + reset -----
  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;

  // ----- DUV ports -----
  logic               en;
  fused_op_t          op_sel;
  logic signed [31:0] data_in, aux_in, data_out;
  logic               in_valid, out_valid;

  fused_postproc_unit #(
    .DATA_WIDTH   (32),
    .USE_LUT_GELU (1)
  ) duv (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (en),
    .op_sel    (op_sel),
    .data_in   (data_in),
    .in_valid  (in_valid),
    .aux_in    (aux_in),
    .data_out  (data_out),
    .out_valid (out_valid)
  );

  // ----- Helpers -----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  function automatic real ref_gelu(input real x);
    real t;
    t = $tanh(0.7978845608 * (x + 0.044715 * x * x * x));
    return 0.5 * x * (1.0 + t);
  endfunction
  function automatic real ref_gelu_prime(input real x);
    real t, u, du_dx;
    u     = 0.7978845608 * (x + 0.044715 * x * x * x);
    t     = $tanh(u);
    du_dx = 0.7978845608 * (1.0 + 3.0 * 0.044715 * x * x);
    return 0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * du_dx;
  endfunction

  // ----- Drive one sample, capture output after latency -----
  // Returns the value seen at `data_out` `latency` cycles after in_valid
  // pulse, and asserts out_valid is high at that cycle.
  task automatic drive_and_capture(input fused_op_t op,
                                   input real in_val,
                                   input real aux_val,
                                   input int  latency,
                                   output real   got,
                                   output bit    saw_valid);
    op_sel    <= op;
    data_in   <= to_q(in_val);
    aux_in    <= to_q(aux_val);
    in_valid  <= 1'b1;
    @(posedge clk);
    in_valid  <= 1'b0;
    data_in   <= '0;
    aux_in    <= '0;
    repeat (latency - 1) @(posedge clk);
    // Sample on negedge so the DUT's NBA updates from the target posedge
    // have settled. Sampling immediately after @(posedge clk) reads the
    // PREVIOUS-cycle out_valid because NBAs scheduled by always_ff in
    // that same active region haven't fired yet.
    @(negedge clk);
    saw_valid = out_valid;
    got       = from_q($signed(data_out));
    @(posedge clk);
  endtask

  // ----- Tracking -----
  int test_failures = 0;
  localparam real TOL = 0.05;

  task automatic check_real(input string label,
                            input real got, input real expected,
                            input bit  saw_valid);
    if (!saw_valid) begin
      $display("  FAIL: %s -- out_valid not asserted", label);
      test_failures++;
    end else if ((got - expected) > TOL || (got - expected) < -TOL) begin
      $display("  FAIL: %s -- got %0.4f vs expected %0.4f (tol %0.2f)",
               label, got, expected, TOL);
      test_failures++;
    end else
      $display("  PASS: %s -- got %0.4f matches %0.4f (within tol)",
               label, got, expected);
  endtask

  // ----- Main -----
  initial begin
    real got;
    bit  saw_valid;

    $display("=== tb_fused_postproc_unit: START ===");
    en       = 1;
    op_sel   = FUSED_BYPASS;
    data_in  = '0;
    aux_in   = '0;
    in_valid = 0;
    #20 rst_n = 1;
    #4;

    // ----- Test 1: BYPASS, 1-cycle latency (Tier 2A output reg) -----
    drive_and_capture(FUSED_BYPASS, 1.5, 0.0, 1, got, saw_valid);
    check_real("T1: BYPASS, 1-cycle latency", got, 1.5, saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 2: MASK, 1-cycle latency (mask is upstream; here pass-through) -----
    drive_and_capture(FUSED_MASK, -2.25, 0.0, 1, got, saw_valid);
    check_real("T2: MASK pass-through, 1-cycle latency", got, -2.25, saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 3: GELU at +1.0 -- gelu_unit_lut latency 4 + output reg 1 = 5
    drive_and_capture(FUSED_GELU, 1.0, 0.0, 5, got, saw_valid);
    check_real("T3: GELU(1.0) latency=5", got, ref_gelu(1.0), saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 4: GELU at -1.0 -----
    drive_and_capture(FUSED_GELU, -1.0, 0.0, 5, got, saw_valid);
    check_real("T4: GELU(-1.0) latency=5", got, ref_gelu(-1.0), saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 5: GELU_GRAD -----
    // Output = data_in * GELU'(aux_in). data_in=1.0, aux_in=1.0 ->
    // expected = 1.0 * GELU'(1.0) ~= 1.0828.
    // Latency (USE_LUT_GELU=1): gelu_grad_unit_lut = 4 cycles + output
    // reg = 5 cycles. data_delay is now sized to match (GRAD_DELAY=4),
    // so data_in and grad_out arrive at the q_mul on the same posedge
    // gelu_grad_valid pulses.
    drive_and_capture(FUSED_GELU_GRAD, 1.0, 1.0, 5, got, saw_valid);
    check_real("T5: GELU_GRAD(1.0 * G'(1.0)) latency=5",
               got, 1.0 * ref_gelu_prime(1.0), saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 6: GELU_GRAD with non-trivial dh and h -----
    drive_and_capture(FUSED_GELU_GRAD, 2.0, 0.5, 5, got, saw_valid);
    check_real("T6: GELU_GRAD(2.0 * G'(0.5))",
               got, 2.0 * ref_gelu_prime(0.5), saw_valid);

    repeat (10) @(posedge clk);

    // ----- Test 7: GELU_GRAD negative h_pre (sign alignment test) -----
    // This is the path most exposed to Tier 2B + data_delay alignment.
    drive_and_capture(FUSED_GELU_GRAD, 1.0, -1.0, 5, got, saw_valid);
    check_real("T7: GELU_GRAD(1.0 * G'(-1.0)) sign test",
               got, 1.0 * ref_gelu_prime(-1.0), saw_valid);

    // ----- Summary -----
    $display("");
    if (test_failures == 0)
      $display("=== TB_FUSED_PP: PASS ===");
    else
      $display("=== TB_FUSED_PP: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  // Watchdog
  initial begin
    #100000;
    $display("WATCHDOG: simulation timed out at 100us");
    $display("=== TB_FUSED_PP: FAIL (timeout) ===");
    $finish;
  end

endmodule
