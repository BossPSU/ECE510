// divider_or_reciprocal_unit.sv — Synthesizable Q16.16 division
// Uses signed integer division (synthesis tools generate sequential divider)
module divider_or_reciprocal_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,

  input  logic signed [DATA_WIDTH-1:0]    numerator,
  input  logic signed [DATA_WIDTH-1:0]    denominator,
  input  logic                            in_valid,

  output logic signed [DATA_WIDTH-1:0]    quotient,
  output logic                            out_valid
);

  // Pipeline: register inputs, compute, register output
  logic signed [31:0] num_r, den_r;
  logic               valid_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      num_r   <= '0;
      den_r   <= Q_ONE;
      valid_r <= 1'b0;
    end else if (en) begin
      num_r   <= numerator;
      den_r   <= (denominator == 0) ? Q_ONE : denominator;
      valid_r <= in_valid;
    end
  end

  // Stage 2: compute Q16.16 quotient
  // Shift numerator left by FRAC_BITS, then divide
  logic signed [63:0] num_ext;
  logic signed [63:0] q_full;
  assign num_ext = $signed({{16{num_r[31]}}, num_r, 16'h0000});
  assign q_full  = num_ext / $signed({{32{den_r[31]}}, den_r});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      quotient  <= '0;
      out_valid <= 1'b0;
    end else if (en) begin
      out_valid <= valid_r;
      if (valid_r)
        quotient <= q_full[31:0];
    end
  end

endmodule
