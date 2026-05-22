/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// perf_counter_block.v -- hand-flattened from project/m2/rtl/perf_counter_block.sv
// Active / stall / total / tiles-completed counters.
// =============================================================================
module perf_counter_block (
    clk,
    rst_n,
    clear,
    array_active,
    array_stall,
    tile_complete,
    active_cycles,
    stall_cycles,
    total_cycles,
    tiles_completed
);

    input  wire        clk;
    input  wire        rst_n;
    input  wire        clear;
    input  wire        array_active;
    input  wire        array_stall;
    input  wire        tile_complete;
    output reg  [31:0] active_cycles;
    output reg  [31:0] stall_cycles;
    output reg  [31:0] total_cycles;
    output reg  [31:0] tiles_completed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_cycles   <= 32'h00000000;
            stall_cycles    <= 32'h00000000;
            total_cycles    <= 32'h00000000;
            tiles_completed <= 32'h00000000;
        end else if (clear) begin
            active_cycles   <= 32'h00000000;
            stall_cycles    <= 32'h00000000;
            total_cycles    <= 32'h00000000;
            tiles_completed <= 32'h00000000;
        end else begin
            total_cycles <= total_cycles + 32'd1;
            if (array_active)
                active_cycles <= active_cycles + 32'd1;
            if (array_stall)
                stall_cycles <= stall_cycles + 32'd1;
            if (tile_complete)
                tiles_completed <= tiles_completed + 32'd1;
        end
    end

endmodule
