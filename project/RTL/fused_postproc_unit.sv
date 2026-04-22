// fused_postproc_unit.sv — Fused post-processing stage after systolic output
// MUX selects: bypass, GELU, GELU', softmax, or mask
module fused_postproc_unit
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   en,

  // Control
  input  fused_op_t              op_sel,

  // Input from systolic array
  input  logic [DATA_WIDTH-1:0]  data_in,
  input  logic                   in_valid,

  // Auxiliary input (e.g., pre-activation h for gelu_grad)
  input  logic [DATA_WIDTH-1:0]  aux_in,

  // Output to next stage or SRAM
  output logic [DATA_WIDTH-1:0]  data_out,
  output logic                   out_valid
);

  // Sub-unit outputs
  logic [DATA_WIDTH-1:0] gelu_out, gelu_grad_out;
  logic                  gelu_valid, gelu_grad_valid;

  // GELU forward — always runs, gated by in_valid+op_sel
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

  // Delayed data_in for GELU_GRAD multiply (3 pipeline stages to match gelu_grad)
  logic [DATA_WIDTH-1:0] data_delay [3];
  logic                  valid_delay [3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 3; i++) begin
        data_delay[i]  <= '0;
        valid_delay[i] <= 1'b0;
      end
    end else if (en) begin
      data_delay[0]  <= data_in;
      valid_delay[0] <= in_valid && (op_sel == FUSED_GELU_GRAD);
      for (int i = 1; i < 3; i++) begin
        data_delay[i]  <= data_delay[i-1];
        valid_delay[i] <= valid_delay[i-1];
      end
    end
  end

  // Output MUX
  always_comb begin
    case (op_sel)
      FUSED_BYPASS: begin
        data_out  = data_in;
        out_valid = in_valid;
      end
      FUSED_GELU: begin
        data_out  = gelu_out;
        out_valid = gelu_valid;
      end
      FUSED_GELU_GRAD: begin
        // dh = dh_act * gelu_grad(h)
        if (gelu_grad_valid) begin
          data_out  = $shortrealtobits(
            $bitstoshortreal(data_delay[2]) * $bitstoshortreal(gelu_grad_out)
          );
          out_valid = 1'b1;
        end else begin
          data_out  = '0;
          out_valid = 1'b0;
        end
      end
      FUSED_MASK: begin
        data_out  = data_in;
        out_valid = in_valid;
      end
      default: begin
        data_out  = data_in;
        out_valid = in_valid;
      end
    endcase
  end

endmodule
