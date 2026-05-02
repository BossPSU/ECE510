// fused_postproc_unit.sv — Synthesizable Q16.16 fused post-processing
// MUX: bypass / GELU / GELU' / softmax / mask
module fused_postproc_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
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

  // GELU forward
  gelu_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (en),
    .x_in      (data_in),
    .in_valid  (in_valid && (op_sel == FUSED_GELU)),
    .y_out     (gelu_out),
    .out_valid (gelu_valid)
  );

  // GELU gradient
  gelu_grad_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu_grad (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (en),
    .x_in      (aux_in),
    .in_valid  (in_valid && (op_sel == FUSED_GELU_GRAD)),
    .grad_out  (gelu_grad_out),
    .out_valid (gelu_grad_valid)
  );

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

  // Output MUX (combinational select based on which path has valid output)
  always_comb begin
    data_out  = '0;
    out_valid = 1'b0;

    if (gelu_valid) begin
      data_out  = gelu_out;
      out_valid = 1'b1;
    end
    else if (gelu_grad_valid) begin
      // dh = dh_act * gelu_grad(h)
      data_out  = q_mul(data_delay[GRAD_DELAY-1], gelu_grad_out);
      out_valid = 1'b1;
    end
    else if (in_valid && (op_sel == FUSED_BYPASS || op_sel == FUSED_MASK)) begin
      data_out  = data_in;
      out_valid = 1'b1;
    end
  end

endmodule
