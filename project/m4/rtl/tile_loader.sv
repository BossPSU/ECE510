// tile_loader.sv — Loads A/B tiles from SRAM into systolic array inputs
module tile_loader
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int TILE_DIM   = TILE_SIZE,
  parameter int ADDR_WIDTH = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,
  input  logic                    en,

  // Tile config
  input  logic [ADDR_WIDTH-1:0]   base_addr,
  input  logic [ADDR_WIDTH-1:0]   stride,
  input  logic [7:0]              tile_rows,
  input  logic [7:0]              tile_cols,

  // SRAM read port
  output logic                    sram_req,
  output logic [ADDR_WIDTH-1:0]   sram_addr,
  input  logic [DATA_WIDTH-1:0]   sram_rdata,
  input  logic                    sram_rvalid,

  // Output stream to systolic array
  output logic [DATA_WIDTH-1:0]   data_out,
  output logic                    data_valid,
  output logic                    done
);

  logic [7:0]  row_cnt, col_cnt;
  logic        active;
  logic        read_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active       <= 1'b0;
      row_cnt      <= '0;
      col_cnt      <= '0;
      sram_req     <= 1'b0;
      done         <= 1'b0;
      read_pending <= 1'b0;
    end else if (start) begin
      active       <= 1'b1;
      row_cnt      <= '0;
      col_cnt      <= '0;
      done         <= 1'b0;
      sram_req     <= 1'b1;
      read_pending <= 1'b1;
    end else if (active && en) begin
      sram_req <= 1'b1;

      if (sram_rvalid) begin
        if (col_cnt == tile_cols - 1) begin
          col_cnt <= '0;
          if (row_cnt == tile_rows - 1) begin
            active   <= 1'b0;
            sram_req <= 1'b0;
            done     <= 1'b1;
          end else begin
            row_cnt <= row_cnt + 1;
          end
        end else begin
          col_cnt <= col_cnt + 1;
        end
      end
    end else begin
      done <= 1'b0;
    end
  end

  assign sram_addr  = base_addr + ({8'b0, row_cnt} * stride) + {8'b0, col_cnt};
  assign data_out   = sram_rdata;
  assign data_valid = sram_rvalid && active;

endmodule
