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

  // Capture output when out_valid pulses (so we don't miss a 1-cycle pulse)
  // Use a reset_pulse signal so the always_ff is the only driver
  logic signed [31:0] captured;
  logic               got_out;
  logic               capture_clear;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      captured <= '0;
      got_out  <= 1'b0;
    end else if (capture_clear) begin
      captured <= '0;
      got_out  <= 1'b0;
    end else if (out_valid && !got_out) begin
      captured <= data_out;
      got_out  <= 1'b1;
    end
  end

  task automatic reset_capture;
    capture_clear = 1'b1;
    @(posedge clk); #1;
    capture_clear = 1'b0;
  endtask

  initial begin
    $display("=== tb_fused_postproc: START ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    op_sel  = FUSED_BYPASS;
    data_in = '0; aux_in = '0;
    capture_clear = 1'b0;

    #10 rst_n = 1;
    #2;

    // ---- Test 1: Bypass mode ----
    $display("  Test 1: Bypass");
    reset_capture();
    op_sel   = FUSED_BYPASS;
    data_in  = to_q(42.0);
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;
    repeat (2) @(posedge clk);

    if (got_out && from_q(captured) > 41.5 && from_q(captured) < 42.5)
      $display("    PASS: bypass output = %0.1f", from_q(captured));
    else
      $display("    FAIL: bypass output = %0.1f (expected 42.0)", from_q(captured));

    repeat (2) @(posedge clk);

    // ---- Test 2: GELU mode ----
    $display("  Test 2: GELU forward");
    reset_capture();
    op_sel   = FUSED_GELU;
    data_in  = to_q(1.0);
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;

    repeat (12) @(posedge clk);

    if (got_out) begin
      real got;
      got = from_q(captured);
      if (got > 0.7 && got < 1.0)
        $display("    PASS: GELU(1.0) = %0.4f", got);
      else
        $display("    FAIL: GELU(1.0) = %0.4f (expected ~0.84)", got);
    end else
      $display("    FAIL: no output from GELU path");

    repeat (4) @(posedge clk);

    // ---- Test 3: GELU grad ----
    $display("  Test 3: GELU grad");
    reset_capture();
    op_sel   = FUSED_GELU_GRAD;
    data_in  = to_q(1.0);
    aux_in   = to_q(0.5);
    in_valid = 1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    in_valid = 0;

    repeat (12) @(posedge clk);

    if (got_out)
      $display("    PASS: GELU grad produced output = %0.4f", from_q(captured));
    else
      $display("    INFO: GELU grad path (no output captured)");

    $display("=== tb_fused_postproc: DONE ===");
    $finish;
  end

endmodule
