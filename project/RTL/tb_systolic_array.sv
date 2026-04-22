// tb_systolic_array.sv — Unit TB for systolic array (Option 3)
// Load one tiny tile, check matrix multiply result
// Uses a small 4x4 subarray to keep simulation fast
`timescale 1ns/1ps

module tb_systolic_array;
  import accel_pkg::*;

  localparam int N = 4; // tiny 4x4 for test

  logic        clk, rst_n, en, clear_acc;
  logic [31:0] a_in  [N];
  logic [31:0] b_in  [N];
  logic [31:0] c_out [N][N];

  systolic_array_64x64 #(
    .ROWS       (N),
    .COLS       (N),
    .DATA_WIDTH (32)
  ) dut (.*);

  always #1 clk = ~clk;

  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
  endfunction

  // Test matrices (4x4)
  // A = [[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]]
  // B = identity (for easy checking: C should equal A)
  shortreal A [N][N];
  shortreal B [N][N];
  shortreal C_expected [N][N];

  initial begin
    $display("=== tb_systolic_array: START ===");
    clk = 0; rst_n = 0; en = 0; clear_acc = 0;
    for (int i = 0; i < N; i++) begin
      a_in[i] = '0;
      b_in[i] = '0;
    end

    // Initialize test data
    // A: sequential values 1..16
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        A[i][j] = shortreal'(i * N + j + 1);

    // B: identity matrix
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++)
        B[i][j] = (i == j) ? 1.0 : 0.0;

    // Golden: C = A * I = A
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        C_expected[i][j] = 0.0;
        for (int k = 0; k < N; k++)
          C_expected[i][j] += A[i][k] * B[k][j];
      end

    // Reset
    #10 rst_n = 1;
    #2;

    // Clear accumulators
    en = 1; clear_acc = 1;
    @(posedge clk); #1;
    clear_acc = 0;

    // Feed data: systolic flow
    // Each cycle, feed one column of A as row inputs and one row of B as col inputs
    // In a real systolic array, data is staggered — simplified here
    for (int k = 0; k < N; k++) begin
      for (int i = 0; i < N; i++) begin
        a_in[i] = $shortrealtobits(A[i][k]);
        b_in[i] = $shortrealtobits(B[k][i]);
      end
      @(posedge clk); #1;
    end

    // Let pipeline drain
    for (int i = 0; i < N; i++) begin
      a_in[i] = '0;
      b_in[i] = '0;
    end
    repeat (N + 4) @(posedge clk);

    // Check results
    en = 0;
    int pass_cnt = 0;
    int fail_cnt = 0;

    $display("  Result C (expect C = A * I = A):");
    for (int i = 0; i < N; i++) begin
      string row_str;
      row_str = $sformatf("  Row %0d: [", i);
      for (int j = 0; j < N; j++) begin
        shortreal got, expected;
        real err;
        got      = fp32(c_out[i][j]);
        expected = C_expected[i][j];
        err      = got - expected;
        if (err < 0) err = -err;

        row_str = {row_str, $sformatf("%6.1f", got)};
        if (j < N-1) row_str = {row_str, ","};

        if (err < 0.1) pass_cnt++;
        else           fail_cnt++;
      end
      $display("%s]", row_str);
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
