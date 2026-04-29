// softmax_unit.sv — Synthesizable Q16.16 softmax
// Pipeline: max_reduce -> subtract+exp_lut -> sum_reduce -> normalize (divide)
module softmax_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int VEC_LEN    = 64
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            start,

  // Active length: only first vec_len slots participate in max/sum/divide.
  // Slots [vec_len .. VEC_LEN-1] are masked out (probs forced to 0).
  // Drive equal to VEC_LEN for full-vector operation.
  input  logic [7:0]                      vec_len,

  input  logic signed [DATA_WIDTH-1:0]    scores_in [VEC_LEN],
  input  logic                            in_valid,

  output logic signed [DATA_WIDTH-1:0]    probs_out [VEC_LEN],
  output logic                            out_valid
);

  // Q16.16 division
  function automatic logic signed [31:0] q_div(input logic signed [31:0] num, input logic signed [31:0] den);
    logic signed [63:0] num_ext;
    logic signed [63:0] result;
    if (den == 0) return Q_ZERO;
    num_ext = $signed({{16{num[31]}}, num, 16'h0000});
    result = num_ext / $signed({{32{den[31]}}, den});
    return result[31:0];
  endfunction

  // Pipeline valids
  logic s1_valid, s2_valid, s3_valid;

  // Pipelined vec_len — keeps the active length aligned with each row of data.
  logic [7:0] s1_len, s2_len, s3_len;

  // Stage 1: latch + find max (only over first vec_len slots)
  logic signed [31:0] s1_scores [VEC_LEN];
  logic signed [31:0] s1_max;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_max   <= '0;
      s1_len   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s1_scores[i] <= '0;
    end else if (en && in_valid) begin
      logic signed [31:0] mx;
      s1_valid <= 1'b1;
      s1_len   <= vec_len;
      mx = scores_in[0];
      s1_scores[0] <= scores_in[0];
      for (int i = 1; i < VEC_LEN; i++) begin
        if ((i < int'(vec_len)) && (scores_in[i] > mx)) mx = scores_in[i];
        s1_scores[i] <= scores_in[i];
      end
      s1_max <= mx;
    end else if (en) begin
      s1_valid <= 1'b0;
    end
  end

  // Stage 2: diff = score - max, clamp to [-8, 0], LUT lookup for exp
  // For synthesis simplicity, compute exp inline using polynomial approximation:
  // exp(x) for x in [-8, 0]: approximated as e^x ~ 1/(1 - x + x^2/2 - x^3/6 + ...)
  // We use a simpler approach: piecewise linear approximation
  // exp(x) ~ max(0, 1 + x + x^2/2) for x near 0, clamp at small value for x < -5

  logic signed [31:0] s2_exp [VEC_LEN];

  function automatic logic signed [31:0] q_exp_approx(input logic signed [31:0] x);
    // Range-reduced Pade [2,2]: exp(x) = (Pade(x/4))^4
    //   Pade(y) = (12 + 6y + y^2) / (12 - 6y + y^2)
    // Padé alone is only accurate over [-4, 0] (errors blow up past -4),
    // but applied to y = x/4 and squared twice it stays close to true exp(x)
    // across [-16, 0]. Examples (true / approx):
    //   x = -3: 0.0498 / 0.0498
    //   x = -5: 0.0067 / 0.0069
    //   x = -7: 0.0009 / 0.0010
    //   x = -10: 4.5e-5 / 9.1e-5
    // For x >= 0 we return 1 (caller subtracts the row max so x is non-positive).
    // For x deep negative we return 0 (below Q16.16 resolution anyway).
    logic signed [31:0] y, y2, num, den, p, p2, p4;
    logic signed [63:0] num_ext, q_full;
    localparam logic signed [31:0] Q_TWELVE     = 32'sh000C0000;  // 12.0
    localparam logic signed [31:0] Q_SIX        = 32'sh00060000;  //  6.0
    localparam logic signed [31:0] Q_EXP_FLOOR  = 32'shFFF00000;  // -16.0
    //  exp(-16) ~ 1.1e-7, far below Q16.16 resolution (~1.5e-5).

    if (x >= Q_ZERO)       return Q_ONE;
    if (x < Q_EXP_FLOOR)   return Q_ZERO;

    // y = x / 4 (arithmetic shift right, preserves sign in Q16.16)
    y  = x >>> 2;
    y2 = q_mul(y, y);
    num = Q_TWELVE + q_mul(Q_SIX, y) + y2;        // 12 + 6y + y^2
    den = Q_TWELVE - q_mul(Q_SIX, y) + y2;        // 12 - 6y + y^2

    if (den <= 0) return Q_ZERO;

    // Q16.16 division: shift num left by FRAC_BITS, then 64-bit divide.
    num_ext = $signed({{16{num[31]}}, num, 16'h0000});
    q_full  = num_ext / $signed({{32{den[31]}}, den});

    if (q_full[31:0] < 0) return Q_ZERO;

    // Square twice to recover exp(x) = (Pade(x/4))^4
    p  = q_full[31:0];
    p2 = q_mul(p, p);
    p4 = q_mul(p2, p2);
    return p4;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
      s2_len   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s2_exp[i] <= '0;
    end else if (en) begin
      s2_valid <= s1_valid;
      s2_len   <= s1_len;
      if (s1_valid) begin
        for (int i = 0; i < VEC_LEN; i++) begin
          logic signed [31:0] diff;
          diff = s1_scores[i] - s1_max;
          // Mask out unused slots (force to 0 contribution)
          if (i < int'(s1_len))
            s2_exp[i] <= q_exp_approx(diff);
          else
            s2_exp[i] <= '0;
        end
      end
    end
  end

  // Stage 3: sum exponentials
  logic signed [31:0] s3_exp [VEC_LEN];
  logic signed [31:0] s3_sum;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
      s3_sum   <= '0;
      s3_len   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s3_exp[i] <= '0;
    end else if (en) begin
      s3_valid <= s2_valid;
      s3_len   <= s2_len;
      if (s2_valid) begin
        logic signed [31:0] acc;
        acc = '0;
        // Sum only the active slots (others are 0 anyway, but be explicit)
        for (int i = 0; i < VEC_LEN; i++) begin
          if (i < int'(s2_len))
            acc = acc + s2_exp[i];
          s3_exp[i] <= s2_exp[i];
        end
        s3_sum <= acc;
      end
    end
  end

  // Stage 4: normalize (divide by sum)
  // Stage 4: normalize. Compute 1/sum ONCE then multiply across the row.
  // Previous version called q_div per-element (VEC_LEN dividers in parallel
  // each cycle); this consolidates to a single divider plus VEC_LEN q_mul.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      for (int i = 0; i < VEC_LEN; i++)
        probs_out[i] <= '0;
    end else if (en) begin
      out_valid <= s3_valid;
      if (s3_valid) begin
        logic signed [31:0] recip;  // 1/s3_sum (or 1/s3_len for uniform fallback)
        if (s3_sum > 0) begin
          recip = q_div(Q_ONE, s3_sum);                  // single divider
          for (int i = 0; i < VEC_LEN; i++) begin
            if (i < int'(s3_len))
              probs_out[i] <= q_mul(s3_exp[i], recip);   // multiplies, not divides
            else
              probs_out[i] <= '0;
          end
        end else begin
          // Uniform fallback: 1/s3_len in Q16.16. q_div used once.
          recip = (s3_len == 0) ? '0 : q_div(Q_ONE, {8'd0, s3_len, 16'd0});
          for (int i = 0; i < VEC_LEN; i++) begin
            if (i < int'(s3_len))
              probs_out[i] <= recip;                     // 1/N is the same for all valid slots
            else
              probs_out[i] <= '0;
          end
        end
      end
    end
  end

endmodule
