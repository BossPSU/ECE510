/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// systolic_array_64x64.v -- hand-flattened from
// project/m2/rtl/systolic_array_64x64.sv
//
// ROWS x COLS grid of mac_pe instances, output-stationary, with skewed A/B
// feeds. Conversions:
//   - a_in/b_in unpacked-array ports -> flat packed buses
//   - c_out 2D unpacked output array -> flat ROWS*COLS*DATA_WIDTH packed bus,
//     LSB-aligned by (row*COLS + col).
//   - Internal forwarding wires kept as 2D `wire signed`, which is yosys-
//     compatible (the AST-frontend signed assertion was only seen on
//     *port-crossing* signed buses).
//   - ROWS/COLS parameters default to 64; chparam from above for scope-down.
// =============================================================================
module systolic_array_64x64 (
    clk,
    rst_n,
    en,
    clear_acc,
    a_in,
    b_in,
    c_out
);

    parameter ROWS       = 64;
    parameter COLS       = 64;
    parameter DATA_WIDTH = 32;

    input  wire clk;
    input  wire rst_n;
    input  wire en;
    input  wire clear_acc;

    // West row inputs: ROWS Q16.16 values, packed LSB-aligned by row index.
    input  wire [(ROWS*DATA_WIDTH)-1:0]      a_in;
    // North column inputs: COLS Q16.16 values, packed by column index.
    input  wire [(COLS*DATA_WIDTH)-1:0]      b_in;
    // Output accumulator grid: ROWS*COLS Q16.16 values, packed by
    // (row*COLS + col).
    output wire [(ROWS*COLS*DATA_WIDTH)-1:0] c_out;

    // Internal west->east and north->south buses. Both are 2D wire arrays.
    // The extra +1 in one dim gives the eastern / southern boundary nets.
    wire signed [DATA_WIDTH-1:0] a_wire [0:ROWS-1][0:COLS];
    wire signed [DATA_WIDTH-1:0] b_wire [0:ROWS][0:COLS-1];

    // ----- Drive the western and northern boundaries from the inputs -----
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_a_in
            assign a_wire[r][0] =
                $signed(a_in[(r*DATA_WIDTH) +: DATA_WIDTH]);
        end
        for (c = 0; c < COLS; c = c + 1) begin : gen_b_in
            assign b_wire[0][c] =
                $signed(b_in[(c*DATA_WIDTH) +: DATA_WIDTH]);
        end
    endgenerate

    // ----- PE grid -----
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : gen_row
            for (c = 0; c < COLS; c = c + 1) begin : gen_col
                wire signed [DATA_WIDTH-1:0] pe_acc;

                // M5 option D: 4-stage MAC PE (mac_pe_piped4).
                //   Stage 1a: saturate + lo-nibble 8x4 partial product
                //   Stage 1b: hi-nibble 8x4 + shift-add -> Q8.8 product
                //   Stage 2:  Q8.8 -> Q16.16 align + lower-16 acc add
                //   Stage 3:  upper-16 acc add with carry-in
                // +3 cycles MAC latency vs legacy. Critical path ~3 ns
                // Sky130 SS / ~1.5-2 ns SAED32 SS. stream_pipeline.v's
                // DRAIN_CYCLES MUST be 7 to drain the deeper PE.
                // Port-compatible drop-in for mac_pe and mac_pe_piped.
                mac_pe_piped4 #(
                    .DATA_WIDTH (DATA_WIDTH)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .en        (en),
                    .clear_acc (clear_acc),
                    .a_in      (a_wire[r][c]),
                    .a_out     (a_wire[r][c+1]),
                    .b_in      (b_wire[r][c]),
                    .b_out     (b_wire[r+1][c]),
                    .acc_out   (pe_acc)
                );

                // Pack PE accumulator into the flat output bus.
                assign c_out[(((r*COLS) + c) * DATA_WIDTH) +: DATA_WIDTH]
                       = pe_acc;
            end
        end
    endgenerate

endmodule
