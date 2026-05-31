// systolic_array_64x64.sv — Core GEMM engine
// 64x64 grid of MAC processing elements with weight-stationary dataflow
module systolic_array_64x64
  import accel_pkg::*;
#(
  parameter int ROWS       = ARRAY_ROWS,
  parameter int COLS       = ARRAY_COLS,
  parameter int DATA_WIDTH = 32,
  // M5 MAC pipeline selector. USE_PIPED4_MAC takes precedence when 1.
  //   USE_PIPED4_MAC == 1 -> mac_pe_piped4 (4-stage: split 8x8 multiplier
  //                          + split 32-bit accumulator add). +3 cycles
  //                          MAC latency vs legacy. Critical path ~3-3.5 ns
  //                          at Sky130 SS, ~1.5-2 ns at SAED32 SS.
  //                          M5 option-D default for the SAED32 chip.
  //   USE_PIPED_MAC  == 1 -> mac_pe_piped (2-stage: mid-MAC register
  //                          between Q8.8 product and Q16.16 align+add).
  //                          +1 cycle latency. Critical path ~7-8 ns
  //                          Sky130 SS. M5 option-C / Sky130-deliverable.
  //   neither set         -> legacy 1-cycle mac_pe (~14.5 ns Sky130 SS).
  // Caller MUST bump stream_pipeline.DRAIN_CYCLES:
  //   piped4=1 -> DRAIN_CYCLES = 7
  //   piped =1 -> DRAIN_CYCLES = 5
  //   neither  -> DRAIN_CYCLES = 4
  parameter int USE_PIPED4_MAC = 1,
  parameter int USE_PIPED_MAC  = 1
)(
  input  logic                            clk,
  input  logic                            rst_n,
  input  logic                            en,
  input  logic                            clear_acc,

  // Row inputs (A matrix tiles, fed from west) — Q16.16 signed
  input  logic signed [DATA_WIDTH-1:0]    a_in  [ROWS],

  // Column inputs (B matrix tiles, fed from north) — Q16.16 signed
  input  logic signed [DATA_WIDTH-1:0]    b_in  [COLS],

  // Output: accumulated results from bottom row — Q16.16 signed
  output logic signed [DATA_WIDTH-1:0]    c_out [ROWS][COLS]
);

  // Internal wires between PEs — Q16.16 signed
  logic signed [DATA_WIDTH-1:0] a_wire [ROWS][COLS+1];
  logic signed [DATA_WIDTH-1:0] b_wire [ROWS+1][COLS];

  // Connect inputs
  genvar r, c;
  generate
    for (r = 0; r < ROWS; r++) begin : gen_a_in
      assign a_wire[r][0] = a_in[r];
    end

    for (c = 0; c < COLS; c++) begin : gen_b_in
      assign b_wire[0][c] = b_in[c];
    end
  endgenerate

  // Instantiate PE grid. Three-way selector:
  //   USE_PIPED4_MAC=1 -> mac_pe_piped4 (4-stage, M5 option D)
  //   else USE_PIPED_MAC=1 -> mac_pe_piped (2-stage, M5 option C)
  //   else -> legacy mac_pe (1-stage)
  // All three flavors share the same port list so the grid wiring above
  // (a_wire/b_wire) is unchanged.
  generate
    for (r = 0; r < ROWS; r++) begin : gen_row
      for (c = 0; c < COLS; c++) begin : gen_col
        if (USE_PIPED4_MAC) begin : g_piped4_pe
          mac_pe_piped4 #(.DATA_WIDTH(DATA_WIDTH)) u_pe (
            .clk       (clk),
            .rst_n     (rst_n),
            .en        (en),
            .clear_acc (clear_acc),
            .a_in      (a_wire[r][c]),
            .a_out     (a_wire[r][c+1]),
            .b_in      (b_wire[r][c]),
            .b_out     (b_wire[r+1][c]),
            .acc_out   (c_out[r][c])
          );
        end else if (USE_PIPED_MAC) begin : g_piped_pe
          mac_pe_piped #(.DATA_WIDTH(DATA_WIDTH)) u_pe (
            .clk       (clk),
            .rst_n     (rst_n),
            .en        (en),
            .clear_acc (clear_acc),
            .a_in      (a_wire[r][c]),
            .a_out     (a_wire[r][c+1]),
            .b_in      (b_wire[r][c]),
            .b_out     (b_wire[r+1][c]),
            .acc_out   (c_out[r][c])
          );
        end else begin : g_legacy_pe
          mac_pe #(.DATA_WIDTH(DATA_WIDTH)) u_pe (
            .clk       (clk),
            .rst_n     (rst_n),
            .en        (en),
            .clear_acc (clear_acc),
            .a_in      (a_wire[r][c]),
            .a_out     (a_wire[r][c+1]),
            .b_in      (b_wire[r][c]),
            .b_out     (b_wire[r+1][c]),
            .acc_out   (c_out[r][c])
          );
        end
      end
    end
  endgenerate

endmodule
