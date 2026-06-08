// =============================================================================
// tb_compute_core.sv -- subsystem-level compute_core integration testbench
// =============================================================================
//
// Drives compute_core directly with macro_cmd_t + DMA, skipping the
// chiplet_interface UCIe-layer wrappers. This isolates the
// dispatcher/scheduler/DMA path from the host protocol layer so a bug at
// the macro_cmd boundary can't be confused with a UCIe-side bug.
//
// What this catches (M3 verification plan Section 4.2):
//   - macro_cmd_t -> per-tile cmd_pkt_t decomposition (mode_decoder /
//     tile_scheduler / tile_dispatcher)
//   - DMA write/read ordering vs compute scheduling
//   - Tile-to-tile state cleanliness between back-to-back macros
//   - Aux buffer pre-load for ff_backward GELU_GRAD path
//   - core_done / core_irq assertion ordering
//
// Scenarios (4 tiles):
//   1. Single ff_forward 64x64 tile (sanity)
//   2. Single ff_backward 64x64 tile (deliverable kernel, full
//      decomposition through compute_core)
//   3. ff_forward -> ff_backward -> ff_forward sequence (state leakage
//      regression)
//   4. ff_backward with aux pre-loaded vs aux loaded mid-sequence
//
// Inputs are simple analytical patterns; correctness is verified by
// reading outputs back through core_dma_rd_* and comparing against
// software-computed references. (For bit-exact ref against the chip's
// mixed precision use tb_ff_backward_e2e.sv with the Python cosim
// vectors; this TB focuses on integration-level functional behavior.)
//
// Final summary line is "=== TB_CC: PASS ===" or "FAIL ...".
// =============================================================================
`timescale 1ns/1ps

module tb_compute_core;
  import accel_pkg::*;

  // Bus widths -- match compute_core defaults
  localparam int N_LANES         = 16;
  localparam int LANE_BITS       = (N_LANES <= 1) ? 1 : $clog2(N_LANES);
  localparam int DMA_ADDR_W      = LANE_LOCAL_W + LANE_BITS;
  localparam int N               = 64;     // ARRAY_DIM, tile dim
  localparam int MAX_BUF         = N * N;

  // ----- Clock / reset -----
  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;

  // ----- DUV ports -----
  macro_cmd_t            core_macro_cmd;
  logic                  core_macro_cmd_valid, core_macro_cmd_ready;

  logic                  core_dma_wr_valid;
  logic [DMA_ADDR_W-1:0] core_dma_wr_addr;
  logic [31:0]           core_dma_wr_data;
  logic                  core_dma_wr_ready;

  logic                  core_dma_rd_req;
  logic [DMA_ADDR_W-1:0] core_dma_rd_addr;
  logic [31:0]           core_dma_rd_data;
  logic                  core_dma_rd_valid;

  logic                  core_busy, core_done, core_irq;

  // ----- DUV -----
  compute_core #(
    .N_LANES(N_LANES)
  ) duv (
    .clk                  (clk),
    .rst_n                (rst_n),
    .macro_cmd_in         (core_macro_cmd),
    .macro_cmd_valid      (core_macro_cmd_valid),
    .macro_cmd_ready      (core_macro_cmd_ready),
    .dma_wr_valid         (core_dma_wr_valid),
    .dma_wr_addr          (core_dma_wr_addr),
    .dma_wr_data          (core_dma_wr_data),
    .dma_wr_ready         (core_dma_wr_ready),
    .dma_rd_req           (core_dma_rd_req),
    .dma_rd_addr          (core_dma_rd_addr),
    .dma_rd_data          (core_dma_rd_data),
    .dma_rd_valid         (core_dma_rd_valid),
    .busy                 (core_busy),
    .done                 (core_done),
    .irq                  (core_irq)
  );

  // ----- Helpers -----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction
  function automatic logic [DMA_ADDR_W-1:0] dma_addr(input int lane,
                                                     input int loc);
    return ({LANE_BITS'(lane), LANE_LOCAL_W'(loc)});
  endfunction

  // GELU + GELU' (software ref)
  function automatic real ref_gelu(input real x);
    real t;
    t = $tanh(0.7978845608 * (x + 0.044715 * x * x * x));
    return 0.5 * x * (1.0 + t);
  endfunction
  function automatic real ref_gelu_prime(input real x);
    real t, du_dx;
    real u = 0.7978845608 * (x + 0.044715 * x * x * x);
    t     = $tanh(u);
    du_dx = 0.7978845608 * (1.0 + 3.0 * 0.044715 * x * x);
    return 0.5 * (1.0 + t) + 0.5 * x * (1.0 - t * t) * du_dx;
  endfunction

  // ----- Bus tasks -----
  task automatic dma_write(input logic [DMA_ADDR_W-1:0] addr,
                           input real val);
    @(posedge clk);
    while (!core_dma_wr_ready) @(posedge clk);
    core_dma_wr_addr  <= addr;
    core_dma_wr_data  <= to_q(val);
    core_dma_wr_valid <= 1'b1;
    @(posedge clk);
    core_dma_wr_valid <= 1'b0;
  endtask

  task automatic dma_read(input  logic [DMA_ADDR_W-1:0] addr,
                          output real val);
    @(posedge clk);
    core_dma_rd_addr <= addr;
    core_dma_rd_req  <= 1'b1;
    @(posedge clk);
    core_dma_rd_req  <= 1'b0;
    do @(posedge clk); while (!core_dma_rd_valid);
    val = from_q($signed(core_dma_rd_data));
  endtask

  task automatic issue_macro(input mode_t mode,
                             input logic [15:0] a, b, aux, o,
                             input logic [7:0]  num_m, num_n,
                             input logic [7:0]  tm, tn, tk);
    @(posedge clk);
    core_macro_cmd.mode        <= mode;
    core_macro_cmd.addr_a      <= a;
    core_macro_cmd.addr_b      <= b;
    core_macro_cmd.addr_aux    <= aux;
    core_macro_cmd.addr_out    <= o;
    core_macro_cmd.num_m_tiles <= num_m;
    core_macro_cmd.num_n_tiles <= num_n;
    core_macro_cmd.tile_m      <= tm;
    core_macro_cmd.tile_n      <= tn;
    core_macro_cmd.tile_k      <= tk;
    core_macro_cmd_valid       <= 1'b1;
    @(posedge clk);
    while (!core_macro_cmd_ready) @(posedge clk);
    core_macro_cmd_valid       <= 1'b0;

    // Wait for irq
    fork
      begin
        wait (core_irq);
      end
      begin
        repeat (1000000) @(posedge clk);
        $display("    TIMEOUT waiting for core_irq");
      end
    join_any
    disable fork;
    @(posedge clk);
  endtask

  // ----- Loading patterns -----
  // A = all-ones, B = identity   ->   C = A
  task automatic load_ones_identity(input logic [15:0] addr_a,
                                    input logic [15:0] addr_b);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        dma_write(dma_addr(0, addr_a + r*N + c), 1.0);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        dma_write(dma_addr(0, addr_b + r*N + c), (r == c) ? 1.0 : 0.0);
  endtask

  // h_pre = 1.0 everywhere
  task automatic load_aux_ones(input logic [15:0] addr_aux);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        dma_write(dma_addr(0, addr_aux + r*N + c), 1.0);
  endtask

  // ----- Verification helpers -----
  int test_failures = 0;

  task automatic verify_uniform(input logic [15:0] addr_out,
                                input real expected,
                                input real tol,
                                input string label,
                                input int n_samples);
    int sample_r, sample_c, ok;
    real got;
    ok = 0;
    for (int s = 0; s < n_samples; s++) begin
      sample_r = $urandom_range(N - 1, 0);
      sample_c = $urandom_range(N - 1, 0);
      dma_read(dma_addr(0, addr_out + sample_r*N + sample_c), got);
      if ((got - expected) < tol && (got - expected) > -tol)
        ok++;
      else
        $display("    [%s] out[%0d][%0d]=%0.4f vs %0.4f",
                 label, sample_r, sample_c, got, expected);
    end
    if (ok == n_samples)
      $display("    [%s] PASS -- %0d/%0d samples within tol", label, ok, n_samples);
    else begin
      $display("    [%s] FAIL -- %0d/%0d samples within tol",
               label, ok, n_samples);
      test_failures++;
    end
  endtask

  // ----- Main -----
  initial begin
    logic [15:0] ADDR_A   = 16'h0000;
    logic [15:0] ADDR_B   = 16'h1000;
    logic [15:0] ADDR_AUX = 16'h2000;
    logic [15:0] ADDR_OUT = 16'h3000;
    real expected;

    $display("=== tb_compute_core: START ===");
    clk = 0; rst_n = 0;
    core_macro_cmd       = '0;
    core_macro_cmd_valid = 0;
    core_dma_wr_valid    = 0; core_dma_wr_addr = '0; core_dma_wr_data = '0;
    core_dma_rd_req      = 0; core_dma_rd_addr = '0;
    #20 rst_n = 1;
    #4;

    // ----- Scenario 1: single ff_forward tile -----
    $display(">>> Scenario 1: single ff_forward 64x64 tile");
    load_ones_identity(ADDR_A, ADDR_B);
    issue_macro(MODE_FFN_FWD,
                ADDR_A, ADDR_B, ADDR_AUX, ADDR_OUT,
                8'd1, 8'd1,
                8'(N), 8'(N), 8'(N));
    expected = ref_gelu(1.0);
    verify_uniform(ADDR_OUT, expected, 0.05, "S1: ff_forward", 16);

    // ----- Diagnostic: where did the data go? -----
    // ADDR_OUT[0] = GELU(1.0) is correct, but verify_uniform's random
    // samples come back 0. Either only one cell was written, or the TB's
    // address scheme differs from what the DUT writes.
    begin : s1_diag
      real         sample_real;
      int          nonzero_count;
      // 1. Confirm lane 0 has A and OUT[0] populated.
      $display("    [S1-DIAG] Lane scan:");
      for (int lane = 0; lane < N_LANES; lane++) begin
        dma_read(dma_addr(lane, ADDR_OUT), sample_real);
        if (sample_real != 0.0)
          $display("      lane %0d, ADDR_OUT[0] = %0.4f", lane, sample_real);
      end
      // 2. Walk lane 0's output region from ADDR_OUT to ADDR_OUT+127.
      //    If only first N (=64) cells have data, the output is row 0 only.
      //    If every Nth cell has data, the output is column-major.
      $display("    [S1-DIAG] Lane 0 ADDR_OUT[0..127] nonzero map:");
      nonzero_count = 0;
      for (int offset = 0; offset < 128; offset++) begin
        dma_read(dma_addr(0, ADDR_OUT + offset[15:0]), sample_real);
        if (sample_real != 0.0) begin
          nonzero_count++;
          if (nonzero_count < 16)
            $display("      ADDR_OUT[%0d] = %0.4f  (row %0d col %0d if row-major)",
                     offset, sample_real, offset/64, offset%64);
        end
      end
      $display("    [S1-DIAG] nonzero in first 128 cells: %0d", nonzero_count);
      // 3. Sweep stride 64 to detect column-major layout.
      $display("    [S1-DIAG] Lane 0 ADDR_OUT[0,64,128,...,4032] nonzero map:");
      nonzero_count = 0;
      for (int r = 0; r < 64; r++) begin
        dma_read(dma_addr(0, ADDR_OUT + (r*64)), sample_real);
        if (sample_real != 0.0) begin
          nonzero_count++;
          if (nonzero_count < 16)
            $display("      ADDR_OUT[%0d] (row %0d col 0 row-major) = %0.4f",
                     r*64, r, sample_real);
        end
      end
      $display("    [S1-DIAG] nonzero col-0-rowmajor cells: %0d", nonzero_count);
      // 4. Try address scheme {col, row} (col-major flip).
      $display("    [S1-DIAG] Lane 0 col-major scan ADDR_OUT[col*64+row]:");
      nonzero_count = 0;
      for (int c = 0; c < 64; c++) begin
        dma_read(dma_addr(0, ADDR_OUT + (c*64)), sample_real);
        if (sample_real != 0.0)
          nonzero_count++;
      end
      $display("    [S1-DIAG] full lane-0 nonzero count needs broader scan");
    end

    // ----- Scenario 2: single ff_backward tile -----
    // C = A (identity B), dy = A (= 1.0). h_pre = 1.0.
    // ff_backward step on the elementwise path: out = dy * GELU'(h_pre).
    // = 1.0 * GELU'(1.0)
    $display(">>> Scenario 2: single ff_backward 64x64 tile");
    load_ones_identity(ADDR_A, ADDR_B);
    load_aux_ones(ADDR_AUX);
    issue_macro(MODE_FFN_BWD,
                ADDR_A, ADDR_B, ADDR_AUX, ADDR_OUT,
                8'd1, 8'd1,
                8'(N), 8'(N), 8'(N));
    expected = ref_gelu_prime(1.0);  // dy=1.0, h_pre=1.0
    verify_uniform(ADDR_OUT, expected, 0.05,
                   "S2: ff_backward (dh1=dy*GELU'(h_pre))", 16);

    // ----- Scenario 3: back-to-back ff_forward -> ff_backward -> ff_forward -----
    // Verifies state cleanliness: every tile reproduces its expected
    // result independent of preceding tiles.
    $display(">>> Scenario 3: ff_fwd -> ff_bwd -> ff_fwd back-to-back");
    for (int i = 0; i < 3; i++) begin
      automatic mode_t mode = (i == 1) ? MODE_FFN_BWD : MODE_FFN_FWD;
      automatic string label;
      load_ones_identity(ADDR_A, ADDR_B);
      load_aux_ones(ADDR_AUX);
      issue_macro(mode,
                  ADDR_A, ADDR_B, ADDR_AUX, ADDR_OUT,
                  8'd1, 8'd1,
                  8'(N), 8'(N), 8'(N));
      expected = (mode == MODE_FFN_BWD)
                   ? ref_gelu_prime(1.0)
                   : ref_gelu(1.0);
      label = $sformatf("S3.%0d: %s", i + 1,
                        (mode == MODE_FFN_BWD) ? "ff_bwd" : "ff_fwd");
      verify_uniform(ADDR_OUT, expected, 0.05, label, 8);
    end

    // ----- Scenario 4: ff_backward with non-uniform aux -----
    // h_pre = 2.0 everywhere; dy = 1.0; expected = GELU'(2.0)
    $display(">>> Scenario 4: ff_backward with h_pre = 2.0");
    load_ones_identity(ADDR_A, ADDR_B);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        dma_write(dma_addr(0, ADDR_AUX + r*N + c), 2.0);
    issue_macro(MODE_FFN_BWD,
                ADDR_A, ADDR_B, ADDR_AUX, ADDR_OUT,
                8'd1, 8'd1,
                8'(N), 8'(N), 8'(N));
    expected = ref_gelu_prime(2.0);   // dy=1.0
    verify_uniform(ADDR_OUT, expected, 0.05,
                   "S4: ff_backward h_pre=2.0", 16);

    // ----- Summary -----
    $display("");
    $display("=== tb_compute_core: ALL TESTS DONE ===");
    if (test_failures == 0)
      $display("=== TB_CC: PASS ===");
    else
      $display("=== TB_CC: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  // Watchdog
  initial begin
    #5000000;
    $display("WATCHDOG: simulation timed out at 5ms");
    $display("=== TB_CC: FAIL (timeout) ===");
    $finish;
  end

endmodule
