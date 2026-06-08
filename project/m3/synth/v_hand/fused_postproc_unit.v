/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// fused_postproc_unit.v -- hand-flattened from
// project/m2/rtl/fused_postproc_unit.sv
//
// MUX over per-element activations: bypass / GELU / GELU' / mask. Softmax
// path is NOT included in this M2 design (it is handled in the streaming
// pipeline with the full vector); op_sel == FUSED_SOFTMAX falls through to
// the default 0 case here.
//
// Instantiates gelu_unit and gelu_grad_unit. fused_op_t encoding inlined.
// =============================================================================
module fused_postproc_unit (
    clk,
    rst_n,
    en,
    op_sel,
    data_in,
    in_valid,
    aux_in,
    data_out,
    out_valid
);

    parameter DATA_WIDTH = 32;

    // fused_op_t encoding from accel_pkg
    localparam [2:0] FUSED_BYPASS    = 3'd0;
    localparam [2:0] FUSED_GELU      = 3'd1;
    localparam [2:0] FUSED_GELU_GRAD = 3'd2;
    localparam [2:0] FUSED_SOFTMAX   = 3'd3;
    localparam [2:0] FUSED_MASK      = 3'd4;

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire [2:0]                      op_sel;
    input  wire signed [DATA_WIDTH-1:0]    data_in;
    input  wire                            in_valid;
    input  wire signed [DATA_WIDTH-1:0]    aux_in;
    output reg  signed [DATA_WIDTH-1:0]    data_out;
    output reg                             out_valid;

    function signed [31:0] q_mul;
        input signed [31:0] a;
        input signed [31:0] b;
        reg signed [63:0] product;
        begin
            product = $signed(a) * $signed(b);
            q_mul   = product[47:16];
        end
    endfunction

    wire signed [31:0] gelu_out;
    wire signed [31:0] gelu_grad_out;
    wire               gelu_valid;
    wire               gelu_grad_valid;

    // M4 Option B+linterp: 256-entry direct GELU / GELU' LUT with
    // linear interpolation. Drop-in port-compatible with the Pade
    // versions. 3-stage pipeline vs 6 for the Pade chain -- gelu output
    // arrives 3 cycles earlier, which the downstream data_delay tap
    // handles benignly (just earlier-than-expected gelu_valid).
    gelu_unit_lut #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_gelu (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (data_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU)),
        .y_out     (gelu_out),
        .out_valid (gelu_valid)
    );

    gelu_grad_unit_lut #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_gelu_grad (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (aux_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU_GRAD)),
        .grad_out  (gelu_grad_out),
        .out_valid (gelu_grad_valid)
    );

    // M3-verified fix (commit f7e8605): GRAD_DELAY must equal the
    // gelu_grad pipeline depth. v_hand instantiates gelu_grad_unit_lut
    // (4-stage after M6 Tier 2B), not the original Pade gelu_grad_unit
    // (6-stage). Was hardcoded to 6, which left data_delay[5] = 0 at
    // the cycle gelu_grad_valid pulsed -> q_mul collapsed to 0*grad_out
    // -> entire FFN_BWD path silently produced 0. Now 4 to match the
    // LUT pipeline.
    localparam GRAD_DELAY = 4;
    reg signed [31:0] data_delay [0:GRAD_DELAY-1];

    integer di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (di = 0; di < GRAD_DELAY; di = di + 1)
                data_delay[di] <= 32'h0;
        end else if (en) begin
            data_delay[0] <= data_in;
            for (di = 1; di < GRAD_DELAY; di = di + 1)
                data_delay[di] <= data_delay[di-1];
        end
    end

    // Combinational MUX (drives data_out_c / out_valid_c).
    reg signed [DATA_WIDTH-1:0] data_out_c;
    reg                         out_valid_c;
    always @* begin
        data_out_c  = 32'h0;
        out_valid_c = 1'b0;
        if (gelu_valid) begin
            data_out_c  = gelu_out;
            out_valid_c = 1'b1;
        end else if (gelu_grad_valid) begin
            data_out_c  = q_mul(data_delay[GRAD_DELAY-1], gelu_grad_out);
            out_valid_c = 1'b1;
        end else if (in_valid &&
                     ((op_sel == FUSED_BYPASS) || (op_sel == FUSED_MASK))) begin
            data_out_c  = data_in;
            out_valid_c = 1'b1;
        end
    end

    // M6 Tier 2A: output pipeline register. Cuts the
    // data_delay[5][12] -> q_mul -> output critical path that drove 71
    // Sky130 SS >5 ns violators on Attempt 9. Adds +1 cycle of latency;
    // caller's FUSED_DEPTH bumped to 9 (stream_pipeline.v).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= 32'h0;
            out_valid <= 1'b0;
        end else if (en) begin
            data_out  <= data_out_c;
            out_valid <= out_valid_c;
        end
    end

endmodule
