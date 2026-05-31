// gelu_unit_lut.sv — LUT-based Q16.16 GELU activation (M4 + M6 Tier 2B)
//
// Drop-in replacement for gelu_unit.sv. Same port list, same Q16.16
// numerical contract. Structural change: the Pade[3,2] tanh chain
// (10 mults + 1 combinational divider, ~500 gate levels of critical
// path) is replaced by a 256-entry direct GELU LUT with linear
// interpolation between adjacent entries.
//
// Architecture
// ------------
// Pipeline (4 cycles after M6 Tier 2B; was 3 in M4):
//   Stage 1 (registered): clamp x_in to [-4, +4 - eps], compute
//     8-bit address (addr_lo) + adjacent address (addr_hi) into the
//     direct GELU LUT, plus 16-bit Q16.16 fractional position frac.
//     Also latches x_in and a "saturation > +4" flag.
//   Stage 2 (LUT registered read): gelu_direct_lut emits LUT[addr_lo]
//     and LUT[addr_hi] in parallel. frac, x_in, sat_pos forwarded.
//   Stage 3a (registered, NEW): subtract diff = data_hi - data_lo and
//     compute the interpolation product delta = q_mul(diff, frac).
//     Register delta + data_lo + x_in + sat_pos. Cuts the
//     s2_data_hi/s2_data_lo -> 32-bit sub -> 32x32 mul -> 32-bit add
//     -> y_out chain that drove 49 of the Sky130 SS >5 ns violators
//     on Attempt 9.
//   Stage 3b (registered): linear interp final add + saturation override.
//        y_interp = data_lo + delta
//     plus saturation override: for x_in > +4, return x_in (since
//     GELU(x) -> x there); for x_in < -4, the LUT itself returns
//     near-zero so no override is needed.
//
// Precision
// ---------
// Worst-case interpolation error over [-4, +4]:
//   eps_lin ~= (h^2 / 8) * max|GELU''| with h = 1/32 ~= 0.03125
//                                       and max|GELU''| ~= 0.4
//          ~= (1e-3 / 8) * 0.4 ~= 5e-5
// Q16.16 LSB is 1/65536 ~= 1.5e-5, so the LUT+interp output is within
// ~3 LSB of true GELU across the entire active range. The current
// Pade[3,2] chain has ~1e-3 worst-case error, so this is ~20x more
// accurate -- the LUT swap is a precision improvement on top of the
// area / f_max win.
//
// Hand-flatten conversion path: see project/m3/synth/v_hand/gelu_unit_lut.v.
module gelu_unit_lut
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
  localparam logic signed [31:0] Q_FOUR        = 32'sh00040000;  //  +4.0
  localparam logic signed [31:0] Q_NEG_FOUR    = 32'shFFFC0000;  //  -4.0
  // Upper clamp = +4.0 - 1 LSB (keeps shifted_q16 < 0x80000 so addr_lo
  // never overflows past 255).
  localparam logic signed [31:0] Q_FOUR_MINUS1 = 32'sh0003FFFF;

  // ---------------------------------------------------------------------
  // Stage 1: clamp, address generation, fractional position
  // ---------------------------------------------------------------------
  // shifted_q16 = clamped + 4.0 -> range [0, 0x80000) in Q16.16 (19 bits)
  // addr_lo[7:0] = top 8 bits of shifted_q16 in [0, 255]
  // frac[15:0]   = next 11 bits, scaled up by <<5 to give Q16.16 fraction
  //                in [0, 1.0) -- low 5 bits below the LUT stride are
  //                rounding noise and contribute the < Q16.16 LSB error.

  logic                       s1_valid;
  logic [7:0]                 s1_addr_lo;
  logic [7:0]                 s1_addr_hi;
  logic signed [31:0]         s1_frac_q16;
  logic signed [31:0]         s1_x_in;
  logic                       s1_sat_pos;     // x_in > +4 -> override w/ x_in

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid    <= 1'b0;
      s1_addr_lo  <= 8'd0;
      s1_addr_hi  <= 8'd0;
      s1_frac_q16 <= '0;
      s1_x_in     <= '0;
      s1_sat_pos  <= 1'b0;
    end else if (en) begin
      s1_valid <= in_valid;
      if (in_valid) begin
        logic signed [31:0] clamped;
        logic        [31:0] shifted;
        logic        [7:0]  addr_lo_w;

        s1_x_in    <= x_in;
        s1_sat_pos <= (x_in > Q_FOUR);

        // Clamp to [-4, +4 - 1 LSB]
        if (x_in > Q_FOUR_MINUS1)
          clamped = Q_FOUR_MINUS1;
        else if (x_in < Q_NEG_FOUR)
          clamped = Q_NEG_FOUR;
        else
          clamped = x_in;

        // shifted_q16 = clamped + 4.0  (lives in [0, 0x80000))
        shifted    = clamped + Q_FOUR;
        addr_lo_w  = shifted[18:11];          // 8-bit address into 256-entry LUT
        s1_addr_lo <= addr_lo_w;
        // addr_hi = min(addr_lo + 1, 255); pipeline-safe overflow handling.
        s1_addr_hi <= (addr_lo_w == 8'd255) ? 8'd255 : (addr_lo_w + 8'd1);
        // frac_q16 = 11-bit fractional position scaled up to Q16.16 [0, 1.0).
        s1_frac_q16 <= {16'h0000, shifted[10:0], 5'h00};
      end
    end
  end

  // ---------------------------------------------------------------------
  // Stage 2: LUT registered read + carry forwarded signals 1 cycle
  // ---------------------------------------------------------------------
  // The LUT itself adds 1 cycle of pipeline (registered output of ROM).
  // We carry frac, x_in, sat_pos, valid alongside.

  logic                       s2_valid;
  logic signed [31:0]         s2_frac_q16;
  logic signed [31:0]         s2_x_in;
  logic                       s2_sat_pos;
  logic signed [DATA_WIDTH-1:0] s2_data_lo;
  logic signed [DATA_WIDTH-1:0] s2_data_hi;

  gelu_direct_lut #(
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
      s2_x_in     <= '0;
      s2_sat_pos  <= 1'b0;
    end else if (en) begin
      s2_valid    <= s1_valid;
      s2_frac_q16 <= s1_frac_q16;
      s2_x_in     <= s1_x_in;
      s2_sat_pos  <= s1_sat_pos;
    end
  end

  // ---------------------------------------------------------------------
  // Stage 3a (M6 Tier 2B): compute and register interpolation product.
  //   diff  = data_hi - data_lo
  //   delta = q_mul(diff, frac)
  // delta_r + data_lo_r3a + x_in_r3a + sat_pos_r3a + valid_r3a passed
  // to Stage 3b.
  // ---------------------------------------------------------------------
  logic                       s3a_valid;
  logic signed [31:0]         s3a_data_lo;
  logic signed [31:0]         s3a_delta;
  logic signed [31:0]         s3a_x_in;
  logic                       s3a_sat_pos;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3a_valid   <= 1'b0;
      s3a_data_lo <= '0;
      s3a_delta   <= '0;
      s3a_x_in    <= '0;
      s3a_sat_pos <= 1'b0;
    end else if (en) begin
      s3a_valid <= s2_valid;
      if (s2_valid) begin
        logic signed [31:0] diff;
        diff       = s2_data_hi - s2_data_lo;
        s3a_data_lo <= s2_data_lo;
        s3a_delta   <= q_mul(diff, s2_frac_q16);
        s3a_x_in    <= s2_x_in;
        s3a_sat_pos <= s2_sat_pos;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Stage 3b: linear interpolation final add + saturation override
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      y_out     <= '0;
    end else if (en) begin
      out_valid <= s3a_valid;
      if (s3a_valid) begin
        logic signed [31:0] interp;
        interp = s3a_data_lo + s3a_delta;
        // For x > +4, GELU(x) -> x. Override the LUT result so the
        // saturation tail tracks the input exactly.
        y_out <= s3a_sat_pos ? s3a_x_in : interp;
      end
    end
  end

endmodule
