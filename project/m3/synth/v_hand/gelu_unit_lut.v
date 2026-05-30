/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// gelu_unit_lut.v -- hand-flattened from project/RTL/gelu_unit_lut.sv
//
// Drop-in port-compatible replacement for gelu_unit.v. Replaces the
// Pade[3,2] tanh chain (10 mults + 1 combinational divider, ~500 gate
// levels) with a 256-entry direct GELU LUT + adjacent-entry linear
// interpolation. 3-cycle pipeline.
//
// Hand-flatten conversions:
//   - dropped `import accel_pkg::*`; Q_FOUR / Q_NEG_FOUR / Q_FOUR_MINUS1
//     inlined as 32-bit hex localparams;
//   - `logic` -> wire/reg;
//   - `always_ff` -> `always @(posedge clk or negedge rst_n)`;
//   - q_mul inlined as Verilog 2005 function;
//   - in-block decls hoisted to module scope (single-row begin pattern).
// =============================================================================
module gelu_unit_lut (
    clk,
    rst_n,
    en,
    x_in,
    in_valid,
    y_out,
    out_valid
);

    parameter DATA_WIDTH = 32;

    // Q16.16 constants
    localparam [31:0] Q_ZERO        = 32'h00000000;
    localparam [31:0] Q_ONE         = 32'h00010000;
    localparam [31:0] Q_FOUR        = 32'h00040000;  // +4.0
    localparam [31:0] Q_NEG_FOUR    = 32'hFFFC0000;  // -4.0
    localparam [31:0] Q_FOUR_MINUS1 = 32'h0003FFFF;  // +4.0 - 1 LSB

    input  wire                            clk;
    input  wire                            rst_n;
    input  wire                            en;
    input  wire signed [DATA_WIDTH-1:0]    x_in;
    input  wire                            in_valid;
    output reg  signed [DATA_WIDTH-1:0]    y_out;
    output reg                             out_valid;

    // ------- helpers --------------------------------------------------
    function signed [31:0] q_mul;
        input signed [31:0] a;
        input signed [31:0] b;
        reg signed [63:0] product;
        begin
            product = $signed(a) * $signed(b);
            q_mul   = product[47:16];
        end
    endfunction

    // ------- module-scope temporaries (per Verilog 2005 style) -------
    reg signed [31:0] clamped;
    reg        [31:0] shifted;
    reg        [7:0]  addr_lo_w;
    reg signed [31:0] diff;
    reg signed [31:0] delta;
    reg signed [31:0] interp;

    // ===== Stage 1: clamp, address gen, fractional position =====
    reg               s1_valid;
    reg [7:0]         s1_addr_lo;
    reg [7:0]         s1_addr_hi;
    reg signed [31:0] s1_frac_q16;
    reg signed [31:0] s1_x_in;
    reg               s1_sat_pos;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid    <= 1'b0;
            s1_addr_lo  <= 8'd0;
            s1_addr_hi  <= 8'd0;
            s1_frac_q16 <= 32'h0;
            s1_x_in     <= 32'h0;
            s1_sat_pos  <= 1'b0;
        end else if (en) begin
            s1_valid <= in_valid;
            if (in_valid) begin
                s1_x_in    <= x_in;
                s1_sat_pos <= ($signed(x_in) > $signed(Q_FOUR));

                if ($signed(x_in) > $signed(Q_FOUR_MINUS1))
                    clamped = $signed(Q_FOUR_MINUS1);
                else if ($signed(x_in) < $signed(Q_NEG_FOUR))
                    clamped = $signed(Q_NEG_FOUR);
                else
                    clamped = x_in;

                shifted    = clamped + Q_FOUR;
                addr_lo_w  = shifted[18:11];
                s1_addr_lo <= addr_lo_w;
                s1_addr_hi <= (addr_lo_w == 8'd255) ? 8'd255
                                                    : (addr_lo_w + 8'd1);
                s1_frac_q16 <= {16'h0000, shifted[10:0], 5'h00};
            end
        end
    end

    // ===== Stage 2: LUT registered read + carry forwarded signals =====
    reg               s2_valid;
    reg signed [31:0] s2_frac_q16;
    reg signed [31:0] s2_x_in;
    reg               s2_sat_pos;
    wire signed [DATA_WIDTH-1:0] s2_data_lo;
    wire signed [DATA_WIDTH-1:0] s2_data_hi;

    gelu_direct_lut #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_lut (
        .clk     (clk),
        .addr_lo (s1_addr_lo),
        .addr_hi (s1_addr_hi),
        .data_lo (s2_data_lo),
        .data_hi (s2_data_hi)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid    <= 1'b0;
            s2_frac_q16 <= 32'h0;
            s2_x_in     <= 32'h0;
            s2_sat_pos  <= 1'b0;
        end else if (en) begin
            s2_valid    <= s1_valid;
            s2_frac_q16 <= s1_frac_q16;
            s2_x_in     <= s1_x_in;
            s2_sat_pos  <= s1_sat_pos;
        end
    end

    // ===== Stage 3: linear interp + saturation override =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            y_out     <= 32'h0;
        end else if (en) begin
            out_valid <= s2_valid;
            if (s2_valid) begin
                diff   = s2_data_hi - s2_data_lo;
                delta  = q_mul(diff, s2_frac_q16);
                interp = s2_data_lo + delta;
                if (s2_sat_pos)
                    y_out <= s2_x_in;
                else
                    y_out <= interp;
            end
        end
    end

endmodule
