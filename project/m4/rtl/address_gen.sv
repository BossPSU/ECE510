// address_gen.sv — Reusable address generation for tile traversal
module address_gen
  import accel_pkg::*;
#(
  parameter int ADDR_WIDTH = 16,
  parameter int TILE_DIM   = TILE_SIZE
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic                    en,

  // Base address and stride
  input  logic [ADDR_WIDTH-1:0]   base_addr,
  input  logic [ADDR_WIDTH-1:0]   row_stride,
  input  logic [7:0]              num_rows,
  input  logic [7:0]              num_cols,

  // Output address stream
  output logic [ADDR_WIDTH-1:0]   addr_out,
  output logic                    addr_valid,
  output logic                    addr_last,
  input  logic                    addr_ready
);

  logic [7:0] row_cnt, col_cnt;
  logic        active;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active     <= 1'b0;
      row_cnt    <= '0;
      col_cnt    <= '0;
      addr_valid <= 1'b0;
      addr_last  <= 1'b0;
    end else if (start) begin
      active     <= 1'b1;
      row_cnt    <= '0;
      col_cnt    <= '0;
      addr_valid <= 1'b1;
      addr_last  <= 1'b0;
    end else if (active && en && addr_ready) begin
      if (col_cnt == num_cols - 1) begin
        col_cnt <= '0;
        if (row_cnt == num_rows - 1) begin
          active     <= 1'b0;
          addr_valid <= 1'b0;
          addr_last  <= 1'b1;
        end else begin
          row_cnt <= row_cnt + 1;
        end
      end else begin
        col_cnt <= col_cnt + 1;
      end

      addr_last <= (col_cnt == num_cols - 1) && (row_cnt == num_rows - 1);
    end
  end

  assign addr_out = base_addr + ({8'b0, row_cnt} * row_stride) + {8'b0, col_cnt};

endmodule
