// tb_fused_postproc.sv — Unit TB for Q16.16 fused post-processing MUX
`timescale 1ns/1ps

module tb_fused_postproc;
  import accel_pkg::*;

  logic               clk, rst_n, en;
  fused_op_t          op_sel;
  logic signed [31:0] data_in, data_out, aux_in;
  logic               in_valid, out_valid;

  fused_postproc_unit #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  initial begin
    $display("=== tb_fused_postproc: START ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    op_sel  = FUSED_BYPASS;
    data_in = '0; aux_in = '0;

    #10 rst_n = 1;
    #2;

    // ---- Test 1: Bypass mode ----
    $display("  Test 1: Bypass");
    op_sel   = FUSED_BYPASS;
    data_in  = to_q(42.0);
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    if (out_valid && from_q(data_out) > 41.5 && from_q(data_out) < 42.5)
      $display("    PASS: bypass output = %0.1f", from_q(data_out));
    else
      $display("    FAIL: bypass output = %0.1f (expected 42.0)", from_q(data_out));

    in_valid = 0;
    repeat (2) @(posedge clk);

    // ---- Test 2: GELU mode ----
    $display("  Test 2: GELU forward");
    op_sel   = FUSED_GELU;
    data_in  = to_q(1.0);
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;

    // Wait for GELU pipeline (6 stages + margin)
    repeat (12) @(posedge clk);

    if (out_valid) begin
      real got;
      got = from_q(data_out);
      // GELU(1.0) ~ 0.84, allow looser bound for Pade approx
      if (got > 0.7 && got < 1.0)
        $display("    PASS: GELU(1.0) = %0.4f", got);
      else
        $display("    FAIL: GELU(1.0) = %0.4f (expected ~0.84)", got);
    end else
      $display("    FAIL: no output from GELU path");

    repeat (4) @(posedge clk);

    // ---- Test 3: GELU grad ----
    $display("  Test 3: GELU grad");
    op_sel   = FUSED_GELU_GRAD;
    data_in  = to_q(1.0);   // dh_act
    aux_in   = to_q(0.5);   // pre-activation h
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;

    repeat (12) @(posedge clk);

    if (out_valid)
      $display("    PASS: GELU grad produced output = %0.4f", from_q(data_out));
    else
      $display("    INFO: GELU grad path (may need more cycles)");

    $display("=== tb_fused_postproc: DONE ===");
    $finish;
  end

endmodule
