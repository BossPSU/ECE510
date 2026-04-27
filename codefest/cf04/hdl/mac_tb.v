`timescale 1ns/1ps

module mac_tb;
    logic               clk;
    logic               rst;
    logic signed [7:0]  a;
    logic signed [7:0]  b;
    logic signed [31:0] out;

    mac dut (
        .clk (clk),
        .rst (rst),
        .a   (a),
        .b   (b),
        .out (out)
    );

    // 10 ns clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer i;

    initial begin
        $display("=== MAC Testbench ===");
        $display(" phase            | time(ns) | rst |   a |   b |        out");
        $display("------------------+----------+-----+-----+-----+-----------");

        // Hold reset for one cycle so accumulator starts at a known 0
        rst = 1'b1;
        a   = 8'sd0;
        b   = 8'sd0;
        @(posedge clk);
        #1;
        $display(" init reset       | %8t |  %0d  | %3d | %3d | %10d",
                 $time, rst, a, b, out);

        // Apply a=3, b=4 for 3 cycles with rst de-asserted
        rst = 1'b0;
        a   = 8'sd3;
        b   = 8'sd4;
        for (i = 1; i <= 3; i = i + 1) begin
            @(posedge clk);
            #1;
            $display(" a=3,b=4 cycle %0d  | %8t |  %0d  | %3d | %3d | %10d",
                     i, $time, rst, a, b, out);
        end

        // Assert rst for one cycle
        rst = 1'b1;
        @(posedge clk);
        #1;
        $display(" assert rst       | %8t |  %0d  | %3d | %3d | %10d",
                 $time, rst, a, b, out);

        // Apply a=-5, b=2 for 2 cycles with rst de-asserted
        rst = 1'b0;
        a   = -8'sd5;
        b   =  8'sd2;
        for (i = 1; i <= 2; i = i + 1) begin
            @(posedge clk);
            #1;
            $display(" a=-5,b=2 cycle %0d | %8t |  %0d  | %3d | %3d | %10d",
                     i, $time, rst, a, b, out);
        end

        $display("=== End of simulation ===");
        $finish;
    end

endmodule
