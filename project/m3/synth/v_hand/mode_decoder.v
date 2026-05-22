/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// mode_decoder.v -- hand-flattened from project/m2/rtl/mode_decoder.sv
//
// Decodes a host cmd_pkt_t (now received as a flat 99-bit bus) into the
// per-lane mode + fused_sel + dim_m/n/k + addr_a/b/out signals.
//
// cmd_pkt_t bit layout (LSB -> MSB), matching accel_pkg::cmd_pkt_t:
//   [  0 +:  3] mode       (3 bits)
//   [  3 +: 16] addr_a
//   [ 19 +: 16] addr_b
//   [ 35 +: 16] addr_aux
//   [ 51 +: 16] addr_out
//   [ 67 +:  8] tile_m
//   [ 75 +:  8] tile_n
//   [ 83 +:  8] tile_k
//   [ 91 +:  8] seq_len
// Total = 99 bits.
// =============================================================================
module mode_decoder (
    cmd,
    cmd_valid,
    mode,
    fused_sel,
    dim_m,
    dim_n,
    dim_k,
    addr_a,
    addr_b,
    addr_out,
    valid
);

    localparam CMD_W = 99;

    // mode_t encoding (accel_pkg enum)
    localparam [2:0] MODE_FFN_FWD  = 3'd0;
    localparam [2:0] MODE_FFN_BWD  = 3'd1;
    localparam [2:0] MODE_ATTN_FWD = 3'd2;
    localparam [2:0] MODE_ATTN_BWD = 3'd3;
    localparam [2:0] MODE_IDLE     = 3'd7;

    // fused_op_t encoding
    localparam [2:0] FUSED_BYPASS    = 3'd0;
    localparam [2:0] FUSED_GELU      = 3'd1;
    localparam [2:0] FUSED_GELU_GRAD = 3'd2;
    localparam [2:0] FUSED_SOFTMAX   = 3'd3;
    localparam [2:0] FUSED_MASK      = 3'd4;

    input  wire [CMD_W-1:0]  cmd;
    input  wire              cmd_valid;
    output wire [2:0]        mode;
    output reg  [2:0]        fused_sel;
    output wire [7:0]        dim_m;
    output wire [7:0]        dim_n;
    output wire [7:0]        dim_k;
    output wire [15:0]       addr_a;
    output wire [15:0]       addr_b;
    output wire [15:0]       addr_out;
    output wire              valid;

    assign valid    = cmd_valid;
    assign mode     = cmd[2:0];
    assign addr_a   = cmd[3 +: 16];
    assign addr_b   = cmd[19 +: 16];
    // (addr_aux at [35 +: 16] not surfaced here -- the M2 SV header
    //  omitted it as well; consumer of cmd_pkt_t uses it directly.)
    assign addr_out = cmd[51 +: 16];
    assign dim_m    = cmd[67 +: 8];
    assign dim_n    = cmd[75 +: 8];
    assign dim_k    = cmd[83 +: 8];

    always @* begin
        case (mode)
            MODE_FFN_FWD:  fused_sel = FUSED_GELU;
            MODE_FFN_BWD:  fused_sel = FUSED_GELU_GRAD;
            MODE_ATTN_FWD: fused_sel = FUSED_SOFTMAX;
            MODE_ATTN_BWD: fused_sel = FUSED_BYPASS;
            default:       fused_sel = FUSED_BYPASS;
        endcase
    end

endmodule
