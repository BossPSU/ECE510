/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// stream_mux.v -- hand-flattened from project/m2/rtl/stream_mux.sv
// N-input -> 1-output stream selector with per-input ready feedback.
// Unpacked-array ports flattened to packed buses indexed by stream id.
// =============================================================================
module stream_mux (
    sel_valid,
    sel,
    in_data,
    in_valid,
    in_ready,
    out_data,
    out_valid,
    out_ready
);

    parameter DATA_WIDTH = 32;
    parameter NUM_INPUTS = 4;
    localparam SEL_W = clog2_f(NUM_INPUTS);

    input  wire                          sel_valid;
    input  wire [SEL_W-1:0]              sel;
    input  wire [(NUM_INPUTS*DATA_WIDTH)-1:0] in_data;
    input  wire [NUM_INPUTS-1:0]         in_valid;
    output reg  [NUM_INPUTS-1:0]         in_ready;
    output wire [DATA_WIDTH-1:0]         out_data;
    output wire                          out_valid;
    input  wire                          out_ready;

    assign out_data  = in_data[(sel*DATA_WIDTH) +: DATA_WIDTH];
    assign out_valid = sel_valid && in_valid[sel];

    integer i;
    always @* begin
        for (i = 0; i < NUM_INPUTS; i = i + 1)
            in_ready[i] = (sel == i) && out_ready && sel_valid;
    end

    function integer clog2_f;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2_f = 0;
            while (v > 0) begin v = v >> 1; clog2_f = clog2_f + 1; end
        end
    endfunction

endmodule
