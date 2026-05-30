/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// divider_or_reciprocal_seq.v -- hand-flattened from
// project/RTL/divider_or_reciprocal_seq.sv (M5)
//
// Drop-in port-compatible replacement for divider_or_reciprocal_unit.v
// (plus an explicit `ready` backpressure output). Replaces the 64-bit
// combinational `/` operator -- the chip's post-M4 critical path at
// ~65 ns -- with a 48-cycle iterative MSB-first shift-subtract divider.
//
// Per-cycle work is one 32-bit subtract + 1-bit shift = ~5 gate levels
// of combinational depth (~0.5 ns at TT). Bit-exact match to the legacy
// divider for inputs whose Q16.16 quotient fits in signed 32 bits (the
// softmax 1/sum use case).
//
// Hand-flatten conversions:
//   - dropped `import accel_pkg::*`; Q_ONE = 32'h00010000 inlined as
//     a 32-bit localparam.
//   - `enum` removed -- state is one bit (IDLE=0, BUSY=1).
//   - `logic` -> wire/reg with explicit direction.
//   - `always_ff` -> `always @(posedge clk or negedge rst_n)`.
//   - Temporaries (R_shifted, q_bit_next, Q_low_next) declared at
//     module scope; the (counter == 1) emit cycle uses them directly.
//   - N_ITER fixed at 48 (no parameterization in v_hand since OpenLane
//     reads top-down with the canonical parameter values).
// =============================================================================
module divider_or_reciprocal_seq (
    clk,
    rst_n,
    en,
    numerator,
    denominator,
    in_valid,
    ready,
    quotient,
    out_valid
);

    parameter DATA_WIDTH = 32;
    parameter N_ITER     = 48;

    localparam [31:0] Q_ONE = 32'h00010000;

    // 7-bit counter is sufficient for N_ITER <= 127.
    localparam COUNTER_W = 7;

    localparam S_IDLE = 1'b0;
    localparam S_BUSY = 1'b1;

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire signed [DATA_WIDTH-1:0]    numerator;
    input  wire signed [DATA_WIDTH-1:0]    denominator;
    input  wire                            in_valid;
    output wire                            ready;
    output reg  signed [DATA_WIDTH-1:0]    quotient;
    output reg                             out_valid;

    reg                state;
    reg [COUNTER_W-1:0] counter;
    reg [47:0]         U;            // working dividend, shifted left each cycle
    reg [31:0]         V;            // divisor magnitude
    reg [32:0]         R;            // working remainder (33 bits = 32 + carry slot)
    reg [31:0]         Q_low;        // low 32 bits of unsigned quotient
    reg                sign_neg;

    // Per-cycle BUSY temporaries (declared at module scope to avoid
    // any latch inference inside the always block).
    reg [32:0]         R_shifted;
    reg                q_bit_next;
    reg [31:0]         Q_low_next;

    assign ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            out_valid <= 1'b0;
            quotient  <= {DATA_WIDTH{1'b0}};
            counter   <= {COUNTER_W{1'b0}};
            U         <= 48'h0;
            V         <= 32'h0;
            R         <= 33'h0;
            Q_low     <= 32'h0;
            sign_neg  <= 1'b0;
            // R_shifted / q_bit_next / Q_low_next are combinational
            // scratchpads inside the S_BUSY branch; they're written
            // unconditionally there (blocking) and never read before
            // that point, so no reset assignment is needed. Adding
            // one would mix blocking + non-blocking writes to the same
            // reg, which Verilator flags as an unsupported pattern.
        end else if (en) begin
            out_valid <= 1'b0;       // 1-cycle pulse on completion
            if (state == S_IDLE) begin
                if (in_valid) begin
                    U <= {(numerator[DATA_WIDTH-1] ?
                            -numerator : numerator), 16'b0};
                    if (denominator == 32'h0) begin
                        V        <= Q_ONE;
                        sign_neg <= 1'b0;
                    end else begin
                        V        <= (denominator[DATA_WIDTH-1] ?
                                      -denominator : denominator);
                        sign_neg <= numerator[DATA_WIDTH-1] ^
                                    denominator[DATA_WIDTH-1];
                    end
                    R       <= 33'h0;
                    Q_low   <= 32'h0;
                    counter <= N_ITER[COUNTER_W-1:0];
                    state   <= S_BUSY;
                end
            end else begin
                // S_BUSY: one shift-subtract iteration per cycle.
                R_shifted  = {R[31:0], U[47]};
                if (R_shifted >= {1'b0, V}) begin
                    R          <= R_shifted - {1'b0, V};
                    q_bit_next  = 1'b1;
                end else begin
                    R          <= R_shifted;
                    q_bit_next  = 1'b0;
                end
                Q_low_next = {Q_low[30:0], q_bit_next};
                Q_low     <= Q_low_next;
                U         <= {U[46:0], 1'b0};

                if (counter == {{(COUNTER_W-1){1'b0}}, 1'b1}) begin
                    // Last iteration -- apply sign and emit.
                    state     <= S_IDLE;
                    out_valid <= 1'b1;
                    if (sign_neg)
                        quotient <= -$signed(Q_low_next);
                    else
                        quotient <=  $signed(Q_low_next);
                end else begin
                    counter <= counter - {{(COUNTER_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

endmodule
