// tile_buffer.sv — Register-based tile buffer
// Holds a TILE_DIM x TILE_DIM tile of Q16.16 values.
//
// Read interfaces:
//   * single-element 2D read (rd_row, rd_col -> rd_data)
//   * single-element linear read (rd_lin_idx -> rd_lin_data)
//   * NUM_RD_PORTS parallel read ports — each port has its own (row, col)
//     input and returns one element. Lets the streaming pipeline issue
//     up to NUM_RD_PORTS scattered reads per cycle without exposing the
//     entire 4096-cell memory at the port (which would create ~131k
//     wires per instance and choke place-and-route).
//
// Layout convention for indexed addresses:
//   wr_idx[11:6]    = row, wr_idx[5:0]    = col   (mem[row][col])
//   rd_lin_idx same convention.
module tile_buffer
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH   = 32,
  parameter int TILE_DIM     = 64,
  parameter int NUM_RD_PORTS = 1
)(
  input  logic                            clk,
  input  logic                            rst_n,

  // Write port
  input  logic                            wr_en,
  input  logic [11:0]                     wr_idx,
  input  logic signed [DATA_WIDTH-1:0]    wr_data,

  // 2D single-element read
  input  logic [7:0]                      rd_row,
  input  logic [7:0]                      rd_col,
  output logic signed [DATA_WIDTH-1:0]    rd_data,

  // Linear single-element read
  input  logic [11:0]                     rd_lin_idx,
  output logic signed [DATA_WIDTH-1:0]    rd_lin_data,

  // Multi-port parallel read (replaces wide mem_out)
  input  logic [7:0]                      mp_rd_row  [NUM_RD_PORTS],
  input  logic [7:0]                      mp_rd_col  [NUM_RD_PORTS],
  output logic signed [DATA_WIDTH-1:0]    mp_rd_data [NUM_RD_PORTS]
);

  logic signed [DATA_WIDTH-1:0] mem [TILE_DIM][TILE_DIM];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TILE_DIM; i++)
        for (int j = 0; j < TILE_DIM; j++)
          mem[i][j] <= '0;
    end else if (wr_en) begin
      mem[wr_idx[11:6]][wr_idx[5:0]] <= wr_data;
    end
  end

  // Single-element reads (combinational)
  assign rd_data     = mem[rd_row[5:0]][rd_col[5:0]];
  assign rd_lin_data = mem[rd_lin_idx[11:6]][rd_lin_idx[5:0]];

  // Parallel read ports — each is a 4096:1 mux of the register file
  genvar p;
  generate
    for (p = 0; p < NUM_RD_PORTS; p++) begin : gen_rd_port
      assign mp_rd_data[p] = mem[mp_rd_row[p][5:0]][mp_rd_col[p][5:0]];
    end
  endgenerate

endmodule
