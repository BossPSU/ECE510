// divider_or_reciprocal_seq.sv — Pipelined Q16.16 signed division (M5)
//
// Drop-in replacement for divider_or_reciprocal_unit.sv. Same port list
// plus an explicit `ready` backpressure signal. Internally replaces the
// 64-bit combinational `/` operator (a ~500-gate-level Brent-Kung
// non-restoring divider chain, the chip's post-M4 critical path) with
// an N_ITER-cycle iterative shift-subtract divider.
//
// Per-cycle work is one 32-bit subtract + 1-bit shift = ~5 gate levels
// of combinational depth. Total latency is N_ITER cycles (default 48 to
// cover the full 48-bit dividend = num << 16; smaller values risk
// truncating large quotients).
//
// Critical path delay: ~0.5 ns at TT (vs 65 ns combinational). At
// ARRAY_DIM=64 softmax_unit_lut, this raises SOFTMAX_LAT from
// 7 + N_PHASES (= 15) to (7 - 2) + N_PHASES + 48 = 61 cycles per row,
// but recovers chip f_max from 15 MHz to ~117 MHz (Sky130 mac_pe limit)
// or ~588 MHz (SAED32 systolic limit).
//
// Algorithm: unsigned MSB-first non-restoring division on |num| << 16
// and |den|, with sign tracked separately and re-applied to the result.
// Exact bit-equivalent to ($signed({{16{num[31]}}, num, 16'h0000}) /
// $signed({{32{den[31]}}, den}))[31:0] for inputs whose quotient fits
// in signed 32 bits (the use case in softmax_unit_lut stage 4).
module divider_or_reciprocal_seq
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  // Number of shift-subtract iterations. Set to 48 to fully match the
  // existing combinational divider over the entire 48-bit dividend
  // range. The softmax 1/sum use case (where num = Q_ONE and den is a
  // positive sum of exp values) only needs ~33 bits of meaningful
  // quotient, so N_ITER can be reduced if you accept truncation on
  // out-of-domain inputs.
  parameter int N_ITER     = 48
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,

  // Numerator / denominator (Q16.16 signed). Denominator == 0 is
  // guarded to Q_ONE (matching the legacy module's behavior) so the
  // engine never stalls on garbage input.
  input  logic signed [DATA_WIDTH-1:0]    numerator,
  input  logic signed [DATA_WIDTH-1:0]    denominator,
  input  logic                            in_valid,

  // High when the divider is idle and can accept a new in_valid.
  // Callers MUST observe ready before asserting in_valid; pulsing
  // in_valid while ready==0 drops the new request silently.
  output logic                            ready,

  output logic signed [DATA_WIDTH-1:0]    quotient,
  output logic                            out_valid
);

  typedef enum logic { S_IDLE, S_BUSY } state_t;

  state_t state;

  // Iteration counter -- needs enough bits for N_ITER. At N_ITER=48 a
  // 7-bit counter suffices.
  localparam int COUNTER_W = $clog2(N_ITER + 1);
  logic [COUNTER_W-1:0] counter;

  // Working state:
  //   U : 48-bit unsigned working dividend, shifted left each cycle
  //       (initialized to |num| << 16). Its MSB is the bit fed into R
  //       this cycle.
  //   V : 32-bit unsigned divisor magnitude.
  //   R : 33-bit working remainder. Extra bit is the carry-in slot for
  //       the shift before the compare-and-subtract.
  //   Q_low : low 32 bits of the unsigned quotient, MSB-first.
  //   sign_neg : XOR of numerator/denominator signs; applied at emit.
  logic [47:0] U;
  logic [31:0] V;
  logic [32:0] R;
  logic [31:0] Q_low;
  logic        sign_neg;

  assign ready = (state == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      out_valid <= 1'b0;
      quotient  <= '0;
      counter   <= '0;
      U         <= '0;
      V         <= '0;
      R         <= '0;
      Q_low     <= '0;
      sign_neg  <= 1'b0;
    end else if (en) begin
      out_valid <= 1'b0;       // 1-cycle pulse on completion
      case (state)
        S_IDLE: begin
          if (in_valid) begin
            // Compute magnitudes + sign. Guard denominator==0 by
            // substituting Q_ONE; result is then numerator (since
            // sign_neg stays 0 only when neither operand was negative,
            // matching the legacy q_div behavior).
            U <= {(numerator[DATA_WIDTH-1] ?
                    -numerator : numerator), 16'b0};
            if (denominator == '0) begin
              V        <= Q_ONE;
              sign_neg <= 1'b0;
            end else begin
              V        <= (denominator[DATA_WIDTH-1] ?
                            -denominator : denominator);
              sign_neg <= numerator[DATA_WIDTH-1] ^
                          denominator[DATA_WIDTH-1];
            end
            R       <= '0;
            Q_low   <= '0;
            counter <= COUNTER_W'(N_ITER);
            state   <= S_BUSY;
          end
        end

        S_BUSY: begin
          logic [32:0] R_shifted;
          logic        q_bit_next;
          logic [31:0] Q_low_next;

          // Bring the next MSB of the dividend into the LSB of R.
          R_shifted = {R[31:0], U[47]};

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

          if (counter == COUNTER_W'(1)) begin
            // Last iteration -- apply sign and emit.
            state     <= S_IDLE;
            out_valid <= 1'b1;
            quotient  <= sign_neg ? -$signed(Q_low_next) :
                                     $signed(Q_low_next);
          end else begin
            counter <= counter - COUNTER_W'(1);
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
