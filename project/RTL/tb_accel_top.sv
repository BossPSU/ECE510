// tb_accel_top.sv — Top-level smoke test TB
// 3 directed tests: FFN forward, FFN backward, Attention
// All tiny data, no randomization, golden model inline
`timescale 1ns/1ps

module tb_accel_top;
  import accel_pkg::*;

  logic        clk, rst_n;
  macro_cmd_t  macro_cmd_in;
  logic        macro_cmd_valid, macro_cmd_ready;
  logic        dma_wr_valid, dma_wr_ready;
  logic [15:0] dma_wr_addr;
  logic [31:0] dma_wr_data;
  logic        dma_rd_req, dma_rd_valid;
  logic [15:0] dma_rd_addr;
  logic [31:0] dma_rd_data;
  logic        busy, done, irq;
  logic [31:0] perf_active, perf_stall, perf_tiles;

  accel_top dut (
    .clk                  (clk),
    .rst_n                (rst_n),
    .macro_cmd_in         (macro_cmd_in),
    .macro_cmd_valid      (macro_cmd_valid),
    .macro_cmd_ready      (macro_cmd_ready),
    .dma_wr_valid         (dma_wr_valid),
    .dma_wr_addr          (dma_wr_addr),
    .dma_wr_data          (dma_wr_data),
    .dma_wr_ready         (dma_wr_ready),
    .dma_rd_req           (dma_rd_req),
    .dma_rd_addr          (dma_rd_addr),
    .dma_rd_data          (dma_rd_data),
    .dma_rd_valid         (dma_rd_valid),
    .busy                 (busy),
    .done                 (done),
    .irq                  (irq),
    .perf_active_cycles   (perf_active),
    .perf_stall_cycles    (perf_stall),
    .perf_tiles_completed (perf_tiles)
  );

  // Clock: 500 MHz
  always #1 clk = ~clk;

  // ---- Q16.16 helpers ----
  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // ---- Helper tasks ----

  // Write one Q16.16 value to scratchpad via DMA
  task automatic dma_write(input logic [15:0] addr, input real val);
    @(posedge clk);
    dma_wr_valid <= 1'b1;
    dma_wr_addr  <= addr;
    dma_wr_data  <= to_q(val);
    @(posedge clk);
    dma_wr_valid <= 1'b0;
    @(posedge clk);
  endtask

  // Read one Q16.16 value from scratchpad via DMA
  task automatic dma_read(input logic [15:0] addr, output real val);
    @(posedge clk);
    dma_rd_req  <= 1'b1;
    dma_rd_addr <= addr;
    @(posedge clk);
    dma_rd_req <= 1'b0;
    @(posedge clk);
    @(posedge clk);
    val = from_q($signed(dma_rd_data));
  endtask

  // Issue a single-tile macro command (num_m_tiles = num_n_tiles = 1).
  // For multi-tile use issue_macro directly.
  task automatic issue_cmd(input mode_t mode,
                           input logic [15:0] a, b, aux, o,
                           input logic [7:0] tm, tn, tk);
    issue_macro(mode, a, b, aux, o, 8'd1, 8'd1, tm, tn, tk);
  endtask

  // Issue a multi-tile macro command and wait for done.
  task automatic issue_macro(input mode_t mode,
                             input logic [15:0] a, b, aux, o,
                             input logic [7:0] num_m, num_n,
                             input logic [7:0] tm, tn, tk);
    @(posedge clk);
    macro_cmd_in.mode        <= mode;
    macro_cmd_in.addr_a      <= a;
    macro_cmd_in.addr_b      <= b;
    macro_cmd_in.addr_aux    <= aux;
    macro_cmd_in.addr_out    <= o;
    macro_cmd_in.num_m_tiles <= num_m;
    macro_cmd_in.num_n_tiles <= num_n;
    macro_cmd_in.tile_m      <= tm;
    macro_cmd_in.tile_n      <= tn;
    macro_cmd_in.tile_k      <= tk;
    macro_cmd_valid          <= 1'b1;
    @(posedge clk);
    macro_cmd_valid <= 1'b0;

    // Wait for done or timeout
    fork
      begin
        wait (done);
      end
      begin
        repeat (20000) @(posedge clk);
        $display("    TIMEOUT waiting for done (20000 cycles)");
      end
    join_any
    disable fork;
  endtask

  // ---- Golden model functions (use real for golden) ----

  function automatic void golden_matmul_2x2(
    input  real a00, a01, a10, a11,
    input  real b00, b01, b10, b11,
    output real c00, c01, c10, c11
  );
    c00 = a00*b00 + a01*b10;
    c01 = a00*b01 + a01*b11;
    c10 = a10*b00 + a11*b10;
    c11 = a10*b01 + a11*b11;
  endfunction

  function automatic real golden_gelu(input real x);
    real t;
    t = $tanh(0.7978845608 * (x + 0.044715 * x * x * x));
    return 0.5 * x * (1.0 + t);
  endfunction

  // ---- Main test sequence ----
  initial begin : main_test
    // All declarations at top of block
    real golden_fwd [4];
    real c00, c01, c10, c11;
    real result [4];
    int fwd_pass;
    int nonzero;
    real err;

    $display("=== tb_accel_top: START ===");
    clk = 0; rst_n = 0;
    macro_cmd_valid = 0;
    dma_wr_valid    = 0;
    dma_rd_req      = 0;
    macro_cmd_in    = '0;
    dma_wr_addr     = '0;
    dma_wr_data     = '0;
    dma_rd_addr     = '0;

    #20 rst_n = 1;
    #4;

    // ===========================================================
    // Test 1: FFN Forward smoke test
    // Write tiny 2x2 matrices A and B to SRAM, issue FFN_FWD
    // Check: start/done, SRAM load/store, GEMM + GELU path
    // ===========================================================
    $display("");
    $display("--- Test 1: FFN Forward Smoke Test ---");

    // Write A = [[1, 2], [3, 4]] at address 0x0000
    dma_write(16'h0000, 1.0);
    dma_write(16'h0001, 2.0);
    dma_write(16'h0002, 3.0);
    dma_write(16'h0003, 4.0);

    // Write B = [[5, 6], [7, 8]] at address 0x0100
    dma_write(16'h0100, 5.0);
    dma_write(16'h0101, 6.0);
    dma_write(16'h0102, 7.0);
    dma_write(16'h0103, 8.0);

    $display("  Data loaded to SRAM");

    // Compute golden result: C = GELU(A * B)
    // A = [[1,2],[3,4]], B = [[5,6],[7,8]]
    // A*B = [[19,22],[43,50]]
    golden_matmul_2x2(1.0, 2.0, 3.0, 4.0,
                       5.0, 6.0, 7.0, 8.0,
                       c00, c01, c10, c11);
    golden_fwd[0] = golden_gelu(c00);
    golden_fwd[1] = golden_gelu(c01);
    golden_fwd[2] = golden_gelu(c10);
    golden_fwd[3] = golden_gelu(c11);
    $display("  Golden GEMM*GELU: [%0.2f, %0.2f, %0.2f, %0.2f]",
             golden_fwd[0], golden_fwd[1], golden_fwd[2], golden_fwd[3]);

    // Issue FFN forward command (no aux for forward)
    issue_cmd(MODE_FFN_FWD, 16'h0000, 16'h0100, 16'h0000, 16'h0200, 8'd2, 8'd2, 8'd2);

    if (done)
      $display("  PASS: FFN forward completed (done asserted)");
    else
      $display("  FAIL: FFN forward did not complete");

    // Read back results from SRAM and compare against golden
    fwd_pass = 0;
    for (int i = 0; i < 4; i++)
      dma_read(16'h0200 + i[15:0], result[i]);
    $display("  Read back: [%0.2f, %0.2f, %0.2f, %0.2f]",
             result[0], result[1], result[2], result[3]);
    for (int i = 0; i < 4; i++) begin
      err = result[i] - golden_fwd[i];
      if (err < 0) err = -err;
      if (err < 1.0)
        fwd_pass++;
      else
        $display("  FAIL: element %0d: got %0.2f expected %0.2f", i, result[i], golden_fwd[i]);
    end
    if (fwd_pass == 4)
      $display("  PASS: all 4 output elements match golden model");
    else
      $display("  PARTIAL: %0d/4 elements match", fwd_pass);

    $display("  Perf: active=%0d stall=%0d tiles=%0d",
             perf_active, perf_stall, perf_tiles);

    repeat (5) @(posedge clk);

    // ===========================================================
    // Test 2: FFN Backward smoke test (TRUE FUSED BACKWARD)
    //   d_pre[r][c] = (A * B)[r][c] * GELU'(h_pre[r][c])
    // We pick h_pre values in the unsaturated regime (|h| < 3) so
    // GELU'(h_pre) is non-trivial and we can verify the multiply.
    // ===========================================================
    $display("");
    $display("--- Test 2: FFN Backward Smoke Test (fused: dh * GELU'(h_pre)) ---");

    // Load h_pre = [[0.5, 1.0], [1.5, 2.0]] at address 0x0500
    dma_write(16'h0500, 0.5);
    dma_write(16'h0501, 1.0);
    dma_write(16'h0502, 1.5);
    dma_write(16'h0503, 2.0);

    // Compute golden: c_out = A*B = [[19,22],[43,50]] (already known)
    //   d_pre[i] = c_out[i] * GELU'(h_pre[i])
    begin : golden_bwd_block
      real golden_bwd [4];
      real h [4];
      real gp;
      int  bwd_pass;

      h[0] = 0.5; h[1] = 1.0; h[2] = 1.5; h[3] = 2.0;
      // Re-derive c_out from the matmul golden helper
      golden_matmul_2x2(1.0, 2.0, 3.0, 4.0,
                        5.0, 6.0, 7.0, 8.0,
                        c00, c01, c10, c11);
      // GELU'(x) = 0.5*(1+tanh(z)) + 0.5*x*(1-tanh^2(z))*sqrt(2/pi)*(1+3*0.044715*x^2)
      //   simplified inline
      for (int i = 0; i < 4; i++) begin : g_loop
        real x, z, t, dt;
        x  = h[i];
        z  = 0.7978845608 * (x + 0.044715 * x * x * x);
        t  = $tanh(z);
        dt = 1.0 - t*t;
        gp = 0.5*(1.0+t) + 0.5*x*dt*0.7978845608*(1.0 + 3.0*0.044715*x*x);
        case (i)
          0: golden_bwd[0] = c00 * gp;
          1: golden_bwd[1] = c01 * gp;
          2: golden_bwd[2] = c10 * gp;
          3: golden_bwd[3] = c11 * gp;
        endcase
      end
      $display("  Golden d_pre: [%0.2f, %0.2f, %0.2f, %0.2f]",
               golden_bwd[0], golden_bwd[1], golden_bwd[2], golden_bwd[3]);

      issue_cmd(MODE_FFN_BWD, 16'h0000, 16'h0100, 16'h0500, 16'h0300, 8'd2, 8'd2, 8'd2);

      if (done)
        $display("  PASS: FFN backward completed (done asserted)");
      else
        $display("  FAIL: FFN backward did not complete");

      bwd_pass = 0;
      for (int i = 0; i < 4; i++)
        dma_read(16'h0300 + i[15:0], result[i]);
      $display("  Read back:    [%0.2f, %0.2f, %0.2f, %0.2f]",
               result[0], result[1], result[2], result[3]);
      // Tolerate ~10% error for the chained Q16.16 approximations
      for (int i = 0; i < 4; i++) begin : check_loop
        real e, tol;
        e   = result[i] - golden_bwd[i];
        if (e < 0) e = -e;
        tol = (golden_bwd[i] < 0 ? -golden_bwd[i] : golden_bwd[i]) * 0.10 + 1.0;
        if (e < tol) bwd_pass++;
        else $display("  FAIL: element %0d: got %0.2f expected %0.2f (err %0.2f)",
                       i, result[i], golden_bwd[i], e);
      end
      if (bwd_pass == 4)
        $display("  PASS: all 4 backward outputs match golden (within tolerance)");
      else
        $display("  PARTIAL: %0d/4 backward elements match", bwd_pass);
    end

    $display("  Perf: active=%0d stall=%0d tiles=%0d",
             perf_active, perf_stall, perf_tiles);

    repeat (5) @(posedge clk);

    // ===========================================================
    // Test 3: Attention smoke test
    // Reuse same data, issue ATTN_FWD
    // Check: GEMM + softmax/mask path, start/done
    // ===========================================================
    $display("");
    $display("--- Test 3: Attention Smoke Test ---");

    issue_cmd(MODE_ATTN_FWD, 16'h0000, 16'h0100, 16'h0000, 16'h0400, 8'd2, 8'd2, 8'd2);

    if (done)
      $display("  PASS: Attention forward completed (done asserted)");
    else
      $display("  FAIL: Attention forward did not complete");

    // Read back and check non-zero
    nonzero = 0;
    for (int i = 0; i < 4; i++)
      dma_read(16'h0400 + i[15:0], result[i]);
    $display("  Read back: [%0.2f, %0.2f, %0.2f, %0.2f]",
             result[0], result[1], result[2], result[3]);
    for (int i = 0; i < 4; i++)
      if (result[i] != 0.0) nonzero++;
    if (nonzero > 0)
      $display("  PASS: attention produced non-zero outputs (%0d/4)", nonzero);
    else
      $display("  FAIL: all outputs are zero");

    $display("  Perf: active=%0d stall=%0d tiles=%0d",
             perf_active, perf_stall, perf_tiles);

    repeat (5) @(posedge clk);

    // ===========================================================
    // Test 4: Multi-tile FFN forward (data-parallel across 2 lanes)
    //   X (2x2)  ·  [W1_0 | W1_1] (2x4)  =  [out_0 | out_1] (2x4)
    //   Two output tiles. Tile 0 goes to lane 0, tile 1 goes to lane 1.
    //   Lane 0 bank: X at local 0x0000, W1_0 at local 0x0100, out at 0x0200
    //   Lane 1 bank: X at local 0x0000, W1_1 at local 0x0180, out at 0x0200
    //     (W1_1 sits at addr_b + tile_k*64 = 0x100 + 0x80 = 0x180 because
    //      the dispatcher computes tile_b = addr_b + n_idx * tile_k * 64.)
    // ===========================================================
    $display("");
    $display("--- Test 4: Multi-tile FFN Forward (2 tiles, 2 lanes parallel) ---");
    begin : test4_block
      real bm00, bm01, bm10, bm11;
      real golden_t0 [4];
      real golden_t1 [4];
      real result0   [4];
      real result1   [4];
      int  pass0, pass1;
      real e;

      // Lane 0 bank (DMA addr < 0x1000):
      //   X at 0x0000-0x0003
      dma_write(16'h0000, 1.0); dma_write(16'h0001, 2.0);
      dma_write(16'h0002, 3.0); dma_write(16'h0003, 4.0);
      //   W1_0 = [[5,6],[7,8]] at 0x0100-0x0103
      dma_write(16'h0100, 5.0); dma_write(16'h0101, 6.0);
      dma_write(16'h0102, 7.0); dma_write(16'h0103, 8.0);

      // Lane 1 bank (DMA addr bit 12 = 1 -> 0x1xxx):
      //   X duplicated at 0x1000-0x1003
      dma_write(16'h1000, 1.0); dma_write(16'h1001, 2.0);
      dma_write(16'h1002, 3.0); dma_write(16'h1003, 4.0);
      //   W1_1 = [[9,10],[11,12]] at 0x1180-0x1183
      //   (lane 1 local 0x180 = addr_b + tile_k*64 from dispatcher)
      dma_write(16'h1180, 9.0);  dma_write(16'h1181, 10.0);
      dma_write(16'h1182, 11.0); dma_write(16'h1183, 12.0);

      // Golden tile 0: X * W1_0
      golden_matmul_2x2(1.0, 2.0, 3.0, 4.0,
                        5.0, 6.0, 7.0, 8.0,
                        c00, c01, c10, c11);
      golden_t0[0] = golden_gelu(c00); golden_t0[1] = golden_gelu(c01);
      golden_t0[2] = golden_gelu(c10); golden_t0[3] = golden_gelu(c11);

      // Golden tile 1: X * W1_1
      bm00 = 9.0; bm01 = 10.0; bm10 = 11.0; bm11 = 12.0;
      golden_matmul_2x2(1.0, 2.0, 3.0, 4.0,
                        bm00, bm01, bm10, bm11,
                        c00, c01, c10, c11);
      golden_t1[0] = golden_gelu(c00); golden_t1[1] = golden_gelu(c01);
      golden_t1[2] = golden_gelu(c10); golden_t1[3] = golden_gelu(c11);

      $display("  Golden tile 0: [%0.2f, %0.2f, %0.2f, %0.2f]",
               golden_t0[0], golden_t0[1], golden_t0[2], golden_t0[3]);
      $display("  Golden tile 1: [%0.2f, %0.2f, %0.2f, %0.2f]",
               golden_t1[0], golden_t1[1], golden_t1[2], golden_t1[3]);

      issue_macro(MODE_FFN_FWD,
                  16'h0000,   // addr_a
                  16'h0100,   // addr_b
                  16'h0000,   // addr_aux (unused)
                  16'h0200,   // addr_out
                  8'd1,       // num_m_tiles
                  8'd2,       // num_n_tiles
                  8'd2, 8'd2, 8'd2);

      if (done) $display("  PASS: macro completed (done asserted)");
      else      $display("  FAIL: macro did not complete");

      // Read tile 0 from lane 0 bank
      for (int i = 0; i < 4; i++)
        dma_read(16'h0200 + i[15:0], result0[i]);
      // Read tile 1 from lane 1 bank
      // dispatcher addr_out for tile (m=0, n=1) = 0x0200 + 1 * (64*64) = 0x1200
      for (int i = 0; i < 4; i++)
        dma_read(16'h1200 + i[15:0], result1[i]);

      $display("  Tile 0 read: [%0.2f, %0.2f, %0.2f, %0.2f]",
               result0[0], result0[1], result0[2], result0[3]);
      $display("  Tile 1 read: [%0.2f, %0.2f, %0.2f, %0.2f]",
               result1[0], result1[1], result1[2], result1[3]);

      pass0 = 0; pass1 = 0;
      for (int i = 0; i < 4; i++) begin
        e = result0[i] - golden_t0[i]; if (e < 0) e = -e;
        if (e < 1.0) pass0++;
      end
      for (int i = 0; i < 4; i++) begin
        e = result1[i] - golden_t1[i]; if (e < 0) e = -e;
        if (e < 1.0) pass1++;
      end
      if (pass0 == 4) $display("  PASS: tile 0 matches golden (4/4)");
      else            $display("  FAIL: tile 0 only %0d/4 match", pass0);
      if (pass1 == 4) $display("  PASS: tile 1 matches golden (4/4)");
      else            $display("  FAIL: tile 1 only %0d/4 match", pass1);

      $display("  Perf: active=%0d stall=%0d tiles=%0d",
               perf_active, perf_stall, perf_tiles);
    end

    // ===========================================================
    // Summary
    // ===========================================================
    $display("");
    $display("=== tb_accel_top: ALL TESTS DONE ===");
    $display("  Test 1 (FFN fwd):    golden model comparison");
    $display("  Test 2 (FFN bwd):    fused dh*GELU'(h_pre)");
    $display("  Test 3 (Attn fwd):   non-zero output check");
    $display("  Test 4 (Multi-tile): 2 lanes data-parallel");
    $display("  Check waveforms for detailed signal activity.");
    $finish;
  end

  // Watchdog timer
  initial begin
    #100000;
    $display("WATCHDOG: simulation timed out at 100us");
    $finish;
  end

endmodule
