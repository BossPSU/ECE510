// tile_writer.sv — Writes result tiles back to SRAM scratchpad
module tile_writer
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

  // Input stream from systolic/fused output
  input  logic [DATA_WIDTH-1:0]   data_in,
  input  logic                    data_valid,

  // SRAM write port
  output logic                    sram_req,
  output logic                    sram_we,
  output logic [ADDR_WIDTH-1:0]   sram_addr,
  output logic [DATA_WIDTH-1:0]   sram_wdata,

  output logic                    done
);

  logic [7:0] row_cnt, col_cnt;
  logic       active;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active   <= 1'b0;
      row_cnt  <= '0;
      col_cnt  <= '0;
      sram_req <= 1'b0;
      sram_we  <= 1'b0;
      done     <= 1'b0;
    end else if (start) begin
      active   <= 1'b1;
      row_cnt  <= '0;
      col_cnt  <= '0;
      done     <= 1'b0;
    end else if (active && en && data_valid) begin
      sram_req   <= 1'b1;
      sram_we    <= 1'b1;
      sram_wdata <= data_in;

      if (col_cnt == tile_cols - 1) begin
        col_cnt <= '0;
        if (row_cnt == tile_rows - 1) begin
          active <= 1'b0;
          done   <= 1'b1;
        end else begin
          row_cnt <= row_cnt + 1;
        end
      end else begin
        col_cnt <= col_cnt + 1;
      end
    end else begin
      sram_req <= 1'b0;
      sram_we  <= 1'b0;
      done     <= 1'b0;
    end
  end

  assign sram_addr = base_addr + ({8'b0, row_cnt} * stride) + {8'b0, col_cnt};

endmodule
