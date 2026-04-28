// gelu_unit.sv — Synthesizable Q16.16 GELU activation
// GELU(x) = 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
// tanh approximated via Pade: tanh(z) ~ z*(27+z^2)/(27+9*z^2), clamped to [-1, 1]
// Pipelined: 6 stages
module gelu_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,

  input  logic signed [DATA_WIDTH-1:0]    x_in,
  input  logic                            in_valid,
  output logic signed [DATA_WIDTH-1:0]    y_out,
  output logic                            out_valid
);

  // Q16.16 constants
  // 27 in Q16.16 = 27 * 65536 = 0x001B0000
  localparam logic signed [31:0] Q_27   = 32'sh001B0000;
  // 9 in Q16.16 = 9 * 65536 = 0x00090000
  localparam logic signed [31:0] Q_9    = 32'sh00090000;

  // Polynomial-input clamp: x^3 in Q16.16 overflows signed 32-bit when |x| >= 32
  // (32^3 * 65536 = 2^31). The polynomial output saturates at z=+/-4 well before
  // |x| reaches 5 anyway, so clamping the polynomial input to +/-16 is safe and
  // gives identical results in the saturated regime. We keep the ORIGINAL x in
  // s1_x for forwarding, since GELU(x_large) = x and GELU(x_neg_large) = 0 use
  // the original magnitude in the final multiply.
  localparam logic signed [31:0] Q_GELU_X_MAX = 32'sh00100000; //  16.0
  localparam logic signed [31:0] Q_GELU_X_MIN = 32'shFFF00000; // -16.0

  logic signed [31:0] x_for_poly;
  always_comb begin
    if (x_in > Q_GELU_X_MAX)      x_for_poly = Q_GELU_X_MAX;
    else if (x_in < Q_GELU_X_MIN) x_for_poly = Q_GELU_X_MIN;
    else                          x_for_poly = x_in;
  end

  // Stage 1: x^2, x^3 (computed from clamped value), forward original x
  logic signed [31:0] s1_x, s1_xp, s1_x2, s1_x3;
  logic               s1_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_x     <= '0;
      s1_xp    <= '0;
      s1_x2    <= '0;
      s1_x3    <= '0;
    end else if (en) begin
      s1_valid <= in_valid;
      if (in_valid) begin
        s1_x  <= x_in;          // original, for forwarding to final stage
        s1_xp <= x_for_poly;    // clamped, for polynomial
        s1_x2 <= q_mul(x_for_poly, x_for_poly);
        s1_x3 <= q_mul(q_mul(x_for_poly, x_for_poly), x_for_poly);
      end
    end
  end

  // Stage 2: tanh argument z = sqrt(2/pi) * (x + 0.044715 * x^3)
  logic signed [31:0] s2_x, s2_z;
  logic               s2_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
      s2_x     <= '0;
      s2_z     <= '0;
    end else if (en) begin
      s2_valid <= s1_valid;
      if (s1_valid) begin
        s2_x <= s1_x;
        // Use clamped x (s1_xp) for the polynomial; addition with the cubed
        // clamped term then stays within Q16.16 even when original x is large.
        s2_z <= q_mul(Q_SQRT_2_PI, s1_xp + q_mul(Q_GELU_C1, s1_x3));
      end
    end
  end

  // Stage 3: clamp z, compute z^2
  logic signed [31:0] s3_x, s3_z, s3_z2;
  logic               s3_valid;
  logic               s3_saturate_pos, s3_saturate_neg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
      s3_x     <= '0;
      s3_z     <= '0;
      s3_z2    <= '0;
      s3_saturate_pos <= 1'b0;
      s3_saturate_neg <= 1'b0;
    end else if (en) begin
      s3_valid <= s2_valid;
      if (s2_valid) begin
        s3_x <= s2_x;
        if (s2_z > Q_SAT_POS) begin
          s3_z <= Q_SAT_POS;
          s3_saturate_pos <= 1'b1;
          s3_saturate_neg <= 1'b0;
        end else if (s2_z < Q_SAT_NEG) begin
          s3_z <= Q_SAT_NEG;
          s3_saturate_pos <= 1'b0;
          s3_saturate_neg <= 1'b1;
        end else begin
          s3_z <= s2_z;
          s3_saturate_pos <= 1'b0;
          s3_saturate_neg <= 1'b0;
        end
        s3_z2 <= q_mul(s2_z, s2_z);
      end
    end
  end

  // Stage 4: numerator = z*(27+z^2), denominator = 27 + 9*z^2
  logic signed [31:0] s4_x, s4_num, s4_den;
  logic               s4_valid, s4_sat_pos, s4_sat_neg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s4_valid <= 1'b0;
      s4_x     <= '0;
      s4_num   <= '0;
      s4_den   <= Q_ONE; // avoid div by zero on reset
      s4_sat_pos <= 1'b0;
      s4_sat_neg <= 1'b0;
    end else if (en) begin
      s4_valid <= s3_valid;
      if (s3_valid) begin
        s4_x   <= s3_x;
        s4_num <= q_mul(s3_z, Q_27 + s3_z2);
        s4_den <= Q_27 + q_mul(Q_9, s3_z2);
        s4_sat_pos <= s3_saturate_pos;
        s4_sat_neg <= s3_saturate_neg;
      end
    end
  end

  // Stage 5: tanh = num / den (using lookup-style reciprocal-multiply)
  // For synthesis: use simple 1-pass Newton-Raphson reciprocal
  // Initial estimate: 1/den ~ 0x10000 / den_int (approximation)
  logic signed [31:0] s5_x, s5_tanh;
  logic               s5_valid;

  function automatic logic signed [31:0] q_div(input logic signed [31:0] num, input logic signed [31:0] den);
    logic signed [63:0] num_ext;
    logic signed [63:0] result;
    if (den == 0) return Q_ZERO;
    num_ext = $signed({{16{num[31]}}, num, 16'h0000}); // shift left by 16 for Q16.16 result
    result = num_ext / $signed({{32{den[31]}}, den});
    return result[31:0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s5_valid <= 1'b0;
      s5_x     <= '0;
      s5_tanh  <= '0;
    end else if (en) begin
      s5_valid <= s4_valid;
      if (s4_valid) begin
        s5_x <= s4_x;
        if (s4_sat_pos)
          s5_tanh <= Q_ONE;
        else if (s4_sat_neg)
          s5_tanh <= Q_NEG_ONE;
        else
          s5_tanh <= q_div(s4_num, s4_den);
      end
    end
  end

  // Stage 6: y = 0.5 * x * (1 + tanh)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      y_out     <= '0;
    end else if (en) begin
      out_valid <= s5_valid;
      if (s5_valid)
        y_out <= q_mul(Q_HALF, q_mul(s5_x, Q_ONE + s5_tanh));
    end
  end

endmodule
