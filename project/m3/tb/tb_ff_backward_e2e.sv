// =============================================================================
// tb_ff_backward_e2e.sv -- end-to-end cosim of the ff_backward kernel
// =============================================================================
//
// Drives the integrated top.sv (chiplet_interface + compute_core) ONLY
// through the UCIe-side ports. Same pattern as tb_top.sv but exercises
// MODE_FFN_BWD and verifies the fused (GEMM + GELU' elementwise) output.
//
// What MODE_FFN_BWD actually computes (per accel_controller.sv:96):
//     dh1[i][j] = (A @ B)[i][j] * GELU_prime(aux[i][j])
//
//   A   = dy  (upstream gradient)
//   B   = W2.T (second FFN weights, transposed)
//   aux = h1  (pre-activation, was saved during forward pass)
//   out = dh1 (the fused output written back to addr_out)
//
// One macro = one fused output (NOT the full 4-output ff_backward). The
// full kernel decomposes to:
//
//   macro 1: MODE_FFN_BWD     -> dh1     (this testbench)
//   macro 2: MODE_ATTN_BWD    -> dW1     (plain GEMM, X.T @ dh1)
//   macro 3: MODE_ATTN_BWD    -> dX      (plain GEMM, dh1 @ W1.T)
//
// Macros 2 and 3 are plain GEMMs already exercised by other tests; this
// TB focuses on the unique fused step (macro 1) -- it's the path that
// crosses every M5/M6 pipelining change at once (mac_pe_piped4, M6 Tier
// 1.5 / 1.6 / Option F at the stream_pipeline boundary, fused_postproc
// Tier 2A, gelu_grad_unit_lut Tier 2B, h_pre data_delay alignment).
//
// Test approach (mirrors tb_top.sv): use analytical input patterns so
// the expected output is a known constant, sample multiple cells across
// the tile, compare within tolerance. The reference math is computed in
// SV `real` -- no Python, no hex files, no external dependencies.
//
// Final summary line is "=== TB_FFB_E2E: PASS ===" or
// "=== TB_FFB_E2E: FAIL (N failure(s)) ===" -- the log scraper greps for
// the PASS line.
// =============================================================================
`timescale 1ns/1ps

module tb_ff_backward_e2e;
  import accel_pkg::*;

  // ----- Bus widths (must match top.sv / chiplet_interface) -----
  localparam int LANE_BITS_TB = $clog2(16);
  localparam int DMA_AW_TB    = LANE_LOCAL_W + LANE_BITS_TB;
  localparam int CMD_BUS_W    = 128;
  localparam int WR_BUS_W     = DMA_AW_TB + 32;

  // ----- Tile dim (matches accel_pkg::TILE_SIZE) -----
  localparam int N = 64;

  // ----- DUV signals -----
  logic                  clk, rst_n;
  logic                  ucie_cmd_valid, ucie_cmd_ready;
  logic [CMD_BUS_W-1:0]  ucie_cmd_data;
  logic                  ucie_wr_valid,  ucie_wr_ready;
  logic [WR_BUS_W-1:0]   ucie_wr_data;
  logic                  ucie_rd_req,    ucie_rd_valid;
  logic [DMA_AW_TB-1:0]  ucie_rd_addr;
  logic [31:0]           ucie_rd_data;
  logic                  ucie_irq, ucie_busy;

  top dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .ucie_cmd_valid (ucie_cmd_valid),
    .ucie_cmd_ready (ucie_cmd_ready),
    .ucie_cmd_data  (ucie_cmd_data),
    .ucie_wr_valid  (ucie_wr_valid),
    .ucie_wr_ready  (ucie_wr_ready),
    .ucie_wr_data   (ucie_wr_data),
    .ucie_rd_req    (ucie_rd_req),
    .ucie_rd_addr   (ucie_rd_addr),
    .ucie_rd_data   (ucie_rd_data),
    .ucie_rd_valid  (ucie_rd_valid),
    .ucie_irq       (ucie_irq),
    .ucie_busy      (ucie_busy)
  );

  always #1 clk = ~clk;

  // ----- Q16.16 / fp conversion helpers -----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction
  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // ----- DMA address packing (lane=0 throughout) -----
  function automatic logic [DMA_AW_TB-1:0] dma_addr(input int lane,
                                                    input int loc);
    return ({LANE_BITS_TB'(lane), LANE_LOCAL_W'(loc)});
  endfunction

  // ----- Per-buffer base addresses (lane 0 slot 0) -----
  localparam logic [15:0] ADDR_A   = 16'h0000;  // dy
  localparam logic [15:0] ADDR_B   = 16'h1000;  // W2.T
  localparam logic [15:0] ADDR_AUX = 16'h2000;  // h1 (h_pre)
  localparam logic [15:0] ADDR_OUT = 16'h3000;  // dh1

  // ----- Reference math: SV `real` GELU and GELU' -----
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

  // Q4.4 grid quantization (matches mac_pe_piped4's pre-multiplier path).
  // Saturate to [-8.0, +7.9375], then snap to the nearest 1/16 grid point
  // by truncating (arithmetic right-shift, same as the chip).
  function automatic real q44_quantize_fp(input real x);
    real clipped, grid_step;
    grid_step = 0.0625;  // 1 / 16
    if (x > 7.9375)       clipped = 7.9375;
    else if (x < -8.0)    clipped = -8.0;
    else                  clipped = x;
    // Truncate to grid (round toward zero for positive, toward -inf for
    // negative -- arithmetic right shift in HW), then re-scale.
    return $floor(clipped / grid_step) * grid_step;
  endfunction

  // ----- UCIe-side host tasks -----
  task automatic ucie_write(input logic [DMA_AW_TB-1:0] addr,
                            input real val);
    @(posedge clk);
    ucie_wr_data  <= {addr, to_q(val)};
    ucie_wr_valid <= 1'b1;
    @(posedge clk);
    ucie_wr_valid <= 1'b0;
  endtask

  task automatic ucie_read(input  logic [DMA_AW_TB-1:0] addr,
                           output real val);
    @(posedge clk);
    ucie_rd_addr <= addr;
    ucie_rd_req  <= 1'b1;
    @(posedge clk);
    ucie_rd_req  <= 1'b0;
    do @(posedge clk); while (!ucie_rd_valid);
    val = from_q($signed(ucie_rd_data));
  endtask

  task automatic ucie_issue_macro(input mode_t mode,
                                  input logic [15:0] a, b, aux, o,
                                  input logic [7:0]  num_m, num_n,
                                  input logic [7:0]  tm, tn, tk);
    macro_cmd_t cmd;
    cmd.mode        = mode;
    cmd.addr_a      = a;
    cmd.addr_b      = b;
    cmd.addr_aux    = aux;
    cmd.addr_out    = o;
    cmd.num_m_tiles = num_m;
    cmd.num_n_tiles = num_n;
    cmd.tile_m      = tm;
    cmd.tile_n      = tn;
    cmd.tile_k      = tk;

    @(posedge clk);
    ucie_cmd_data  <= {{(CMD_BUS_W-$bits(macro_cmd_t)){1'b0}}, cmd};
    ucie_cmd_valid <= 1'b1;
    @(posedge clk);
    ucie_cmd_valid <= 1'b0;

    fork
      begin
        wait (ucie_irq);
      end
      begin
        repeat (500000) @(posedge clk);
        $display("    TIMEOUT waiting for ucie_irq");
      end
    join_any
    disable fork;
    @(posedge clk);
  endtask

  // ----- Load identity-pattern matrices: A = all ones, B = identity -----
  // C = A @ B = A = all-ones. So dh2 (pre-elementwise) = 1.0 everywhere.
  task automatic load_ones_identity();
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        ucie_write(dma_addr(0, ADDR_A + r*N + c), 1.0);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        ucie_write(dma_addr(0, ADDR_B + r*N + c), (r == c) ? 1.0 : 0.0);
  endtask

  // Fill aux (h_pre) with a single constant value.
  task automatic load_aux_constant(input real h_val);
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++)
        ucie_write(dma_addr(0, ADDR_AUX + r*N + c), h_val);
  endtask

  // ----- Verification: sample tile, compare against expected -----
  int test_failures = 0;

  // Tolerance: 0.05 in fp units. Accounts for:
  //   - Q4.4 multiplier quantization in mac_pe_piped4 (1 LSB = 0.0625)
  //   - GELU' LUT 256-entry interpolation error (~0.01 typical)
  //   - Saturation rounding at boundaries
  localparam real TOL = 0.05;

  task automatic verify_const_output(input string label,
                                     input real expected,
                                     input int n_samples);
    int ok, sample_r, sample_c;
    real got;
    ok = 0;
    for (int s = 0; s < n_samples; s++) begin
      // Deterministic sampling: corners, diagonal, off-diagonal.
      case (s % 8)
        0: begin sample_r = 0;        sample_c = 0;        end
        1: begin sample_r = 0;        sample_c = N - 1;    end
        2: begin sample_r = N - 1;    sample_c = 0;        end
        3: begin sample_r = N - 1;    sample_c = N - 1;    end
        4: begin sample_r = (s * 7) % N; sample_c = (s * 7) % N; end
        5: begin sample_r = (s * 5) % N; sample_c = (s * 11) % N; end
        6: begin sample_r = 7;        sample_c = 23;       end
        7: begin sample_r = 31;       sample_c = 13;       end
      endcase
      ucie_read(dma_addr(0, ADDR_OUT + sample_r * N + sample_c), got);
      if ((got - expected) < TOL && (got - expected) > -TOL) begin
        ok++;
      end else begin
        $display("    [%s] out[%0d][%0d] = %0.4f vs expected %0.4f "
                 "(err %0.4f, tol %0.2f)",
                 label, sample_r, sample_c, got, expected,
                 got - expected, TOL);
      end
    end
    if (ok == n_samples)
      $display("  PASS: %s -- %0d/%0d samples within tol",
               label, ok, n_samples);
    else begin
      $display("  FAIL: %s -- %0d/%0d samples within tol",
               label, ok, n_samples);
      test_failures++;
    end
  endtask

  // ----- One MODE_FFN_BWD scenario: constant aux value, identity GEMM -----
  // Expected: dh1[r][c] = 1.0 * GELU'(h_const) = constant across the tile
  task automatic run_scenario(input string label, input real h_const);
    real expected, h_q44;
    int  cyc_start, cyc_end;

    $display("");
    $display(">>> %s: h_pre = %0.4f everywhere", label, h_const);

    // Load identity GEMM (C = all ones) + constant aux
    load_ones_identity();
    load_aux_constant(h_const);

    // Issue macro
    cyc_start = $time / 2;
    ucie_issue_macro(MODE_FFN_BWD,
                     ADDR_A, ADDR_B, ADDR_AUX, ADDR_OUT,
                     8'd1, 8'd1,                        // 1x1 macro
                     8'(N), 8'(N), 8'(N));
    cyc_end = $time / 2;
    $display("    macro completed in %0d cycles", cyc_end - cyc_start);

    // Reference: 1.0 * GELU'(h_const). h_const goes through the chip's
    // Q4.4 quantization in the LUT input, so do the same for the
    // reference value.
    h_q44    = q44_quantize_fp(h_const);
    expected = 1.0 * ref_gelu_prime(h_q44);

    // Sample 16 outputs and compare
    verify_const_output(label, expected, 16);
  endtask

  // ----- Main test sequence -----
  initial begin : main_test
    $display("=== tb_ff_backward_e2e: START ===");
    clk            = 0; rst_n          = 0;
    ucie_cmd_valid = 0; ucie_cmd_data  = '0;
    ucie_wr_valid  = 0; ucie_wr_data   = '0;
    ucie_rd_req    = 0; ucie_rd_addr   = '0;
    #20 rst_n = 1;
    #4;

    // ----- Scenario A: baseline -- h_pre = 1.0 -----
    // GELU'(1.0) ~= 1.0828
    run_scenario("Scenario A (h=1.0)", 1.0);

    // ----- Scenario B: positive saturation region -- h_pre = 2.0 -----
    // GELU'(2.0) ~= 1.0852 -- close to 1.0 in the upper saturation region
    run_scenario("Scenario B (h=2.0)", 2.0);

    // ----- Scenario C: negative side -- h_pre = -1.0 -----
    // GELU'(-1.0) ~= -0.0828 -- catches sign-handling bugs in
    // gelu_grad_unit_lut and h_pre data_delay alignment
    run_scenario("Scenario C (h=-1.0)", -1.0);

    // ----- Scenario D: near zero -- h_pre = 0.0 -----
    // GELU'(0.0) = 0.5 -- the inflection point
    run_scenario("Scenario D (h=0.0)", 0.0);

    // ----- Scenario E: sub-unit positive -- h_pre = 0.5 -----
    // GELU'(0.5) ~= 0.8675 -- mid-curve region exercises LUT interpolation
    run_scenario("Scenario E (h=0.5)", 0.5);

    // ----- Scenario F: saturation boundary -- h_pre near Q4.4 max -----
    // h = 7.5 is inside Q4.4 range but near the boundary; verifies the
    // chip clamps cleanly without overflow
    run_scenario("Scenario F (h=7.5)", 7.5);

    // ----- Scenario G: state-leakage regression -- repeat A -----
    // Re-run scenario A AFTER scenarios B-F to confirm the chip's FSM /
    // tile_buffer / output buffer all reset cleanly between macros
    run_scenario("Scenario G (h=1.0 repeat)", 1.0);

    // ----- Summary -----
    $display("");
    $display("=== tb_ff_backward_e2e: ALL TESTS DONE ===");
    if (test_failures == 0)
      $display("=== TB_FFB_E2E: PASS ===");
    else
      $display("=== TB_FFB_E2E: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  // ----- Watchdog -----
  initial begin
    #20000000;     // 20 ms
    $display("WATCHDOG: simulation timed out at 20ms");
    $display("=== TB_FFB_E2E: FAIL (timeout) ===");
    $finish;
  end

endmodule
