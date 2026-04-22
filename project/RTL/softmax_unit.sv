// softmax_unit.sv — Attention softmax block
// Split into sub-stages: max_reduce → subtract → exp → sum_reduce → normalize
module softmax_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int VEC_LEN    = 64
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    en,
  input  logic                    start,

  input  logic [DATA_WIDTH-1:0]   scores_in [VEC_LEN],
  input  logic                    in_valid,

  output logic [DATA_WIDTH-1:0]   probs_out [VEC_LEN],
  output logic                    out_valid
);

  // Pipeline valid signals
  logic s1_valid, s2_valid, s3_valid;

  // Stage 1 registers
  logic [DATA_WIDTH-1:0] s1_scores [VEC_LEN];
  logic [DATA_WIDTH-1:0] s1_max;

  // Stage 2 registers
  logic [DATA_WIDTH-1:0] s2_exp [VEC_LEN];

  // Stage 3 registers
  logic [DATA_WIDTH-1:0] s3_exp [VEC_LEN];
  logic [DATA_WIDTH-1:0] s3_sum;

  // Stage 1: Latch inputs + find max
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else if (en) begin
      s1_valid <= in_valid;
      if (in_valid) begin
        shortreal mx;
        mx = $bitstoshortreal(scores_in[0]);
        s1_scores[0] <= scores_in[0];
        for (int i = 1; i < VEC_LEN; i++) begin
          shortreal v;
          v = $bitstoshortreal(scores_in[i]);
          if (v > mx) mx = v;
          s1_scores[i] <= scores_in[i];
        end
        s1_max <= $shortrealtobits(mx);
      end
    end
  end

  // Stage 2: Subtract max + exp
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
    end else if (en) begin
      s2_valid <= s1_valid;
      if (s1_valid) begin
        shortreal mx;
        mx = $bitstoshortreal(s1_max);
        for (int i = 0; i < VEC_LEN; i++) begin
          shortreal diff, e;
          diff = $bitstoshortreal(s1_scores[i]) - mx;
          e = $exp(diff);
          s2_exp[i] <= $shortrealtobits(e);
        end
      end
    end
  end

  // Stage 3: Sum exponentials
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
    end else if (en) begin
      s3_valid <= s2_valid;
      if (s2_valid) begin
        shortreal acc;
        acc = shortreal'(0.0);
        for (int i = 0; i < VEC_LEN; i++) begin
          acc = acc + $bitstoshortreal(s2_exp[i]);
          s3_exp[i] <= s2_exp[i];
        end
        s3_sum <= $shortrealtobits(acc);
      end
    end
  end

  // Stage 4: Normalize
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else if (en) begin
      out_valid <= s3_valid;
      if (s3_valid) begin
        shortreal sm;
        sm = $bitstoshortreal(s3_sum);
        if (sm > shortreal'(0.0)) begin
          for (int i = 0; i < VEC_LEN; i++) begin
            probs_out[i] <= $shortrealtobits($bitstoshortreal(s3_exp[i]) / sm);
          end
        end else begin
          // Avoid NaN: uniform distribution if sum is zero
          for (int i = 0; i < VEC_LEN; i++) begin
            probs_out[i] <= $shortrealtobits(shortreal'(1.0) / shortreal'(VEC_LEN));
          end
        end
      end
    end
  end

endmodule
