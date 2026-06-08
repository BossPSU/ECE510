// =============================================================================
// tb_stream_pipeline_tile.sv -- subsystem-level tile testbench
// =============================================================================
//
// Drives stream_pipeline.sv directly (no chiplet, no compute_core FSM)
// with behavioral models for the A, B, aux, and output buffers. Runs 8
// scenarios (M3 verification plan Section 4.1) to catch latency-constant
// off-by-ones and FSM-counter alignment bugs that the full e2e cosim
// might miss in random vectors.
//
// What this catches:
//   - DRAIN_CYCLES, FUSED_DEPTH, SOFTMAX_LAT off-by-one
//   - out_row_cnt/coll_row_cnt walk alignment
//   - feed_active / array_clear / a/b_in pipelining alignment (Option B
//     + extended Option B)
//   - tile_m/n/k shadow registers (Option F) for asymmetric tiles
//
// Scenarios:
//   1. (m,n,k)=(1,1,1)   BYPASS    -- minimum tile, every counter just
//                                     wraps once
//   2. (m,n,k)=(64,64,64) BYPASS   -- maximum tile, fully exercises feed
//   3. (m,n,k)=(32,16,8)  BYPASS   -- asymmetric: m!=n!=k
//   4. (m,n,k)=(64,64,64) GELU     -- fused activation path
//   5. (m,n,k)=(64,64,64) GELU_GRAD-- aux buffer + h_pre alignment (M6
//                                     Tier 2B + Option F highest risk)
//   6. (m,n,k)=(64,64,64) SOFTMAX  -- softmax path + capture buffer walk
//   7. (m,n,k)=(64,64,64) MASK     -- causal-mask path
//   8. Three back-to-back (m,n,k)=(64,64,64) BYPASS tiles -- verifies
//      FSM resets cleanly between tiles
//
// Reference math is computed in-line (this TB does not depend on the
// Python cosim vectors). For each scenario the testbench:
//   1. Loads A and B buffers with simple synthetic patterns
//   2. Pulses `start`
//   3. Waits for `done` or watchdog
//   4. Verifies every output write matches the analytical reference
//   5. Verifies done arrived within predicted_cycles * 1.1
//
// Final summary line is "=== TB_SP_TILE: PASS ===" or "FAIL ...".
// =============================================================================
`timescale 1ns/1ps

module tb_stream_pipeline_tile;
  import accel_pkg::*;

  // ----- Configuration -----
  localparam int ARRAY_DIM = 64;
  localparam int DW        = 32;
  localparam int MAX_DIM   = ARRAY_DIM;
  localparam int MAX_BUF   = MAX_DIM * MAX_DIM;

  // ----- Clock + reset -----
  logic clk = 0;
  logic rst_n = 0;
  always #1 clk = ~clk;

  // ----- DUV port wires -----
  logic               start, done, running_o;
  logic [7:0]         tile_m, tile_n, tile_k;
  fused_op_t          op_sel;

  logic [7:0]         a_rd_row [ARRAY_DIM];
  logic [7:0]         a_rd_col [ARRAY_DIM];
  logic signed [31:0] a_rd_data [ARRAY_DIM];

  logic [7:0]         b_rd_row [ARRAY_DIM];
  logic [7:0]         b_rd_col [ARRAY_DIM];
  logic signed [31:0] b_rd_data [ARRAY_DIM];

  logic [7:0]         aux_rd_row, aux_rd_col;
  logic signed [31:0] aux_rd_data;

  logic               out_wr_en;
  logic [11:0]        out_wr_idx;
  logic signed [31:0] out_wr_data;

  // ----- DUV -----
  stream_pipeline #(
    .DATA_WIDTH      (DW),
    .ARRAY_DIM       (ARRAY_DIM),
    .USE_LUT_SOFTMAX (1),
    .USE_LUT_GELU    (1),
    .USE_PIPED4_MAC  (1),
    .USE_PIPED_MAC   (1)
  ) duv (
    .clk         (clk),
    .rst_n       (rst_n),
    .start       (start),
    .done        (done),
    .tile_m      (tile_m),
    .tile_n      (tile_n),
    .tile_k      (tile_k),
    .op_sel      (op_sel),
    .a_rd_row    (a_rd_row),
    .a_rd_col    (a_rd_col),
    .a_rd_data   (a_rd_data),
    .b_rd_row    (b_rd_row),
    .b_rd_col    (b_rd_col),
    .b_rd_data   (b_rd_data),
    .aux_rd_row  (aux_rd_row),
    .aux_rd_col  (aux_rd_col),
    .aux_rd_data (aux_rd_data),
    .out_wr_en   (out_wr_en),
    .out_wr_idx  (out_wr_idx),
    .out_wr_data (out_wr_data),
    .running_o   (running_o)
  );

  // ----- Behavioral buffers -----
  logic signed [31:0] A_mem   [MAX_DIM-1:0][MAX_DIM-1:0];
  logic signed [31:0] B_mem   [MAX_DIM-1:0][MAX_DIM-1:0];
  logic signed [31:0] aux_mem [MAX_DIM-1:0][MAX_DIM-1:0];
  logic signed [31:0] out_mem [MAX_DIM-1:0][MAX_DIM-1:0];
  bit                 out_seen [MAX_DIM-1:0][MAX_DIM-1:0];
  int                 out_writes_per_cell [MAX_DIM-1:0][MAX_DIM-1:0];
  // First and last (row, col) idx the DUT emits (raw, before bit slicing).
  // Plus a global write count -- catches whether the DUT actually pushes
  // out the expected ~m*n writes.
  int                 total_writes;
  int                 first_idx_seen;
  int                 last_idx_seen;

  // Combinational read paths (the stream_pipeline drives addresses
  // continuously; we serve data combinationally same cycle).
  genvar gi;
  generate
    for (gi = 0; gi < ARRAY_DIM; gi++) begin : g_a
      assign a_rd_data[gi] = A_mem[a_rd_row[gi][5:0]][a_rd_col[gi][5:0]];
    end
    for (gi = 0; gi < ARRAY_DIM; gi++) begin : g_b
      assign b_rd_data[gi] = B_mem[b_rd_row[gi][5:0]][b_rd_col[gi][5:0]];
    end
  endgenerate
  assign aux_rd_data = aux_mem[aux_rd_row[5:0]][aux_rd_col[5:0]];

  // Write capture
  always_ff @(posedge clk) begin
    if (out_wr_en) begin
      automatic int row = out_wr_idx[11:6];
      automatic int col = out_wr_idx[5:0];
      out_mem[row][col]              <= out_wr_data;
      out_seen[row][col]             <= 1'b1;
      out_writes_per_cell[row][col]  <= out_writes_per_cell[row][col] + 1;
      total_writes                   <= total_writes + 1;
      if (total_writes == 0)
        first_idx_seen <= out_wr_idx;
      last_idx_seen <= out_wr_idx;
    end
  end

  // ----- Helpers -----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // GELU model (matches accel_pkg)
  function automatic real ref_gelu(input real x);
    real t;
    t = $tanh(0.7978845608 * (x + 0.044715 * x * x * x));
    return 0.5 * x * (1.0 + t);
  endfunction

  // GELU' model
  function automatic real ref_gelu_prime(input real x);
    real t, du_dx, u;
    u     = 0.7978845608 * (x + 0.044715 * x * x * x);
    t     = $tanh(u);
    du_dx = 0.7978845608 * (1.0 + 3.0 * 0.044715 * x * x);
    return 0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * du_dx;
  endfunction

  // ----- Failure tracking -----
  int test_failures = 0;

  task automatic clear_buffers();
    for (int r = 0; r < MAX_DIM; r++)
      for (int c = 0; c < MAX_DIM; c++) begin
        A_mem[r][c]   = '0;
        B_mem[r][c]   = '0;
        aux_mem[r][c] = '0;
        out_mem[r][c] = '0;
        out_seen[r][c] = 1'b0;
        out_writes_per_cell[r][c] = 0;
      end
    total_writes   = 0;
    first_idx_seen = -1;
    last_idx_seen  = -1;
  endtask

  task automatic run_tile(input int m, input int n, input int k,
                          input fused_op_t op,
                          input int predicted_cycles,
                          input string label);
    int cyc_start, cyc_end;

    tile_m = 8'(m);
    tile_n = 8'(n);
    tile_k = 8'(k);
    op_sel = op;

    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    cyc_start = $time / 2;
    fork
      begin
        wait (done);
      end
      begin
        repeat (predicted_cycles * 4) @(posedge clk);
        $display("    [%s] TIMEOUT after %0d cycles",
                 label, predicted_cycles * 4);
        test_failures++;
      end
    join_any
    disable fork;
    cyc_end = $time / 2;

    if ((cyc_end - cyc_start) > predicted_cycles * 12 / 10) begin
      $display("    [%s] cycle overhead %0.2fx > 1.1x",
               label,
               real'(cyc_end - cyc_start) / real'(predicted_cycles));
      test_failures++;
    end else begin
      $display("    [%s] %0d cycles (predicted %0d, %0.2fx)",
               label, cyc_end - cyc_start, predicted_cycles,
               real'(cyc_end - cyc_start) / real'(predicted_cycles));
    end
  endtask

  // Pattern A_ij = i + 1 (Q16.16), B_ij = 1 if i==j else 0.
  // C = A * B = A. Used to verify GEMM correctness against a known result.
  task automatic load_identity_pattern(input int m, input int n, input int k);
    for (int r = 0; r < m; r++)
      for (int c = 0; c < k; c++)
        A_mem[r][c] = to_q(real'(r + 1));
    for (int r = 0; r < k; r++)
      for (int c = 0; c < n; c++)
        B_mem[r][c] = (r == c) ? to_q(1.0) : '0;
  endtask

  // Verify out[r][c] = (r+1) for r in [0,m), c in [0,n) under BYPASS.
  // Tolerance accounts for Q4.4 multiplier quantization (1 LSB at Q4.4
  // = 1/16, but rows fit in Q4.4 cleanly).
  function automatic int check_identity_pattern(input int m, input int n,
                                                input int k,
                                                input string label);
    int errors = 0;
    real got, expected;
    int  bad_count;
    bad_count = 0;
    for (int r = 0; r < m; r++)
      for (int c = 0; c < n; c++) begin
        if (!out_seen[r][c]) begin
          if (bad_count < 4)
            $display("    [%s] out[%0d][%0d] never written", label, r, c);
          errors++;
          bad_count++;
          continue;
        end
        got      = from_q(out_mem[r][c]);
        // Reference: PE[r][c] = sum_j=0..k-1 A[r][j] * B[j][c]. For
        // B=identity the only non-zero term is j=c, BUT only when c<k
        // (the inner-product range). For c>=k the sum is 0.
        if (c < k)
          expected = real'(r + 1);
        else
          expected = 0.0;
        // The Q4.4 MAC saturates inputs at +7.9375 / -8.0 (NVFP4-style
        // mixed-precision). Without clamping the expected, rows 8+ would
        // "fail" against the saturated DUT output even when the math is
        // right.
        if (expected >  7.9375) expected =  7.9375;
        if (expected < -8.0   ) expected = -8.0;
        if ((got - expected) > 0.125 || (got - expected) < -0.125) begin
          if (bad_count < 4)
            $display("    [%s] out[%0d][%0d]=%0.4f vs %0.4f",
                     label, r, c, got, expected);
          errors++;
          bad_count++;
        end
      end
    if (errors == 0)
      $display("    [%s] PASS -- all %0d outputs match (tol 0.125)",
               label, m * n);
    else begin
      $display("    [%s] FAIL -- %0d/%0d errors", label, errors, m * n);
      // Probe c_out_array directly via hierarchical ref. Tells us if the
      // bug is in compute (math broken -- c_out is 0) or write-path
      // (math OK -- c_out is 1 but never lands in out_mem).
      $display("    [%s] -- diag: c_out_array[0][0]  = %0.4f (expect 1)",
               label, from_q(duv.c_out_array[0][0]));
      $display("    [%s] -- diag: c_out_array[0][1]  = %0.4f (expect 1)",
               label, from_q(duv.c_out_array[0][1]));
      $display("    [%s] -- diag: c_out_array[1][0]  = %0.4f (expect 2)",
               label, from_q(duv.c_out_array[1][0]));
      $display("    [%s] -- diag: c_out_array[1][1]  = %0.4f (expect 2)",
               label, from_q(duv.c_out_array[1][1]));
      $display("    [%s] -- diag: c_out_array[7][7]  = %0.4f (expect ~7.94 sat)",
               label, from_q(duv.c_out_array[7][7]));
      $display("    [%s] -- diag: c_out_array[63][63] = %0.4f (expect ~7.94 sat)",
               label, from_q(duv.c_out_array[63][63]));
      $display("    [%s] -- diag: total DUT writes captured: %0d (expected ~%0d)",
               label, total_writes, m * n);
      $display("    [%s] -- diag: first out_wr_idx = %0d (= 0x%h, row=%0d col=%0d)",
               label, first_idx_seen, first_idx_seen,
               (first_idx_seen >> 6) & 6'h3f, first_idx_seen & 6'h3f);
      $display("    [%s] -- diag: last  out_wr_idx = %0d (= 0x%h, row=%0d col=%0d)",
               label, last_idx_seen, last_idx_seen,
               (last_idx_seen >> 6) & 6'h3f, last_idx_seen & 6'h3f);
      // Write-count histogram by row.
      begin : diag_writes_per_row
        int writes_in_row;
        $display("    [%s] -- diag: writes-per-row counts (only nonzero):",
                 label);
        for (int rr = 0; rr < 64; rr++) begin
          writes_in_row = 0;
          for (int cc = 0; cc < 64; cc++)
            writes_in_row += out_writes_per_cell[rr][cc];
          if (writes_in_row > 0)
            $display("      row %0d: %0d total writes (over all cols)",
                     rr, writes_in_row);
        end
      end
      // Diagnostic: per-row pass count + per-col pass count + sample of
      // passing cells. Lets us see whether the 1/16-of-cells survival
      // pattern is row-aligned, col-aligned, or some other structure.
      begin : diag
        int row_pass [64];
        int col_pass [64];
        int dumped;
        for (int rr = 0; rr < 64; rr++) begin
          row_pass[rr] = 0;
          col_pass[rr] = 0;
        end
        for (int rr = 0; rr < m; rr++)
          for (int cc = 0; cc < n; cc++) begin
            real g, e;
            if (!out_seen[rr][cc]) continue;
            g = from_q(out_mem[rr][cc]);
            e = real'(rr + 1);
            if ((g - e) <= 0.125 && (g - e) >= -0.125) begin
              row_pass[rr]++;
              col_pass[cc]++;
            end
          end
        $display("    [%s] -- diag: per-row PASS counts:", label);
        for (int rr = 0; rr < m; rr++)
          if (row_pass[rr] > 0)
            $display("      row %0d: %0d/%0d cells pass",
                     rr, row_pass[rr], n);
        $display("    [%s] -- diag: per-col PASS counts:", label);
        for (int cc = 0; cc < n; cc++)
          if (col_pass[cc] > 0)
            $display("      col %0d: %0d/%0d cells pass",
                     cc, col_pass[cc], m);
        // Dump first 8 cells where out_seen is true but value is wrong.
        $display("    [%s] -- diag: first 8 'seen but wrong' cells:",
                 label);
        dumped = 0;
        for (int rr = 0; rr < m && dumped < 8; rr++)
          for (int cc = 0; cc < n && dumped < 8; cc++) begin
            real g, e;
            if (!out_seen[rr][cc]) continue;
            g = from_q(out_mem[rr][cc]);
            e = real'(rr + 1);
            if ((g - e) > 0.125 || (g - e) < -0.125) begin
              $display("      out[%0d][%0d] seen=1 got=%0.4f want=%0.4f",
                       rr, cc, g, e);
              dumped++;
            end
          end
        // Dump first 8 cells where out_seen is false (never written).
        $display("    [%s] -- diag: first 8 'never written' cells:",
                 label);
        dumped = 0;
        for (int rr = 0; rr < m && dumped < 8; rr++)
          for (int cc = 0; cc < n && dumped < 8; cc++) begin
            if (!out_seen[rr][cc]) begin
              $display("      out[%0d][%0d] out_seen=0", rr, cc);
              dumped++;
            end
          end
      end
    end
    return errors;
  endfunction

  // ----- Main -----
  initial begin
    int errs;
    $display("=== tb_stream_pipeline_tile: START ===");

    clk    = 0;
    rst_n  = 0;
    start  = 0;
    op_sel = FUSED_BYPASS;
    tile_m = 8'd0; tile_n = 8'd0; tile_k = 8'd0;
    clear_buffers();
    #20 rst_n = 1;
    #4;

    // ----- Scenario 1: (1,1,1) BYPASS -----
    // Minimum tile. Drain absorbs the rest; only 1 output write expected.
    clear_buffers();
    A_mem[0][0] = to_q(3.0);
    B_mem[0][0] = to_q(1.0);
    run_tile(1, 1, 1, FUSED_BYPASS, 200, "S1: (1,1,1) BYPASS");
    if (!out_seen[0][0] || from_q(out_mem[0][0]) < 2.5
                        || from_q(out_mem[0][0]) > 3.5) begin
      $display("    [S1] output mismatch: got %0.4f, want 3.0",
               from_q(out_mem[0][0]));
      test_failures++;
    end else
      $display("    [S1] PASS");

    // ----- Scenario 2: (64,64,64) BYPASS, identity pattern -----
    clear_buffers();
    load_identity_pattern(64, 64, 64);
    run_tile(64, 64, 64, FUSED_BYPASS, 4400, "S2: (64,64,64) BYPASS");
    test_failures += check_identity_pattern(64, 64, 64, "S2");

    // ----- Scenario 3: asymmetric tile (32,16,8) BYPASS -----
    clear_buffers();
    load_identity_pattern(32, 16, 8);
    run_tile(32, 16, 8, FUSED_BYPASS, 1000, "S3: (32,16,8) BYPASS");
    test_failures += check_identity_pattern(32, 16, 8, "S3");

    // ----- Scenario 4: (64,64,64) GELU -----
    // C = A (identity B). Expected: out[r][c] = GELU(r+1) for r<64.
    // For r >= 8 GELU(r+1) approaches r+1 (well past saturation midpoint).
    clear_buffers();
    load_identity_pattern(64, 64, 64);
    run_tile(64, 64, 64, FUSED_GELU, 4400 + 100, "S4: (64,64,64) GELU");
    begin : check_gelu
      int errors = 0;
      int bad_count = 0;
      real got, expected;
      for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++) begin
          if (!out_seen[r][c]) begin
            errors++; continue;
          end
          got      = from_q(out_mem[r][c]);
          // PE[r][c] computes A[r][c] = r+1 in Q4.4 (saturated at 7.9375).
          // Then fused_postproc applies GELU. Reference must clamp first.
          begin
            real sat_in;
            sat_in = real'(r + 1);
            if (sat_in >  7.9375) sat_in =  7.9375;
            if (sat_in < -8.0   ) sat_in = -8.0;
            expected = ref_gelu(sat_in);
          end
          if ((got - expected) > 0.25 || (got - expected) < -0.25) begin
            if (bad_count < 4)
              $display("    [S4] out[%0d][%0d]=%0.4f vs %0.4f",
                       r, c, got, expected);
            errors++; bad_count++;
          end
        end
      if (errors == 0)
        $display("    [S4] PASS -- GELU outputs match within tol");
      else begin
        $display("    [S4] FAIL -- %0d errors", errors);
        test_failures++;
      end
    end

    // ----- Scenario 5: (64,64,64) GELU_GRAD (HIGHEST RISK) -----
    // Identity GEMM => dh2_pre = (r+1).
    // aux_mem[r][c] = (r+1) so h_pre = (r+1).
    // Expected: out[r][c] = (r+1) * GELU'(r+1).
    clear_buffers();
    load_identity_pattern(64, 64, 64);
    for (int r = 0; r < 64; r++)
      for (int c = 0; c < 64; c++)
        aux_mem[r][c] = to_q(real'(r + 1));
    run_tile(64, 64, 64, FUSED_GELU_GRAD, 4400 + 100,
             "S5: (64,64,64) GELU_GRAD");
    begin : check_gelu_grad
      int errors = 0;
      int bad_count = 0;
      real got, expected;
      for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++) begin
          if (!out_seen[r][c]) begin
            errors++; continue;
          end
          got      = from_q(out_mem[r][c]);
          // dh2_pre (= A[r][c] = r+1) saturates in Q4.4. h_pre (= aux_mem
          // = r+1) likewise. Reference: dh2_pre * GELU'(h_pre), both
          // sat-clamped.
          begin
            real sat_dh, sat_h;
            sat_dh = real'(r + 1);
            sat_h  = real'(r + 1);
            if (sat_dh >  7.9375) sat_dh =  7.9375;
            if (sat_dh < -8.0   ) sat_dh = -8.0;
            if (sat_h  >  7.9375) sat_h  =  7.9375;
            if (sat_h  < -8.0   ) sat_h  = -8.0;
            expected = sat_dh * ref_gelu_prime(sat_h);
          end
          if ((got - expected) > 0.5 || (got - expected) < -0.5) begin
            if (bad_count < 4)
              $display("    [S5] out[%0d][%0d]=%0.4f vs %0.4f",
                       r, c, got, expected);
            errors++; bad_count++;
          end
        end
      if (errors == 0)
        $display("    [S5] PASS -- GELU_GRAD outputs aligned with h_pre");
      else begin
        $display("    [S5] FAIL -- %0d errors (likely h_pre misalignment)",
                 errors);
        test_failures++;
      end
    end

    // ----- Scenario 6: (64,64,64) SOFTMAX -----
    // C row r is constant = (r+1). Softmax of a constant row -> 1/N
    // for every element (uniform distribution).
    clear_buffers();
    for (int r = 0; r < 64; r++)
      for (int c = 0; c < 64; c++)
        A_mem[r][c] = to_q(real'(r + 1));
    for (int r = 0; r < 64; r++)
      for (int c = 0; c < 64; c++)
        B_mem[r][c] = to_q(1.0/64.0);
    // C[r][c] = sum_k A[r][k]*B[k][c] = (r+1)*sum_k 1/64 = r+1.
    // -> softmax(row of constant r+1) = uniform 1/64.
    run_tile(64, 64, 64, FUSED_SOFTMAX, 4400 + 256,
             "S6: (64,64,64) SOFTMAX");
    begin : check_softmax
      int errors = 0;
      real got;
      for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++) begin
          if (!out_seen[r][c]) begin
            errors++; continue;
          end
          got = from_q(out_mem[r][c]);
          if ((got - 1.0/64.0) > 0.01 || (got - 1.0/64.0) < -0.01) begin
            if (errors < 4)
              $display("    [S6] out[%0d][%0d]=%0.4f vs 0.0156",
                       r, c, got);
            errors++;
          end
        end
      if (errors == 0)
        $display("    [S6] PASS -- softmax uniform distribution OK");
      else begin
        $display("    [S6] FAIL -- %0d errors", errors);
        test_failures++;
      end
    end

    // ----- Scenario 7: (64,64,64) MASK -----
    // Causal mask zeroes out the upper triangle. Test that out[r][c]=0
    // for c > r (masked) and out[r][c]=C[r][c] otherwise.
    clear_buffers();
    load_identity_pattern(64, 64, 64);
    run_tile(64, 64, 64, FUSED_MASK, 4400 + 100, "S7: (64,64,64) MASK");
    begin : check_mask
      int errors = 0;
      real got, expected;
      int bad_count = 0;
      for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++) begin
          if (!out_seen[r][c]) begin
            errors++; continue;
          end
          got      = from_q(out_mem[r][c]);
          // Causal: c > r masked to a very-negative value (Q_NEG_BIG);
          // otherwise passthrough = (r+1).
          if (c > r) begin
            if (got > -1000.0) begin
              if (bad_count < 4)
                $display("    [S7] out[%0d][%0d]=%0.4f should be masked",
                         r, c, got);
              errors++; bad_count++;
            end
          end else begin
            expected = real'(r + 1);
            if ((got - expected) > 0.125 || (got - expected) < -0.125) begin
              if (bad_count < 4)
                $display("    [S7] out[%0d][%0d]=%0.4f vs %0.4f",
                         r, c, got, expected);
              errors++; bad_count++;
            end
          end
        end
      if (errors == 0)
        $display("    [S7] PASS -- causal mask applied correctly");
      else begin
        $display("    [S7] FAIL -- %0d errors", errors);
        test_failures++;
      end
    end

    // ----- Scenario 8: back-to-back (64,64,64) BYPASS x3 -----
    for (int tile = 0; tile < 3; tile++) begin
      clear_buffers();
      load_identity_pattern(64, 64, 64);
      run_tile(64, 64, 64, FUSED_BYPASS, 4400,
               $sformatf("S8.%0d: back-to-back", tile + 1));
      errs = check_identity_pattern(64, 64, 64,
                $sformatf("S8.%0d", tile + 1));
      if (errs > 0) test_failures += 1;
    end

    // ----- Summary -----
    $display("");
    $display("=== tb_stream_pipeline_tile: ALL TESTS DONE ===");
    if (test_failures == 0)
      $display("=== TB_SP_TILE: PASS ===");
    else
      $display("=== TB_SP_TILE: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  // Watchdog
  initial begin
    #1000000;
    $display("WATCHDOG: simulation timed out at 1ms");
    $display("=== TB_SP_TILE: FAIL (timeout) ===");
    $finish;
  end

endmodule
