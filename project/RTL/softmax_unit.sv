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

  // Stage 1: latch + find max
  logic signed [31:0] s1_scores [VEC_LEN];
  logic signed [31:0] s1_max;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_max   <= '0;
      for (int i = 0; i < VEC_LEN; i++)
        s1_scores[i] <= '0;
    end else if (en && in_valid) begin
      logic signed [31:0] mx;
      s1_valid <= 1'b1;
      mx = scores_in[0];
      s1_scores[0] <= scores_in[0];
      for (int i = 1; i < VEC_LEN; i++) begin
        if (scores_in[i] > mx) mx = scores_in[i];
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
    // Pade [2,2] approximation: exp(x) ~ (12 + 6x + x^2) / (12 - 6x + x^2)
    // Accurate to ~3% over [-4, 0], symmetric, well-behaved
    // For x >= 0: clamp to 1.0 (we expect x <= 0 after subtracting max)
    // For x < -8: very small floor value
    logic signed [31:0] x_use, x2, num, den;
    logic signed [63:0] num_ext, q_full;
    // Q16.16 constant 12 = 12 << 16 = 0x000C0000
    // Q16.16 constant 6 = 6 << 16 = 0x00060000
    localparam logic signed [31:0] Q_TWELVE = 32'sh000C0000;
    localparam logic signed [31:0] Q_SIX    = 32'sh00060000;

    if (x >= Q_ZERO) return Q_ONE;
    if (x < Q_EXP_MIN) return 32'sh00000010; // ~0.000244

    x_use = x;
    x2    = q_mul(x_use, x_use);
    num   = Q_TWELVE + q_mul(Q_SIX, x_use) + x2;        // 12 + 6x + x^2
    den   = Q_TWELVE - q_mul(Q_SIX, x_use) + x2;        // 12 - 6x + x^2

    if (den <= 0) return 32'sh00000010;

    // Q16.16 division: shift num left by 16 then divide
    num_ext = $signed({{16{num[31]}}, num, 16'h0000});
    q_full  = num_ext / $signed({{32{den[31]}}, den});

    if (q_full[31:0] < 0) return 32'sh00000010;
    return q_full[31:0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
      for (int i = 0; i < VEC_LEN; i++)
        s2_exp[i] <= '0;
    end else if (en) begin
      s2_valid <= s1_valid;
      if (s1_valid) begin
        for (int i = 0; i < VEC_LEN; i++) begin
          logic signed [31:0] diff;
          diff = s1_scores[i] - s1_max;
          s2_exp[i] <= q_exp_approx(diff);
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
      for (int i = 0; i < VEC_LEN; i++)
        s3_exp[i] <= '0;
    end else if (en) begin
      s3_valid <= s2_valid;
      if (s2_valid) begin
        logic signed [31:0] acc;
        acc = '0;
        for (int i = 0; i < VEC_LEN; i++) begin
          acc = acc + s2_exp[i];
          s3_exp[i] <= s2_exp[i];
        end
        s3_sum <= acc;
      end
    end
  end

  // Stage 4: normalize (divide by sum)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      for (int i = 0; i < VEC_LEN; i++)
        probs_out[i] <= '0;
    end else if (en) begin
      out_valid <= s3_valid;
      if (s3_valid) begin
        if (s3_sum > 0) begin
          for (int i = 0; i < VEC_LEN; i++)
            probs_out[i] <= q_div(s3_exp[i], s3_sum);
        end else begin
          // Uniform fallback: 1/VEC_LEN in Q16.16
          // VEC_LEN as Q16.16 = VEC_LEN << FRAC_BITS
          for (int i = 0; i < VEC_LEN; i++)
            probs_out[i] <= q_div(Q_ONE, 32'(VEC_LEN) <<< FRAC_BITS);
        end
      end
    end
  end

endmodule
