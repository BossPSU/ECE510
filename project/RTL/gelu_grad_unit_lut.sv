// gelu_grad_unit_lut.sv — LUT-based Q16.16 GELU derivative (M4 update)
//
// Drop-in replacement for gelu_grad_unit.sv. Same port list, same Q16.16
// numerical contract. Same architecture as gelu_unit_lut: 256-entry
// direct GELU'(x) ROM with adjacent-entry linear interpolation;
// 3-cycle pipeline (vs 6 for the Pade chain it replaces).
//
// Saturation tails for GELU':
//   x -> -inf : GELU'(x) -> 0       (clamp negative side to 0)
//   x -> +inf : GELU'(x) -> 1       (clamp positive side to 1)
// At the LUT range boundary the natural ROM values already give
// GELU'(-4) ~= -5e-4 and GELU'(+3.97) ~= 1.0006, so the explicit
// saturation override is mostly a cosmetic clamp -- but it keeps
// the upstream value exact and avoids accumulating LUT noise in
// downstream products.
module gelu_grad_unit_lut
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

  // Q16.16 constants
  localparam logic signed [31:0] Q_FOUR        = 32'sh00040000;  //  +4.0
  localparam logic signed [31:0] Q_NEG_FOUR    = 32'shFFFC0000;  //  -4.0
  localparam logic signed [31:0] Q_FOUR_MINUS1 = 32'sh0003FFFF;

  // ---------------------------------------------------------------------
  // Stage 1: clamp, address generation, fractional position
  // ---------------------------------------------------------------------
  logic                       s1_valid;
  logic [7:0]                 s1_addr_lo;
  logic [7:0]                 s1_addr_hi;
  logic signed [31:0]         s1_frac_q16;
  logic                       s1_sat_pos;     // x > +4 -> override w/ +1.0
  logic                       s1_sat_neg;     // x < -4 -> override w/  0.0

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid    <= 1'b0;
      s1_addr_lo  <= 8'd0;
      s1_addr_hi  <= 8'd0;
      s1_frac_q16 <= '0;
      s1_sat_pos  <= 1'b0;
      s1_sat_neg  <= 1'b0;
    end else if (en) begin
      s1_valid <= in_valid;
      if (in_valid) begin
        logic signed [31:0] clamped;
        logic        [31:0] shifted;
        logic        [7:0]  addr_lo_w;

        s1_sat_pos <= (x_in > Q_FOUR);
        s1_sat_neg <= (x_in < Q_NEG_FOUR);

        if (x_in > Q_FOUR_MINUS1)
          clamped = Q_FOUR_MINUS1;
        else if (x_in < Q_NEG_FOUR)
          clamped = Q_NEG_FOUR;
        else
          clamped = x_in;

        shifted    = clamped + Q_FOUR;
        addr_lo_w  = shifted[18:11];
        s1_addr_lo <= addr_lo_w;
        s1_addr_hi <= (addr_lo_w == 8'd255) ? 8'd255 : (addr_lo_w + 8'd1);
        s1_frac_q16 <= {16'h0000, shifted[10:0], 5'h00};
      end
    end
  end

  // ---------------------------------------------------------------------
  // Stage 2: LUT registered read + carry forwarded signals
  // ---------------------------------------------------------------------
  logic                       s2_valid;
  logic signed [31:0]         s2_frac_q16;
  logic                       s2_sat_pos;
  logic                       s2_sat_neg;
  logic signed [DATA_WIDTH-1:0] s2_data_lo;
  logic signed [DATA_WIDTH-1:0] s2_data_hi;

  gelu_grad_direct_lut #(
    .DATA_WIDTH (DATA_WIDTH)
  ) u_lut (
    .clk     (clk),
    .addr_lo (s1_addr_lo),
    .addr_hi (s1_addr_hi),
    .data_lo (s2_data_lo),
    .data_hi (s2_data_hi)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid    <= 1'b0;
      s2_frac_q16 <= '0;
      s2_sat_pos  <= 1'b0;
      s2_sat_neg  <= 1'b0;
    end else if (en) begin
      s2_valid    <= s1_valid;
      s2_frac_q16 <= s1_frac_q16;
      s2_sat_pos  <= s1_sat_pos;
      s2_sat_neg  <= s1_sat_neg;
    end
  end

  // ---------------------------------------------------------------------
  // Stage 3: linear interpolation + saturation override
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      grad_out     <= '0;
    end else if (en) begin
      out_valid <= s2_valid;
      if (s2_valid) begin
        logic signed [31:0] diff;
        logic signed [31:0] delta;
        logic signed [31:0] interp;
        diff   = s2_data_hi - s2_data_lo;
        delta  = q_mul(diff, s2_frac_q16);
        interp = s2_data_lo + delta;
        // Override saturation tails: x < -4 -> 0, x > +4 -> 1.
        if (s2_sat_pos)
          grad_out <= Q_ONE;
        else if (s2_sat_neg)
          grad_out <= Q_ZERO;
        else
          grad_out <= interp;
      end
    end
  end

endmodule
