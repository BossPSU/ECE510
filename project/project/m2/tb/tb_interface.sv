// =============================================================================
// tb_interface.sv -- Testbench for chiplet_interface (interface.sv)
// =============================================================================
//
// Tests:
//   1. Command-channel write: drives a packed macro_cmd_t over ucie_cmd_data,
//      verifies the unpacked struct on the core side matches every field.
//   2. Data write transaction: drives ucie_wr_valid + packed {addr, data},
//      verifies core_dma_wr_addr / core_dma_wr_data with a full handshake.
//   3. Data read response: drives ucie_rd_req with an address, returns mock
//      data on the core_dma_rd_data side, verifies it forwards to ucie_rd_data
//      with ucie_rd_valid.
//   4. Status pass-through: core_busy / core_irq -> ucie_busy / ucie_irq.
//
// Reference values are computed inline in SV (no DUT-derived expected values).
// Final line is "TB_INTERFACE: PASS" or "TB_INTERFACE: FAIL".
// =============================================================================
`timescale 1ns/1ps

module tb_interface;
  import accel_pkg::*;

  localparam int LANE_BITS_TB = $clog2(16);
  localparam int DMA_AW_TB    = LANE_LOCAL_W + LANE_BITS_TB;
  localparam int CMD_BUS_W    = 128;
  localparam int WR_BUS_W     = DMA_AW_TB + 32;

  logic                 clk, rst_n;

  // UCIe-side ports
  logic                 ucie_cmd_valid, ucie_cmd_ready;
  logic [CMD_BUS_W-1:0] ucie_cmd_data;
  logic                 ucie_wr_valid,  ucie_wr_ready;
  logic [WR_BUS_W-1:0]  ucie_wr_data;
  logic                 ucie_rd_req;
  logic [DMA_AW_TB-1:0] ucie_rd_addr;
  logic [31:0]          ucie_rd_data;
  logic                 ucie_rd_valid;
  logic                 ucie_irq, ucie_busy;

  // Core-side ports (driven from this TB to model the compute_core)
  macro_cmd_t           core_macro_cmd;
  logic                 core_macro_cmd_valid;
  logic                 core_macro_cmd_ready;
  logic                 core_dma_wr_valid;
  logic [DMA_AW_TB-1:0] core_dma_wr_addr;
  logic [31:0]          core_dma_wr_data;
  logic                 core_dma_wr_ready;
  logic                 core_dma_rd_req;
  logic [DMA_AW_TB-1:0] core_dma_rd_addr;
  logic [31:0]          core_dma_rd_data;
  logic                 core_dma_rd_valid;
  logic                 core_busy, core_irq;

  chiplet_interface dut (
    .clk                  (clk),
    .rst_n                (rst_n),
    .ucie_cmd_valid       (ucie_cmd_valid),
    .ucie_cmd_ready       (ucie_cmd_ready),
    .ucie_cmd_data        (ucie_cmd_data),
    .ucie_wr_valid        (ucie_wr_valid),
    .ucie_wr_ready        (ucie_wr_ready),
    .ucie_wr_data         (ucie_wr_data),
    .ucie_rd_req          (ucie_rd_req),
    .ucie_rd_addr         (ucie_rd_addr),
    .ucie_rd_data         (ucie_rd_data),
    .ucie_rd_valid        (ucie_rd_valid),
    .ucie_irq             (ucie_irq),
    .ucie_busy            (ucie_busy),
    .core_macro_cmd       (core_macro_cmd),
    .core_macro_cmd_valid (core_macro_cmd_valid),
    .core_macro_cmd_ready (core_macro_cmd_ready),
    .core_dma_wr_valid    (core_dma_wr_valid),
    .core_dma_wr_addr     (core_dma_wr_addr),
    .core_dma_wr_data     (core_dma_wr_data),
    .core_dma_wr_ready    (core_dma_wr_ready),
    .core_dma_rd_req      (core_dma_rd_req),
    .core_dma_rd_addr     (core_dma_rd_addr),
    .core_dma_rd_data     (core_dma_rd_data),
    .core_dma_rd_valid    (core_dma_rd_valid),
    .core_busy            (core_busy),
    .core_irq             (core_irq)
  );

  always #1 clk = ~clk;

  int test_failures = 0;

  task automatic check_eq_int(input string label, input int got, input int exp);
    if (got !== exp) begin
      $display("  FAIL: %s: got 0x%0h expected 0x%0h", label, got, exp);
      test_failures++;
    end
  endtask

  initial begin : main_test
    macro_cmd_t expected_cmd;
    logic [DMA_AW_TB-1:0] test_addr;
    logic [31:0]          test_data;
    logic [WR_BUS_W-1:0]  packed_wr;
    int timeout;

    $display("=== tb_interface: START ===");

    clk = 0; rst_n = 0;
    ucie_cmd_valid = 0; ucie_cmd_data  = '0;
    ucie_wr_valid  = 0; ucie_wr_data   = '0;
    ucie_rd_req    = 0; ucie_rd_addr   = '0;
    core_macro_cmd_ready = 1'b1;     // core always accepts
    core_dma_wr_ready    = 1'b1;
    core_dma_rd_data     = '0;
    core_dma_rd_valid    = 1'b0;
    core_busy            = 1'b0;
    core_irq             = 1'b0;

    #10 rst_n = 1;
    #4;

    // ===========================================================
    // Test 1: command channel — drive packed macro_cmd, verify unpack
    // ===========================================================
    $display("");
    $display("--- Test 1: UCIe command channel unpack ---");
    expected_cmd.mode        = MODE_FFN_FWD;
    expected_cmd.addr_a      = 16'h1234;
    expected_cmd.addr_b      = 16'h5678;
    expected_cmd.addr_aux    = 16'h9ABC;
    expected_cmd.addr_out    = 16'hDEF0;
    expected_cmd.num_m_tiles = 8'd2;
    expected_cmd.num_n_tiles = 8'd4;
    expected_cmd.tile_m      = 8'd64;
    expected_cmd.tile_n      = 8'd64;
    expected_cmd.tile_k      = 8'd64;

    @(posedge clk);
    ucie_cmd_data  <= {{(CMD_BUS_W-$bits(macro_cmd_t)){1'b0}}, expected_cmd};
    ucie_cmd_valid <= 1'b1;
    @(posedge clk);
    // Combinational unpack — sample immediately after edge
    #1;
    check_eq_int("cmd.mode",        int'(core_macro_cmd.mode),        int'(expected_cmd.mode));
    check_eq_int("cmd.addr_a",      int'(core_macro_cmd.addr_a),      int'(expected_cmd.addr_a));
    check_eq_int("cmd.addr_b",      int'(core_macro_cmd.addr_b),      int'(expected_cmd.addr_b));
    check_eq_int("cmd.addr_aux",    int'(core_macro_cmd.addr_aux),    int'(expected_cmd.addr_aux));
    check_eq_int("cmd.addr_out",    int'(core_macro_cmd.addr_out),    int'(expected_cmd.addr_out));
    check_eq_int("cmd.num_m_tiles", int'(core_macro_cmd.num_m_tiles), int'(expected_cmd.num_m_tiles));
    check_eq_int("cmd.num_n_tiles", int'(core_macro_cmd.num_n_tiles), int'(expected_cmd.num_n_tiles));
    check_eq_int("cmd.tile_m",      int'(core_macro_cmd.tile_m),      int'(expected_cmd.tile_m));
    check_eq_int("cmd.tile_n",      int'(core_macro_cmd.tile_n),      int'(expected_cmd.tile_n));
    check_eq_int("cmd.tile_k",      int'(core_macro_cmd.tile_k),      int'(expected_cmd.tile_k));
    if (!core_macro_cmd_valid) begin
      $display("  FAIL: core_macro_cmd_valid did not propagate");
      test_failures++;
    end
    if (!ucie_cmd_ready) begin
      $display("  FAIL: ucie_cmd_ready did not assert (core_macro_cmd_ready=1)");
      test_failures++;
    end
    @(posedge clk);
    ucie_cmd_valid <= 1'b0;
    $display("  PASS: command unpack covered all 10 fields");

    // ===========================================================
    // Test 2: full write-channel handshake (lane 3, slot 1, offset 0x0080)
    // ===========================================================
    $display("");
    $display("--- Test 2: UCIe data-write channel handshake ---");
    test_addr = {LANE_BITS_TB'(3), LANE_LOCAL_W'(16'h4080)};   // lane 3, local 0x4080
    test_data = 32'hCAFEBABE;
    packed_wr = {test_addr, test_data};

    @(posedge clk);
    ucie_wr_data  <= packed_wr;
    ucie_wr_valid <= 1'b1;
    @(posedge clk);
    #1;
    check_eq_int("wr.addr",  int'(core_dma_wr_addr), int'(test_addr));
    check_eq_int("wr.data",  int'(core_dma_wr_data), int'(test_data));
    if (!core_dma_wr_valid)  begin $display("  FAIL: core_dma_wr_valid"); test_failures++; end
    if (!ucie_wr_ready)      begin $display("  FAIL: ucie_wr_ready");     test_failures++; end
    @(posedge clk);
    ucie_wr_valid <= 1'b0;
    $display("  PASS: write handshake forwarded addr=0x%0h data=0x%0h",
             core_dma_wr_addr, core_dma_wr_data);

    // ===========================================================
    // Test 3: read-channel response
    // ===========================================================
    $display("");
    $display("--- Test 3: UCIe data-read channel response ---");
    test_addr = {LANE_BITS_TB'(7), LANE_LOCAL_W'(16'h0200)};
    @(posedge clk);
    ucie_rd_req  <= 1'b1;
    ucie_rd_addr <= test_addr;
    @(posedge clk);
    #1;
    check_eq_int("rd.addr_passthrough", int'(core_dma_rd_addr), int'(test_addr));
    if (!core_dma_rd_req) begin $display("  FAIL: core_dma_rd_req"); test_failures++; end
    @(posedge clk);
    ucie_rd_req <= 1'b0;

    // Model scratchpad returning the data 1 cycle later
    @(posedge clk);
    core_dma_rd_data  <= 32'hDEADBEEF;
    core_dma_rd_valid <= 1'b1;
    @(posedge clk);
    #1;
    check_eq_int("rd.data",  int'(ucie_rd_data),  32'hDEADBEEF);
    if (!ucie_rd_valid) begin $display("  FAIL: ucie_rd_valid"); test_failures++; end
    @(posedge clk);
    core_dma_rd_data  <= '0;
    core_dma_rd_valid <= 1'b0;
    $display("  PASS: read response forwarded data=0x%0h", ucie_rd_data);

    // ===========================================================
    // Test 4: status pass-through
    // ===========================================================
    $display("");
    $display("--- Test 4: status / IRQ pass-through ---");
    @(posedge clk);
    core_busy <= 1'b1;
    core_irq  <= 1'b0;
    @(posedge clk);
    #1;
    if (ucie_busy !== 1'b1) begin $display("  FAIL: busy didn't propagate"); test_failures++; end
    if (ucie_irq  !== 1'b0) begin $display("  FAIL: irq stuck high");        test_failures++; end
    @(posedge clk);
    core_busy <= 1'b0;
    core_irq  <= 1'b1;
    @(posedge clk);
    #1;
    if (ucie_busy !== 1'b0) begin $display("  FAIL: busy stuck high");      test_failures++; end
    if (ucie_irq  !== 1'b1) begin $display("  FAIL: irq didn't propagate"); test_failures++; end
    @(posedge clk);
    core_irq <= 1'b0;
    $display("  PASS: busy and irq propagate in both directions");

    // ===========================================================
    // Final summary
    // ===========================================================
    $display("");
    $display("=== tb_interface: ALL TESTS DONE ===");
    if (test_failures == 0)
      $display("=== TB_INTERFACE: PASS ===");
    else
      $display("=== TB_INTERFACE: FAIL (%0d failure(s)) ===", test_failures);
    $finish;
  end

  // Watchdog
  initial begin
    #10000;
    $display("WATCHDOG: simulation timed out at 10us");
    $display("=== TB_INTERFACE: FAIL (timeout) ===");
    $finish;
  end

endmodule
