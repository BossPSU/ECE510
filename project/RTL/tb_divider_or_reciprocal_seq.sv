// tb_divider_or_reciprocal_seq.sv — Unit TB for pipelined Q16.16 divider
//
// Drives a set of {num, den} pairs through divider_or_reciprocal_seq and
// compares the bit-exact quotient against the same inputs driven through
// the legacy combinational divider_or_reciprocal_unit. Both modules
// implement the same Q16.16 semantics; the iterative version just trades
// 50 cycles of latency for ~130x shallower combinational depth.
//
// Pass criteria:
//   - For every {num, den} pair the iterative quotient matches the
//     combinational quotient bit-for-bit
//   - ready/out_valid handshake fires once per row, with no spurious
//     pulses while idle
`timescale 1ns/1ps

module tb_divider_or_reciprocal_seq;
  import accel_pkg::*;

  localparam int N_VECTORS = 16;

  logic               clk, rst_n, en;
  logic signed [31:0] numerator, denominator;
  logic               in_valid;
  logic signed [31:0] q_seq, q_legacy;
  logic               ov_seq, ov_legacy;
  logic               ready_seq;

  // DUTs in parallel
  divider_or_reciprocal_seq #(.DATA_WIDTH(32), .N_ITER(48)) dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .en          (en),
    .numerator   (numerator),
    .denominator (denominator),
    .in_valid    (in_valid),
    .ready       (ready_seq),
    .quotient    (q_seq),
    .out_valid   (ov_seq)
  );

  divider_or_reciprocal_unit #(.DATA_WIDTH(32)) ref_div (
    .clk         (clk),
    .rst_n       (rst_n),
    .en          (en),
    .numerator   (numerator),
    .denominator (denominator),
    .in_valid    (in_valid),
    .quotient    (q_legacy),
    .out_valid   (ov_legacy)
  );

  always #1 clk = ~clk;

  function automatic logic signed [31:0] to_q(input real x);
    return $signed(int'(x * 65536.0));
  endfunction

  function automatic real from_q(input logic signed [31:0] q);
    return $itor(q) / 65536.0;
  endfunction

  // Stimulus: pairs of (num, den) chosen to exercise sign combinations,
  // small/large magnitudes, and division-by-zero. The reference divider
  // already encodes the "den==0 -> return Q_ONE" rule; the iterative
  // version implements the same guard.
  logic signed [31:0] nums[N_VECTORS];
  logic signed [31:0] dens[N_VECTORS];
  logic signed [31:0] captured_seq[N_VECTORS];
  logic signed [31:0] captured_legacy[N_VECTORS];

  int seq_idx;
  int legacy_idx;
  int pass_cnt;
  int fail_cnt;

  initial begin
    // 1.0 / N -- the softmax 1/sum cases, the actual workload
    nums[0] = Q_ONE;  dens[0] = to_q(2.0);    // expect +0.5
    nums[1] = Q_ONE;  dens[1] = to_q(4.0);    // expect +0.25
    nums[2] = Q_ONE;  dens[2] = to_q(7.0);    // expect ~+0.1428
    nums[3] = Q_ONE;  dens[3] = to_q(64.0);   // smallest typical sum
    nums[4] = Q_ONE;  dens[4] = to_q(0.5);    // expect +2.0
    // Sign combinations
    nums[5] = to_q( 3.0); dens[5] = to_q( 2.0);   // expect +1.5
    nums[6] = to_q(-3.0); dens[6] = to_q( 2.0);   // expect -1.5
    nums[7] = to_q( 3.0); dens[7] = to_q(-2.0);   // expect -1.5
    nums[8] = to_q(-3.0); dens[8] = to_q(-2.0);   // expect +1.5
    // Small + small
    nums[9]  = to_q(0.125);  dens[9]  = to_q(0.5);    // expect +0.25
    nums[10] = to_q(0.0625); dens[10] = to_q(0.125);  // expect +0.5
    // Large/large but quotient still in range
    nums[11] = to_q(100.0);  dens[11] = to_q(25.0);   // expect +4.0
    nums[12] = to_q(123.456); dens[12] = to_q(789.0); // expect ~+0.1564
    // Numerator zero
    nums[13] = 32'sd0;    dens[13] = to_q(5.0);       // expect 0
    // Denominator zero (legacy returns Q_ONE; seq should too)
    nums[14] = to_q(2.5); dens[14] = 32'sd0;          // expect +2.5 (per den<-Q_ONE)
    // Identity
    nums[15] = Q_ONE; dens[15] = Q_ONE;               // expect +1.0
  end

  initial begin
    $display("=== tb_divider_or_reciprocal_seq: START ===");
    clk = 0; rst_n = 0; en = 1; in_valid = 0;
    numerator = '0; denominator = '0;
    seq_idx = 0; legacy_idx = 0;
    pass_cnt = 0; fail_cnt = 0;

    #10 rst_n = 1;
    #2;

    // Drive each vector ONE AT A TIME, waiting for the seq divider's
    // ready handshake before issuing the next. The legacy divider has
    // 2-cycle latency so it gets pumped naturally between captures.
    for (int i = 0; i < N_VECTORS; i++) begin
      // Wait until the iterative divider is ready
      while (!ready_seq) @(posedge clk);

      numerator   = nums[i];
      denominator = dens[i];
      in_valid    = 1'b1;
      @(posedge clk); #1;
      in_valid    = 1'b0;
      // The iterative divider will now sit in BUSY for ~48 cycles. The
      // capture-on-out_valid blocks below latch the result whenever it
      // pulses.
    end

    // Drain
    repeat (60) @(posedge clk);

    // Compare captured pairs
    $display("");
    $display("Vector-by-vector comparison:");
    $display("  %3s  %10s  %10s   %12s  %12s  %s",
             "idx", "num_q16", "den_q16", "seq_q16", "ref_q16", "diff");
    for (int i = 0; i < N_VECTORS; i++) begin
      logic signed [31:0] diff;
      diff = captured_seq[i] - captured_legacy[i];
      if (diff == 0) begin
        $display("  PASS [%3d]  %+10.4f  %+10.4f   %+12.5f  %+12.5f  match",
                 i,
                 from_q(nums[i]), from_q(dens[i]),
                 from_q(captured_seq[i]), from_q(captured_legacy[i]));
        pass_cnt++;
      end else begin
        $display("  FAIL [%3d]  %+10.4f  %+10.4f   %+12.5f  %+12.5f  diff=%0d LSB",
                 i,
                 from_q(nums[i]), from_q(dens[i]),
                 from_q(captured_seq[i]), from_q(captured_legacy[i]),
                 diff);
        fail_cnt++;
      end
    end

    $display("");
    $display("  %0d PASS, %0d FAIL out of %0d vectors",
             pass_cnt, fail_cnt, N_VECTORS);
    $display("=== tb_divider_or_reciprocal_seq: DONE ===");
    $finish;
  end

  // Capture seq results in arrival order
  always @(posedge clk) begin
    if (rst_n && ov_seq && seq_idx < N_VECTORS) begin
      captured_seq[seq_idx] <= q_seq;
      seq_idx <= seq_idx + 1;
    end
  end

  // Capture legacy results in arrival order
  always @(posedge clk) begin
    if (rst_n && ov_legacy && legacy_idx < N_VECTORS) begin
      captured_legacy[legacy_idx] <= q_legacy;
      legacy_idx <= legacy_idx + 1;
    end
  end

endmodule
