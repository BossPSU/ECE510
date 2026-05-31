/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// mac_pe_piped4.v -- hand-flattened from project/RTL/mac_pe_piped4.sv (M5 option D)
//
// Drop-in port-compatible 4-stage MAC PE. Same Q4.4 mul + Q16.16 acc as
// mac_pe.v / mac_pe_piped.v; pipeline depth is the only difference.
//
//   Stage 1a:  in -> sat -> 8x4 partial mul (a * b[3:0])         -> [reg]
//   Stage 1b:  [reg] -> 8x4 partial mul (a * b[7:4]) + shift-add -> [reg]
//   Stage 2:   [reg] -> Q8.8 -> Q16.16 align + lower-16 acc add  -> [reg]
//   Stage 3:   [reg] -> upper-16 acc add with carry-in           -> [reg]
//
// Cost vs mac_pe.v: +3 cycles of MAC latency. clear_acc must be delayed
// 3 cycles to align with the Stage-3 accumulator add. stream_pipeline's
// DRAIN_CYCLES must be bumped to 7 (vs 4 legacy / 5 mac_pe_piped).
//
// West/north forwarding (a_out, b_out) stays 1-cycle (matches mac_pe.v
// and mac_pe_piped.v); systolic feed timing is independent of PE depth.
// =============================================================================
module mac_pe_piped4 (
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

    // ----- Combinational: Q16.16 -> Q4.4 quantize (no mul yet) -----
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

    // ----- Stage 1a comb: lower-nibble partial product (a * b[3:0]) -----
    // b[3:0] treated as unsigned; sign-extension applies via the upper
    // nibble term in Stage 1b.
    wire [3:0]         b_lo;
    wire signed [11:0] prod_lower_comb;
    assign b_lo            = b_q44[3:0];
    assign prod_lower_comb = a_q44 * $signed({1'b0, b_lo});

    // ----- Stage 1a register: partial product + forwarded operands -----
    reg signed [11:0]       prod_lower_r;
    reg signed [MULT_W-1:0] a_q44_r;
    reg signed [3:0]        b_hi_r;
    reg                     clear_acc_r1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_lower_r <= 12'sh0;
            a_q44_r      <= {MULT_W{1'b0}};
            b_hi_r       <= 4'sh0;
            clear_acc_r1 <= 1'b0;
        end else if (en) begin
            prod_lower_r <= prod_lower_comb;
            a_q44_r      <= a_q44;
            b_hi_r       <= b_q44[7:4];
            clear_acc_r1 <= clear_acc;
        end
    end

    // ----- Stage 1b comb: upper-nibble partial product + shift-add -----
    wire signed [11:0] prod_upper_comb;
    wire signed [15:0] product_q88_comb;

    assign prod_upper_comb  = a_q44_r * b_hi_r;
    assign product_q88_comb = ({{4{prod_upper_comb[11]}}, prod_upper_comb} <<< 4)
                            +  {{4{prod_lower_r[11]}},   prod_lower_r};

    // ----- Stage 1b register: full Q8.8 product -----
    reg signed [2*MULT_W-1:0] product_q88_r;
    reg                       clear_acc_r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_q88_r <= {(2*MULT_W){1'b0}};
            clear_acc_r2  <= 1'b0;
        end else if (en) begin
            product_q88_r <= product_q88_comb;
            clear_acc_r2  <= clear_acc_r1;
        end
    end

    // ----- Stage 2 comb: Q8.8 -> Q16.16 align + lower-16 acc add -----
    wire signed [DATA_WIDTH-1:0] product_q;
    assign product_q = {
        { (DATA_WIDTH - 2*MULT_W - Q88_PROMOTE_SH){product_q88_r[2*MULT_W-1]} },
        product_q88_r,
        { Q88_PROMOTE_SH{1'b0} }
    };

    // Pre-clear via operand path (so the carry/upper-add chain stays
    // straight). When clear_acc_r2 is high, both halves of acc are
    // treated as 0 for this iteration's add.
    wire [15:0] acc_lo_operand;
    wire [15:0] acc_hi_operand;
    wire [16:0] lo_sum_comb;

    assign acc_lo_operand = clear_acc_r2 ? 16'h0 : acc_r[15:0];
    assign acc_hi_operand = clear_acc_r2 ? 16'h0 : acc_r[31:16];
    assign lo_sum_comb    = {1'b0, acc_lo_operand} + {1'b0, product_q[15:0]};

    // ----- Stage 2 register: lo_sum + carry + upper-16 operands -----
    reg [15:0]        lo_sum_r;
    reg               carry_r;
    reg signed [15:0] product_hi_r;
    reg [15:0]        acc_hi_r2;
    reg               clear_acc_r3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lo_sum_r     <= 16'h0;
            carry_r      <= 1'b0;
            product_hi_r <= 16'sh0;
            acc_hi_r2    <= 16'h0;
            clear_acc_r3 <= 1'b0;
        end else if (en) begin
            lo_sum_r     <= lo_sum_comb[15:0];
            carry_r      <= lo_sum_comb[16];
            product_hi_r <= product_q[31:16];
            acc_hi_r2    <= acc_hi_operand;
            clear_acc_r3 <= clear_acc_r2;
        end
    end

    // ----- Stage 3 comb: upper-16 acc add with carry-in -----
    wire signed [15:0] hi_sum_comb;
    assign hi_sum_comb = product_hi_r
                       + $signed({15'h0, carry_r})
                       + $signed(acc_hi_r2);

    // ----- Stage 3 register: full accumulator + forwarding regs -----
    reg signed [DATA_WIDTH-1:0] acc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            acc_r <= {DATA_WIDTH{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
            if (clear_acc_r3)
                acc_r <= {DATA_WIDTH{1'b0}};
            else
                acc_r <= {hi_sum_comb, lo_sum_r};
        end
    end

    assign acc_out = acc_r;

endmodule
