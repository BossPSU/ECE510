// gelu_grad_unit.sv — Synthesizable Q16.16 GELU gradient
// gelu'(x) = 0.5*(1+tanh(z)) + 0.5*x*(1-tanh^2(z))*sqrt(2/pi)*(1+3*0.044715*x^2)
// where z = sqrt(2/pi)*(x + 0.044715*x^3)
// tanh approximated via Pade, clamped
module gelu_grad_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,

  input  logic signed [DATA_WIDTH-1:0]    x_in,
  input  logic                            in_valid,
  output logic signed [DATA_WIDTH-1:0]    grad_out,
  output logic                            out_valid
);

  localparam logic signed [31:0] Q_27 = 32'sh001B0000;
  localparam logic signed [31:0] Q_9  = 32'sh00090000;

  function automatic logic signed [31:0] q_div(input logic signed [31:0] num, input logic signed [31:0] den);
    logic signed [63:0] num_ext;
    logic signed [63:0] result;
    if (den == 0) return Q_ZERO;
    num_ext = $signed({{16{num[31]}}, num, 16'h0000});
    result = num_ext / $signed({{32{den[31]}}, den});
    return result[31:0];
  endfunction

  // Stage 1: x^2, x^3
  logic signed [31:0] s1_x, s1_x2, s1_x3;
  logic               s1_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_x  <= '0; s1_x2 <= '0; s1_x3 <= '0;
    end else if (en) begin
      s1_valid <= in_valid;
      if (in_valid) begin
        s1_x  <= x_in;
        s1_x2 <= q_mul(x_in, x_in);
        s1_x3 <= q_mul(q_mul(x_in, x_in), x_in);
      end
    end
  end

  // Stage 2: z = sqrt(2/pi)*(x + 0.044715*x^3),  inner_grad_pre = 1 + 3*0.044715*x^2
  logic signed [31:0] s2_x, s2_z, s2_inner_pre;
  logic               s2_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
      s2_x <= '0; s2_z <= '0; s2_inner_pre <= '0;
    end else if (en) begin
      s2_valid <= s1_valid;
      if (s1_valid) begin
        s2_x         <= s1_x;
        s2_z         <= q_mul(Q_SQRT_2_PI, s1_x + q_mul(Q_GELU_C1, s1_x3));
        s2_inner_pre <= Q_ONE + q_mul(Q_GELU_C3, s1_x2);
      end
    end
  end

  // Stage 3: clamp z, compute z^2, inner = sqrt(2/pi) * inner_pre
  logic signed [31:0] s3_x, s3_z, s3_z2, s3_inner;
  logic               s3_valid, s3_sat_pos, s3_sat_neg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
      s3_x <= '0; s3_z <= '0; s3_z2 <= '0; s3_inner <= '0;
      s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b0;
    end else if (en) begin
      s3_valid <= s2_valid;
      if (s2_valid) begin
        s3_x     <= s2_x;
        s3_inner <= q_mul(Q_SQRT_2_PI, s2_inner_pre);
        if (s2_z > Q_SAT_POS) begin
          s3_z <= Q_SAT_POS;
          s3_sat_pos <= 1'b1; s3_sat_neg <= 1'b0;
        end else if (s2_z < Q_SAT_NEG) begin
          s3_z <= Q_SAT_NEG;
          s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b1;
        end else begin
          s3_z <= s2_z;
          s3_sat_pos <= 1'b0; s3_sat_neg <= 1'b0;
        end
        s3_z2 <= q_mul(s2_z, s2_z);
      end
    end
  end

  // Stage 4: tanh numerator/denominator
  logic signed [31:0] s4_x, s4_num, s4_den, s4_inner;
  logic               s4_valid, s4_sat_pos, s4_sat_neg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s4_valid <= 1'b0;
      s4_x <= '0; s4_num <= '0; s4_den <= Q_ONE; s4_inner <= '0;
      s4_sat_pos <= 1'b0; s4_sat_neg <= 1'b0;
    end else if (en) begin
      s4_valid <= s3_valid;
      if (s3_valid) begin
        s4_x     <= s3_x;
        s4_inner <= s3_inner;
        s4_num   <= q_mul(s3_z, Q_27 + s3_z2);
        s4_den   <= Q_27 + q_mul(Q_9, s3_z2);
        s4_sat_pos <= s3_sat_pos;
        s4_sat_neg <= s3_sat_neg;
      end
    end
  end

  // Stage 5: tanh = num/den, dtanh = 1 - tanh^2
  logic signed [31:0] s5_x, s5_tanh, s5_dtanh, s5_inner;
  logic               s5_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s5_valid <= 1'b0;
      s5_x <= '0; s5_tanh <= '0; s5_dtanh <= '0; s5_inner <= '0;
    end else if (en) begin
      s5_valid <= s4_valid;
      if (s4_valid) begin
        logic signed [31:0] tanh_val;
        s5_x     <= s4_x;
        s5_inner <= s4_inner;
        if (s4_sat_pos)      tanh_val = Q_ONE;
        else if (s4_sat_neg) tanh_val = Q_NEG_ONE;
        else                 tanh_val = q_div(s4_num, s4_den);
        s5_tanh  <= tanh_val;
        s5_dtanh <= Q_ONE - q_mul(tanh_val, tanh_val);
      end
    end
  end

  // Stage 6: grad = 0.5*(1+tanh) + 0.5*x*dtanh*inner
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      grad_out  <= '0;
    end else if (en) begin
      out_valid <= s5_valid;
      if (s5_valid) begin
        logic signed [31:0] term1, term2;
        term1 = q_mul(Q_HALF, Q_ONE + s5_tanh);
        term2 = q_mul(Q_HALF, q_mul(s5_x, q_mul(s5_dtanh, s5_inner)));
        grad_out <= term1 + term2;
      end
    end
  end

endmodule
