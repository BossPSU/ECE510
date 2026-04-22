// softmax_unit.sv — Attention softmax block
// Split into sub-stages: max_reduce → subtract → exp → sum_reduce → normalize
module softmax_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int VEC_LEN    = 64   // sequence length per head
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    en,
  input  logic                    start,

  // Input: one row of scores
  input  logic [DATA_WIDTH-1:0]   scores_in [VEC_LEN],
  input  logic                    in_valid,

  // Output: normalized probabilities
  output logic [DATA_WIDTH-1:0]   probs_out [VEC_LEN],
  output logic                    out_valid
);

  // ---- Stage 1: Find max (comparator tree) ----
  logic [DATA_WIDTH-1:0] max_val;
  logic                  max_valid;

  // Combinational max-reduce
  always_comb begin
    shortreal m;
    m = $bitstoshortreal(scores_in[0]);
    for (int i = 1; i < VEC_LEN; i++) begin
      if ($bitstoshortreal(scores_in[i]) > m)
        m = $bitstoshortreal(scores_in[i]);
    end
    max_val = $shortrealtobits(m);
  end

  // Register max and input
  logic [DATA_WIDTH-1:0] s1_scores [VEC_LEN];
  logic [DATA_WIDTH-1:0] s1_max;
  logic                  s1_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s1_valid <= 1'b0;
    else if (en) begin
      s1_valid <= in_valid;
      s1_max   <= max_val;
      for (int i = 0; i < VEC_LEN; i++)
        s1_scores[i] <= scores_in[i];
    end
  end

  // ---- Stage 2: Subtract max + exp (via LUT) ----
  logic [DATA_WIDTH-1:0] s2_exp [VEC_LEN];
  logic                  s2_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s2_valid <= 1'b0;
    else if (en) begin
      s2_valid <= s1_valid;
      for (int i = 0; i < VEC_LEN; i++) begin
        shortreal diff;
        diff = $bitstoshortreal(s1_scores[i]) - $bitstoshortreal(s1_max);
        s2_exp[i] <= $shortrealtobits($exp(diff));
      end
    end
  end

  // ---- Stage 3: Sum exponentials ----
  logic [DATA_WIDTH-1:0] s3_exp [VEC_LEN];
  logic [DATA_WIDTH-1:0] s3_sum;
  logic                  s3_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s3_valid <= 1'b0;
    else if (en) begin
      s3_valid <= s2_valid;
      begin
        shortreal acc;
        acc = shortreal'(0.0);
        for (int i = 0; i < VEC_LEN; i++) begin
          acc += $bitstoshortreal(s2_exp[i]);
          s3_exp[i] <= s2_exp[i];
        end
        s3_sum <= $shortrealtobits(acc);
      end
    end
  end

  // ---- Stage 4: Normalize (divide by sum) ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) out_valid <= 1'b0;
    else if (en) begin
      out_valid <= s3_valid;
      for (int i = 0; i < VEC_LEN; i++) begin
        probs_out[i] <= $shortrealtobits(
          $bitstoshortreal(s3_exp[i]) / $bitstoshortreal(s3_sum)
        );
      end
    end
  end

endmodule
