// tb_systolic_array.sv — Unit TB for Q16.16 systolic array (4x4 subarray)
// Tests C = A * I = A using skewed input feeding
`timescale 1ns/1ps

module tb_systolic_array;
  import accel_pkg::*;

  localparam int N = 4;

  logic                clk, rst_n, en, clear_acc;
  logic signed [31:0]  a_in  [N];
  logic signed [31:0]  b_in  [N];
  logic signed [31:0]  c_out [N][N];

  systolic_array_64x64 #(
    .ROWS       (N),
    .COLS       (N),
    .DATA_WIDTH (32)
  ) dut (.*);

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // Test matrices (in real domain, then convert to Q16.16 when feeding)
  real A_mat [N][N];
  real B_mat [N][N];
  real C_expected [N][N];

  initial begin
    int pass_cnt, fail_cnt;
    $display("=== tb_systolic_array: START ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    pass_cnt = 0; fail_cnt = 0;

    for (int i = 0; i < N; i++) begin
      a_in[i] = '0;
      b_in[i] = '0;
    end

    // A = sequential 1..16
    // B = identity
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        A_mat[i][j] = real'(i * N + j + 1);
        B_mat[i][j] = (i == j) ? 1.0 : 0.0;
      end

    // Golden: C = A * I = A
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        C_expected[i][j] = 0.0;
        for (int k = 0; k < N; k++)
          C_expected[i][j] = C_expected[i][j] + A_mat[i][k] * B_mat[k][j];
      end

    // Reset
    #10 rst_n = 1;
    #2;

    // Clear accumulators
    en = 1; clear_acc = 1;
    @(posedge clk); #1;
    clear_acc = 0;

    // Skewed feeding for systolic dataflow
    for (int cyc = 0; cyc < 2*N - 1; cyc++) begin
      for (int i = 0; i < N; i++) begin
        int k_a;
        k_a = cyc - i;
        if (k_a >= 0 && k_a < N)
          a_in[i] = to_q(A_mat[i][k_a]);
        else
          a_in[i] = '0;
      end
      for (int j = 0; j < N; j++) begin
        int k_b;
        k_b = cyc - j;
        if (k_b >= 0 && k_b < N)
          b_in[j] = to_q(B_mat[k_b][j]);
        else
          b_in[j] = '0;
      end
      @(posedge clk); #1;
    end

    // Zero inputs and let pipeline settle
    for (int i = 0; i < N; i++) begin
      a_in[i] = '0;
      b_in[i] = '0;
    end
    repeat (N + 2) @(posedge clk);

    // Check results
    en = 0;
    $display("  Result C (expect C = A * I = A):");
    for (int i = 0; i < N; i++) begin
      $display("  Row %0d: [%6.1f, %6.1f, %6.1f, %6.1f]  expect [%6.1f, %6.1f, %6.1f, %6.1f]",
               i,
               from_q(c_out[i][0]), from_q(c_out[i][1]),
               from_q(c_out[i][2]), from_q(c_out[i][3]),
               C_expected[i][0], C_expected[i][1],
               C_expected[i][2], C_expected[i][3]);
      for (int j = 0; j < N; j++) begin
        real err;
        err = from_q(c_out[i][j]) - C_expected[i][j];
        if (err < 0) err = -err;
        if (err < 0.1) pass_cnt++;
        else           fail_cnt++;
      end
    end

    $display("  Results: %0d PASS, %0d FAIL (of %0d elements)",
             pass_cnt, fail_cnt, N*N);

    if (fail_cnt == 0)
      $display("  OVERALL: PASS");
    else
      $display("  OVERALL: FAIL");

    $display("=== tb_systolic_array: DONE ===");
    $finish;
  end

endmodule
