/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// tile_writer.v -- hand-flattened from project/m2/rtl/tile_writer.sv
// Walks (tile_rows x tile_cols) base+stride addresses and writes the
// incoming stream into the scratchpad on each beat.
// =============================================================================
module tile_writer (
    clk,
    rst_n,
    start,
    en,
    base_addr,
    stride,
    tile_rows,
    tile_cols,
    data_in,
    data_valid,
    sram_req,
    sram_we,
    sram_addr,
    sram_wdata,
    done
);

    parameter DATA_WIDTH = 32;
    parameter TILE_DIM   = 64;
    parameter ADDR_WIDTH = 16;

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    start;
    input  wire                    en;
    input  wire [ADDR_WIDTH-1:0]   base_addr;
    input  wire [ADDR_WIDTH-1:0]   stride;
    input  wire [7:0]              tile_rows;
    input  wire [7:0]              tile_cols;
    input  wire [DATA_WIDTH-1:0]   data_in;
    input  wire                    data_valid;
    output reg                     sram_req;
    output reg                     sram_we;
    output wire [ADDR_WIDTH-1:0]   sram_addr;
    output reg  [DATA_WIDTH-1:0]   sram_wdata;
    output reg                     done;

    reg [7:0] row_cnt;
    reg [7:0] col_cnt;
    reg       active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active     <= 1'b0;
            row_cnt    <= 8'd0;
            col_cnt    <= 8'd0;
            sram_req   <= 1'b0;
            sram_we    <= 1'b0;
            sram_wdata <= {DATA_WIDTH{1'b0}};
            done       <= 1'b0;
        end else if (start) begin
            active   <= 1'b1;
            row_cnt  <= 8'd0;
            col_cnt  <= 8'd0;
            done     <= 1'b0;
            sram_req <= 1'b0;
            sram_we  <= 1'b0;
        end else if (active && en && data_valid) begin
            sram_req   <= 1'b1;
            sram_we    <= 1'b1;
            sram_wdata <= data_in;

            if (col_cnt == tile_cols - 8'd1) begin
                col_cnt <= 8'd0;
                if (row_cnt == tile_rows - 8'd1) begin
                    active <= 1'b0;
                    done   <= 1'b1;
                end else begin
                    row_cnt <= row_cnt + 8'd1;
                end
            end else begin
                col_cnt <= col_cnt + 8'd1;
            end
        end else begin
            sram_req <= 1'b0;
            sram_we  <= 1'b0;
            done     <= 1'b0;
        end
    end

    assign sram_addr = base_addr + ({8'b0, row_cnt} * stride)
                                 + {8'b0, col_cnt};

endmodule
