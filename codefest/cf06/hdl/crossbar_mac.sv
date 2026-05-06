// crossbar_mac.sv — 4x4 binary-weight crossbar MAC unit
//
// Each clock cycle computes:
//     out[j] = sum_i ( weight[i][j] * in[i] ),  weight[i][j] in {+1, -1}
//
// Weight encoding stored in w_reg: 1'b1 -> +1, 1'b0 -> -1.
// Inputs are 8-bit signed; outputs are signed accumulators wide enough
// to hold 4 * (-128..+127) = -512..+512 (16-bit signed is plenty).
//
// Weights are loaded synchronously when load_w is asserted.

module crossbar_mac #(
    parameter int N     = 4,    // grid size (rows = inputs, cols = outputs)
    parameter int IN_W  = 8,    // signed input width
    parameter int OUT_W = 16    // signed output / accumulator width
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // Synchronous weight load
    input  logic                       load_w,
    input  logic                       w_in     [N][N],   // 1=+1, 0=-1

    // Data path
    input  logic signed [IN_W-1:0]     in_data  [N],
    output logic signed [OUT_W-1:0]    out_data [N]
);

    // Weight register array (1 bit per crossbar element)
    logic w_reg [N][N];

    // -----------------------------------------------------------
    // Weight load
    // -----------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++)
                    w_reg[i][j] <= 1'b0;
        end else if (load_w) begin
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++)
                    w_reg[i][j] <= w_in[i][j];
        end
    end

    // -----------------------------------------------------------
    // Per-column dot product (combinational)
    //   sum[j] = sum_i ( (+/-1) * in[i] )
    // -----------------------------------------------------------
    logic signed [OUT_W-1:0] sum_comb [N];

    always_comb begin
        for (int j = 0; j < N; j++) begin
            sum_comb[j] = '0;
            for (int i = 0; i < N; i++) begin
                if (w_reg[i][j])
                    sum_comb[j] = sum_comb[j] + OUT_W'(in_data[i]);
                else
                    sum_comb[j] = sum_comb[j] - OUT_W'(in_data[i]);
            end
        end
    end

    // -----------------------------------------------------------
    // Register the outputs (one result per clock cycle)
    // -----------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int j = 0; j < N; j++)
                out_data[j] <= '0;
        end else begin
            for (int j = 0; j < N; j++)
                out_data[j] <= sum_comb[j];
        end
    end

endmodule
