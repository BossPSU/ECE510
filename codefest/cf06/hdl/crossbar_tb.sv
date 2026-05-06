// crossbar_tb.sv — Testbench for the 4x4 binary-weight crossbar MAC
//
// Weights (1 = +1, 0 = -1):
//   row 0: [+1, -1, +1, -1]
//   row 1: [+1, +1, -1, -1]
//   row 2: [-1, +1, +1, -1]
//   row 3: [-1, -1, -1, +1]
//
// Inputs: in = [10, 20, 30, 40]
//
// Hand-calculated outputs  out[j] = sum_i w[i][j] * in[i]:
//   out[0] = (+1)(10) + (+1)(20) + (-1)(30) + (-1)(40) = -40
//   out[1] = (-1)(10) + (+1)(20) + (+1)(30) + (-1)(40) =   0
//   out[2] = (+1)(10) + (-1)(20) + (+1)(30) + (-1)(40) = -20
//   out[3] = (-1)(10) + (-1)(20) + (-1)(30) + (+1)(40) = -20

`timescale 1ns/1ps

module crossbar_tb;

    localparam int N     = 4;
    localparam int IN_W  = 8;
    localparam int OUT_W = 16;

    // -----------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------
    logic                       clk;
    logic                       rst_n;
    logic                       load_w;
    logic                       w_in     [N][N];
    logic signed [IN_W-1:0]     in_data  [N];
    logic signed [OUT_W-1:0]    out_data [N];

    crossbar_mac #(
        .N     (N),
        .IN_W  (IN_W),
        .OUT_W (OUT_W)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .load_w   (load_w),
        .w_in     (w_in),
        .in_data  (in_data),
        .out_data (out_data)
    );

    // -----------------------------------------------------------
    // 100 MHz clock
    // -----------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------
    // Expected results (hand-calculated)
    // -----------------------------------------------------------
    logic signed [OUT_W-1:0] expected [N];

    // -----------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------
    int errors;

    initial begin
        // VCD for waveform inspection
        $dumpfile("crossbar_tb.vcd");
        $dumpvars(0, crossbar_tb);

        // ------ init / reset ------
        rst_n  = 1'b0;
        load_w = 1'b0;
        for (int i = 0; i < N; i++) begin
            in_data[i] = '0;
            for (int j = 0; j < N; j++)
                w_in[i][j] = 1'b0;
        end

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ------ load weights (1 = +1, 0 = -1) ------
        // row 0: [+1, -1, +1, -1]
        w_in[0][0] = 1'b1; w_in[0][1] = 1'b0; w_in[0][2] = 1'b1; w_in[0][3] = 1'b0;
        // row 1: [+1, +1, -1, -1]
        w_in[1][0] = 1'b1; w_in[1][1] = 1'b1; w_in[1][2] = 1'b0; w_in[1][3] = 1'b0;
        // row 2: [-1, +1, +1, -1]
        w_in[2][0] = 1'b0; w_in[2][1] = 1'b1; w_in[2][2] = 1'b1; w_in[2][3] = 1'b0;
        // row 3: [-1, -1, -1, +1]
        w_in[3][0] = 1'b0; w_in[3][1] = 1'b0; w_in[3][2] = 1'b0; w_in[3][3] = 1'b1;

        load_w = 1'b1;
        @(posedge clk);
        load_w = 1'b0;

        // ------ apply inputs ------
        in_data[0] = 8'sd10;
        in_data[1] = 8'sd20;
        in_data[2] = 8'sd30;
        in_data[3] = 8'sd40;

        // expected, hand-calculated
        expected[0] = -16'sd40;
        expected[1] =  16'sd0;
        expected[2] = -16'sd20;
        expected[3] = -16'sd20;

        // outputs are registered; wait one clock for them to update
        @(posedge clk);
        #1;  // settle past NBA region

        // ------ report ------
        $display("---------------------------------------------------");
        $display(" 4x4 Binary-Weight Crossbar MAC — simulation result");
        $display("---------------------------------------------------");
        $display(" Inputs:  [%0d, %0d, %0d, %0d]",
                 in_data[0], in_data[1], in_data[2], in_data[3]);
        $display(" Weights (1 = +1, 0 = -1):");
        for (int i = 0; i < N; i++)
            $display("   row %0d: [%0b %0b %0b %0b]",
                     i, w_in[i][0], w_in[i][1], w_in[i][2], w_in[i][3]);

        errors = 0;
        $display(" Outputs:");
        for (int j = 0; j < N; j++) begin
            $display("   out[%0d] = %0d   expected = %0d   %s",
                     j, out_data[j], expected[j],
                     (out_data[j] === expected[j]) ? "PASS" : "FAIL");
            if (out_data[j] !== expected[j]) errors++;
        end

        $display("---------------------------------------------------");
        if (errors == 0)
            $display(" *** TEST PASSED ***");
        else
            $display(" *** TEST FAILED: %0d mismatch(es) ***", errors);
        $display("---------------------------------------------------");

        $finish;
    end

    // Watchdog
    initial begin
        #1000;
        $display("TIMEOUT — test did not finish");
        $finish;
    end

endmodule
