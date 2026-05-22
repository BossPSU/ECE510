/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// pipeline_stage.v -- hand-flattened from project/m2/rtl/pipeline_stage.sv
// Generic single-entry valid/ready register slice.
// =============================================================================
module pipeline_stage (
    clk,
    rst_n,
    in_data,
    in_valid,
    in_ready,
    out_data,
    out_valid,
    out_ready
);

    parameter DATA_WIDTH = 32;

    input  wire                   clk;
    input  wire                   rst_n;
    input  wire [DATA_WIDTH-1:0]  in_data;
    input  wire                   in_valid;
    output wire                   in_ready;
    output wire [DATA_WIDTH-1:0]  out_data;
    output wire                   out_valid;
    input  wire                   out_ready;

    reg [DATA_WIDTH-1:0] buf_data;
    reg                  buf_valid;

    assign in_ready  = !buf_valid || out_ready;
    assign out_data  = buf_data;
    assign out_valid = buf_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
            buf_data  <= {DATA_WIDTH{1'b0}};
        end else if (in_ready) begin
            buf_valid <= in_valid;
            buf_data  <= in_data;
        end
    end

endmodule
