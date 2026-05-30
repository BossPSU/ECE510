/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// mac_pe_piped.v -- hand-flattened from project/RTL/mac_pe_piped.sv (M5)
//
// Drop-in port-compatible variant of mac_pe.v with one extra pipeline
// register between the 8x8 Q4.4 multiplier output and the Q16.16
// alignment + accumulator add. Splits the leaf critical path in half:
// from ~50 gate levels combinational to ~25-30 per pipeline stage.
//
// Cost: +1 cycle of MAC latency. No throughput change -- the systolic
// array still issues one MAC per cycle; the new register uniformly
// delays each accumulation by 1 cycle, which propagates along the
// array. The drain-cycle count in stream_pipeline MUST be bumped by 1
// when this PE is used.
// =============================================================================
module mac_pe_piped (
    clk,
    rst_n,
    en,
    clear_acc,
    a_in,
    a_out,
    b_in,
    b_out,
    acc_out
);

    parameter DATA_WIDTH = 32;

    localparam MULT_W         = 8;
    localparam MULT_FRAC      = 4;
    localparam FRAC_BITS      = 16;
    localparam Q44_ALIGN_SH   = FRAC_BITS - MULT_FRAC;
    localparam Q88_PROMOTE_SH = FRAC_BITS - 2*MULT_FRAC;

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire                            clear_acc;

    input  wire signed [DATA_WIDTH-1:0]    a_in;
    output reg  signed [DATA_WIDTH-1:0]    a_out;

    input  wire signed [DATA_WIDTH-1:0]    b_in;
    output reg  signed [DATA_WIDTH-1:0]    b_out;

    output wire signed [DATA_WIDTH-1:0]    acc_out;

    // ----- Combinational stage 1: Q16.16 -> Q4.4 quantize + 8x8 mul -----
    wire signed [DATA_WIDTH-1:0] a_shifted;
    wire signed [DATA_WIDTH-1:0] b_shifted;
    wire signed [MULT_W-1:0]     a_q44;
    wire signed [MULT_W-1:0]     b_q44;

    assign a_shifted = a_in >>> Q44_ALIGN_SH;
    assign b_shifted = b_in >>> Q44_ALIGN_SH;

    assign a_q44 = (a_shifted >  32'sd127) ?  8'sd127 :
                   (a_shifted < -32'sd128) ? -8'sd128 :
                                              a_shifted[MULT_W-1:0];
    assign b_q44 = (b_shifted >  32'sd127) ?  8'sd127 :
                   (b_shifted < -32'sd128) ? -8'sd128 :
                                              b_shifted[MULT_W-1:0];

    wire signed [2*MULT_W-1:0] product_q88_comb;
    assign product_q88_comb = a_q44 * b_q44;

    // ----- NEW pipeline register: Q8.8 product + delayed clear_acc -----
    reg  signed [2*MULT_W-1:0] product_q88_r;
    reg                         clear_acc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_q88_r <= {(2*MULT_W){1'b0}};
            clear_acc_r   <= 1'b0;
        end else if (en) begin
            product_q88_r <= product_q88_comb;
            clear_acc_r   <= clear_acc;
        end
    end

    // ----- Combinational stage 2: Q8.8 -> Q16.16, accumulator update -----
    wire signed [DATA_WIDTH-1:0] product_q;
    assign product_q = {
        { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88_r[2*MULT_W-1]} },
        product_q88_r,
        { Q88_PROMOTE_SH{1'b0} }
    };

    // ----- Forwarding + accumulator registers -----
    reg signed [DATA_WIDTH-1:0] acc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            acc_r <= {DATA_WIDTH{1'b0}};
        end else if (en) begin
            // West/north forwarding stays 1-cycle (matches mac_pe.v).
            a_out <= a_in;
            b_out <= b_in;
            // Accumulator uses the registered product (1 cycle behind
            // inputs) and the registered clear_acc that aligns with it.
            if (clear_acc_r)
                acc_r <= {DATA_WIDTH{1'b0}};
            else
                acc_r <= acc_r + product_q;
        end
    end

    assign acc_out = acc_r;

endmodule
