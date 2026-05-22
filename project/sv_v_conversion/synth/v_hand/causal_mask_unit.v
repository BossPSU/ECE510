/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// causal_mask_unit.v -- hand-flattened from project/m2/rtl/causal_mask_unit.sv
//
// Applies a causal mask on a row of attention scores: positions where the
// column index exceeds the current row index get replaced with a large
// negative Q16.16 value so softmax assigns them ~0 probability.
//
// Port conversion: data_in/data_out unpacked arrays [VEC_LEN] are flattened
// to packed VEC_LEN*32-bit buses, LSB-aligned by column index.
// =============================================================================
module causal_mask_unit (
    data_in,
    row_idx,
    in_valid,
    data_out,
    out_valid
);

    parameter DATA_WIDTH = 32;
    parameter VEC_LEN    = 64;

    // Large negative Q16.16 (~ -32767.0) for masked-out positions
    localparam [DATA_WIDTH-1:0] NEG_INF = 32'h80010000;

    input  wire [(VEC_LEN*DATA_WIDTH)-1:0]  data_in;
    input  wire [7:0]                       row_idx;
    input  wire                             in_valid;
    output reg  [(VEC_LEN*DATA_WIDTH)-1:0]  data_out;
    output wire                             out_valid;

    assign out_valid = in_valid;

    integer c;
    always @* begin
        for (c = 0; c < VEC_LEN; c = c + 1) begin
            if (c > row_idx)
                data_out[(c*DATA_WIDTH) +: DATA_WIDTH] = NEG_INF;
            else
                data_out[(c*DATA_WIDTH) +: DATA_WIDTH] =
                    data_in[(c*DATA_WIDTH) +: DATA_WIDTH];
        end
    end

endmodule
