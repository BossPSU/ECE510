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

    gelu_unit #(
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

    gelu_grad_unit #(
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

    // 6-stage delay to align data_in with gelu_grad output for the
    // dh = dh_act * gelu_grad(h) elementwise multiply.
    localparam GRAD_DELAY = 6;
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

    // Output MUX
    always @* begin
        data_out  = 32'h0;
        out_valid = 1'b0;
        if (gelu_valid) begin
            data_out  = gelu_out;
            out_valid = 1'b1;
        end else if (gelu_grad_valid) begin
            data_out  = q_mul(data_delay[GRAD_DELAY-1], gelu_grad_out);
            out_valid = 1'b1;
        end else if (in_valid &&
                     ((op_sel == FUSED_BYPASS) || (op_sel == FUSED_MASK))) begin
            data_out  = data_in;
            out_valid = 1'b1;
        end
    end

endmodule
