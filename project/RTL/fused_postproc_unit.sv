// fused_postproc_unit.sv — Synthesizable Q16.16 fused post-processing
// MUX: bypass / GELU / GELU' / softmax / mask
module fused_postproc_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH   = 32,
  // 0 = original Pade-chain gelu_unit / gelu_grad_unit (default; unchanged)
  // 1 = LUT+linear-interp gelu_unit_lut / gelu_grad_unit_lut (M4 update)
  parameter int USE_LUT_GELU = 0
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,

  input  fused_op_t                       op_sel,

  input  logic signed [DATA_WIDTH-1:0]    data_in,
  input  logic                            in_valid,

  // Auxiliary input (pre-activation h for gelu_grad)
  input  logic signed [DATA_WIDTH-1:0]    aux_in,

  output logic signed [DATA_WIDTH-1:0]    data_out,
  output logic                            out_valid
);

  logic signed [31:0] gelu_out, gelu_grad_out;
  logic               gelu_valid, gelu_grad_valid;

  // GELU forward + gradient. USE_LUT_GELU picks between the original
  // Pade-chain modules and the M4 LUT+interp drop-ins. SOFTMAX_LAT-style
  // pipeline-depth handling isn't needed here because both variants
  // converge to the same downstream out_valid; the data_delay tap below
  // assumes 6-stage gelu_grad latency (the new LUT version is only 3
  // stages so output arrives earlier, which is benign for the MUX).
  generate
    if (USE_LUT_GELU) begin : g_gelu_lut
      gelu_unit_lut #(.DATA_WIDTH(DATA_WIDTH)) u_gelu (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (data_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU)),
        .y_out     (gelu_out),
        .out_valid (gelu_valid)
      );

      gelu_grad_unit_lut #(.DATA_WIDTH(DATA_WIDTH)) u_gelu_grad (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (aux_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU_GRAD)),
        .grad_out  (gelu_grad_out),
        .out_valid (gelu_grad_valid)
      );
    end else begin : g_gelu_pade
      gelu_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (data_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU)),
        .y_out     (gelu_out),
        .out_valid (gelu_valid)
      );

      gelu_grad_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu_grad (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .x_in      (aux_in),
        .in_valid  (in_valid && (op_sel == FUSED_GELU_GRAD)),
        .grad_out  (gelu_grad_out),
        .out_valid (gelu_grad_valid)
      );
    end
  endgenerate

  // 6-stage delay for data_in to align with gelu_grad pipeline
  localparam int GRAD_DELAY = 6;
  logic signed [31:0] data_delay [GRAD_DELAY];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < GRAD_DELAY; i++)
        data_delay[i] <= '0;
    end else if (en) begin
      data_delay[0] <= data_in;
      for (int i = 1; i < GRAD_DELAY; i++)
        data_delay[i] <= data_delay[i-1];
    end
  end

  // Output MUX (combinational select; the actual data_out / out_valid
  // are registered below to break the data_delay[GRAD_DELAY-1] -> q_mul
  // -> output critical path that lands here at Sky130 SS).
  logic signed [DATA_WIDTH-1:0] data_out_c;
  logic                         out_valid_c;
  always_comb begin
    data_out_c  = '0;
    out_valid_c = 1'b0;

    if (gelu_valid) begin
      data_out_c  = gelu_out;
      out_valid_c = 1'b1;
    end
    else if (gelu_grad_valid) begin
      // dh = dh_act * gelu_grad(h)
      data_out_c  = q_mul(data_delay[GRAD_DELAY-1], gelu_grad_out);
      out_valid_c = 1'b1;
    end
    else if (in_valid && (op_sel == FUSED_BYPASS || op_sel == FUSED_MASK)) begin
      data_out_c  = data_in;
      out_valid_c = 1'b1;
    end
  end

  // M6 Tier 2A: output pipeline register. Adds +1 cycle to fused_postproc
  // total latency (caller's FUSED_DEPTH bumped to 9). Cuts the
  // data_delay[5][12] -> q_mul -> output path that drove 71 Sky130 SS
  // violators on Attempt 9.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out  <= '0;
      out_valid <= 1'b0;
    end else if (en) begin
      data_out  <= data_out_c;
      out_valid <= out_valid_c;
    end
  end

endmodule
