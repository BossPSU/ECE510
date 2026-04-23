// tb_accel_top.sv — Top-level smoke test TB
// 3 directed tests: FFN forward, FFN backward, Attention
// All tiny data, no randomization, golden model inline
`timescale 1ns/1ps

module tb_accel_top;
  import accel_pkg::*;

  logic        clk, rst_n;
  cmd_pkt_t    cmd_in;
  logic        cmd_valid, cmd_ready;
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
    .cmd_in               (cmd_in),
    .cmd_valid            (cmd_valid),
    .cmd_ready            (cmd_ready),
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

  // ---- Helper tasks ----

  // Write one FP32 value to scratchpad via DMA
  task automatic dma_write(input logic [15:0] addr, input shortreal val);
    @(posedge clk);
    dma_wr_valid <= 1'b1;
    dma_wr_addr  <= addr;
    dma_wr_data  <= $shortrealtobits(val);
    @(posedge clk);
    dma_wr_valid <= 1'b0;
    @(posedge clk); // wait for write to complete
  endtask

  // Read one FP32 value from scratchpad via DMA
  task automatic dma_read(input logic [15:0] addr, output shortreal val);
    @(posedge clk);
    dma_rd_req  <= 1'b1;
    dma_rd_addr <= addr;
    @(posedge clk);
    dma_rd_req <= 1'b0;
    @(posedge clk); // wait for read latency
    @(posedge clk);
    val = $bitstoshortreal(dma_rd_data);
  endtask

  // Issue a command and wait for done
  task automatic issue_cmd(input mode_t mode,
                           input logic [15:0] a, b, o,
                           input logic [7:0] tm, tn, tk);
    @(posedge clk);
    cmd_in.mode     <= mode;
    cmd_in.addr_a   <= a;
    cmd_in.addr_b   <= b;
    cmd_in.addr_out <= o;
    cmd_in.tile_m   <= tm;
    cmd_in.tile_n   <= tn;
    cmd_in.tile_k   <= tk;
    cmd_in.seq_len  <= 8'd4;
    cmd_valid       <= 1'b1;
    @(posedge clk);
    cmd_valid <= 1'b0;

    // Wait for done or timeout
    fork
      begin
        wait (done);
      end
      begin
        repeat (5000) @(posedge clk);
        $display("    TIMEOUT waiting for done");
      end
    join_any
    disable fork;
  endtask

  // ---- Golden model functions ----

  // Simple 2x2 matmul: C = A * B (fixed size, no dynamic arrays)
  function automatic void golden_matmul_2x2(
    input  shortreal a00, a01, a10, a11,
    input  shortreal b00, b01, b10, b11,
    output shortreal c00, c01, c10, c11
  );
    c00 = a00*b00 + a01*b10;
    c01 = a00*b01 + a01*b11;
    c10 = a10*b00 + a11*b10;
    c11 = a10*b01 + a11*b11;
  endfunction

  // Simple GELU
  function automatic shortreal golden_gelu(shortreal x);
    shortreal t;
    t = $tanh(0.7978845608 * (x + 0.044715 * x * x * x));
    return 0.5 * x * (1.0 + t);
  endfunction

  // Simple softmax
  function automatic void golden_softmax(
    input shortreal s[], output shortreal p[], input int len
  );
    shortreal mx, sm;
    mx = s[0];
    for (int i = 1; i < len; i++)
      if (s[i] > mx) mx = s[i];
    sm = 0.0;
    for (int i = 0; i < len; i++) begin
      p[i] = $exp(s[i] - mx);
      sm += p[i];
    end
    for (int i = 0; i < len; i++)
      p[i] = p[i] / sm;
  endfunction

  // ---- Main test sequence ----
  initial begin : main_test
    // All declarations at top of block
    shortreal golden_fwd [4];
    shortreal c00, c01, c10, c11;
    shortreal result [4];
    int fwd_pass;
    int nonzero;
    real err;

    $display("=== tb_accel_top: START ===");
    clk = 0; rst_n = 0;
    cmd_valid    = 0;
    dma_wr_valid = 0;
    dma_rd_req   = 0;
    cmd_in       = '0;
    dma_wr_addr  = '0;
    dma_wr_data  = '0;
    dma_rd_addr  = '0;

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

    // Issue FFN forward command
    issue_cmd(MODE_FFN_FWD, 16'h0000, 16'h0100, 16'h0200, 8'd2, 8'd2, 8'd2);

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
    // Test 2: FFN Backward smoke test
    // Reuse same data, issue FFN_BWD
    // Check: GEMM + GELU grad path, start/done handshake
    // ===========================================================
    $display("");
    $display("--- Test 2: FFN Backward Smoke Test ---");

    issue_cmd(MODE_FFN_BWD, 16'h0000, 16'h0100, 16'h0300, 8'd2, 8'd2, 8'd2);

    if (done)
      $display("  PASS: FFN backward completed (done asserted)");
    else
      $display("  FAIL: FFN backward did not complete");

    // Read back and check non-zero (basic sanity)
    nonzero = 0;
    for (int i = 0; i < 4; i++)
      dma_read(16'h0300 + i[15:0], result[i]);
    $display("  Read back: [%0.2f, %0.2f, %0.2f, %0.2f]",
             result[0], result[1], result[2], result[3]);
    for (int i = 0; i < 4; i++)
      if (result[i] != 0.0) nonzero++;
    if (nonzero > 0)
      $display("  PASS: backward produced non-zero outputs (%0d/4)", nonzero);
    else
      $display("  FAIL: all outputs are zero");

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

    issue_cmd(MODE_ATTN_FWD, 16'h0000, 16'h0100, 16'h0400, 8'd2, 8'd2, 8'd2);

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

    // ===========================================================
    // Summary
    // ===========================================================
    $display("");
    $display("=== tb_accel_top: ALL TESTS DONE ===");
    $display("  Test 1 (FFN fwd):  golden model comparison");
    $display("  Test 2 (FFN bwd):  non-zero output check");
    $display("  Test 3 (Attn fwd): non-zero output check");
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
