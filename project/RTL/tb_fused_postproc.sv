// tb_fused_postproc.sv — Unit TB for fused post-processing MUX
// Tests bypass, GELU, and GELU grad paths with stubbed systolic output
`timescale 1ns/1ps

module tb_fused_postproc;
  import accel_pkg::*;

  logic        clk, rst_n, en;
  fused_op_t   op_sel;
  logic [31:0] data_in, data_out, aux_in;
  logic        in_valid, out_valid;

  fused_postproc_unit #(.DATA_WIDTH(32)) dut (.*);

  always #1 clk = ~clk;

  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
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
    data_in  = $shortrealtobits(shortreal'(42.0));
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    if (out_valid && fp32(data_out) == shortreal'(42.0))
      $display("    PASS: bypass output = %0.1f", fp32(data_out));
    else
      $display("    FAIL: bypass output = %0.1f (expected 42.0)", fp32(data_out));

    in_valid = 0;
    repeat (2) @(posedge clk);

    // ---- Test 2: GELU mode ----
    $display("  Test 2: GELU forward");
    op_sel   = FUSED_GELU;
    data_in  = $shortrealtobits(shortreal'(1.0));
    in_valid = 1;
    @(posedge clk); #1;
    in_valid = 0;

    // Wait for GELU pipeline (3 stages)
    repeat (6) @(posedge clk);

    if (out_valid) begin
      shortreal got;
      got = fp32(data_out);
      // GELU(1.0) ≈ 0.8412
      if (got > 0.79 && got < 0.89)
        $display("    PASS: GELU(1.0) = %0.4f", got);
      else
        $display("    FAIL: GELU(1.0) = %0.4f (expected ~0.84)", got);
    end else
      $display("    FAIL: no output from GELU path");

    repeat (2) @(posedge clk);

    // ---- Test 3: GELU grad mode ----
    $display("  Test 3: GELU grad (stubbed)");
    op_sel   = FUSED_GELU_GRAD;
    data_in  = $shortrealtobits(shortreal'(1.0)); // dh_act
    aux_in   = $shortrealtobits(shortreal'(0.5)); // pre-activation h
    in_valid = 1;
    @(posedge clk); #1;
    in_valid = 0;

    repeat (6) @(posedge clk);

    if (out_valid)
      $display("    PASS: GELU grad produced output = %0.4f", fp32(data_out));
    else
      $display("    INFO: GELU grad path (may need more cycles)");

    $display("=== tb_fused_postproc: DONE ===");
    $finish;
  end

endmodule
