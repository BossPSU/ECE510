/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// double_buffer_ctrl.v -- hand-flattened from project/m2/rtl/double_buffer_ctrl.sv
// Ping-pong base-address generator: one region for compute, the other for load.
// =============================================================================
module double_buffer_ctrl (
    clk,
    rst_n,
    swap,
    active_buf,
    compute_base,
    load_base
);

    parameter ADDR_WIDTH  = 16;
    parameter REGION_SIZE = 16'h1000;

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    swap;
    output reg                     active_buf;
    output wire [ADDR_WIDTH-1:0]   compute_base;
    output wire [ADDR_WIDTH-1:0]   load_base;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_buf <= 1'b0;
        else if (swap)
            active_buf <= ~active_buf;
    end

    assign compute_base = active_buf ? REGION_SIZE : {ADDR_WIDTH{1'b0}};
    assign load_base    = active_buf ? {ADDR_WIDTH{1'b0}} : REGION_SIZE;

endmodule
