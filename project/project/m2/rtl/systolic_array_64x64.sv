// systolic_array_64x64.sv — Core GEMM engine
// 64x64 grid of MAC processing elements with weight-stationary dataflow
module systolic_array_64x64
  import accel_pkg::*;
#(
  parameter int ROWS       = ARRAY_ROWS,
  parameter int COLS       = ARRAY_COLS,
  parameter int DATA_WIDTH = 32
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

  // Instantiate PE grid
  generate
    for (r = 0; r < ROWS; r++) begin : gen_row
      for (c = 0; c < COLS; c++) begin : gen_col
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
  endgenerate

endmodule
