// tile_buffer.sv — Register-based tile buffer
// Holds a TILE_DIM x TILE_DIM tile of Q16.16 values
// Single-port write, multi-element read (for systolic feeding)
//
// Layout convention:
//   wr_idx[11:6] = row, wr_idx[5:0] = col   (mem[row][col])
//   rd_lin_idx interpreted same way
//   mem_out exposes the entire memory in parallel for systolic feeding
module tile_buffer
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int TILE_DIM   = 64
)(
  input  logic                            clk,
  input  logic                            rst_n,

  // Write port
  input  logic                            wr_en,
  input  logic [11:0]                     wr_idx,    // {row[5:0], col[5:0]}
  input  logic signed [DATA_WIDTH-1:0]    wr_data,

  // 2D read access (combinational, single element)
  input  logic [7:0]                      rd_row,
  input  logic [7:0]                      rd_col,
  output logic signed [DATA_WIDTH-1:0]    rd_data,

  // Linear read port (FSM drains tile to SRAM)
  input  logic [11:0]                     rd_lin_idx,
  output logic signed [DATA_WIDTH-1:0]    rd_lin_data,

  // Full memory exposure for parallel reads (used by streaming pipeline)
  output logic signed [DATA_WIDTH-1:0]    mem_out [TILE_DIM][TILE_DIM]
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

  // Combinational read (single element)
  assign rd_data     = mem[rd_row[5:0]][rd_col[5:0]];
  assign rd_lin_data = mem[rd_lin_idx[11:6]][rd_lin_idx[5:0]];

  // Full memory exposure
  genvar gi, gj;
  generate
    for (gi = 0; gi < TILE_DIM; gi++) begin : gen_mem_row
      for (gj = 0; gj < TILE_DIM; gj++) begin : gen_mem_col
        assign mem_out[gi][gj] = mem[gi][gj];
      end
    end
  endgenerate

endmodule
