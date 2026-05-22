/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// tile_loader.v -- hand-flattened from project/m2/rtl/tile_loader.sv
// Walks (tile_rows x tile_cols) base+stride addresses; emits one
// scratchpad read per cycle and forwards the responses as a stream.
// =============================================================================
module tile_loader (
    clk,
    rst_n,
    start,
    en,
    base_addr,
    stride,
    tile_rows,
    tile_cols,
    sram_req,
    sram_addr,
    sram_rdata,
    sram_rvalid,
    data_out,
    data_valid,
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
    output reg                     sram_req;
    output wire [ADDR_WIDTH-1:0]   sram_addr;
    input  wire [DATA_WIDTH-1:0]   sram_rdata;
    input  wire                    sram_rvalid;
    output wire [DATA_WIDTH-1:0]   data_out;
    output wire                    data_valid;
    output reg                     done;

    reg [7:0] row_cnt;
    reg [7:0] col_cnt;
    reg       active;
    reg       read_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active       <= 1'b0;
            row_cnt      <= 8'd0;
            col_cnt      <= 8'd0;
            sram_req     <= 1'b0;
            done         <= 1'b0;
            read_pending <= 1'b0;
        end else if (start) begin
            active       <= 1'b1;
            row_cnt      <= 8'd0;
            col_cnt      <= 8'd0;
            done         <= 1'b0;
            sram_req     <= 1'b1;
            read_pending <= 1'b1;
        end else if (active && en) begin
            sram_req <= 1'b1;
            if (sram_rvalid) begin
                if (col_cnt == tile_cols - 8'd1) begin
                    col_cnt <= 8'd0;
                    if (row_cnt == tile_rows - 8'd1) begin
                        active   <= 1'b0;
                        sram_req <= 1'b0;
                        done     <= 1'b1;
                    end else begin
                        row_cnt <= row_cnt + 8'd1;
                    end
                end else begin
                    col_cnt <= col_cnt + 8'd1;
                end
            end
        end else begin
            done <= 1'b0;
        end
    end

    assign sram_addr  = base_addr + ({8'b0, row_cnt} * stride)
                                  + {8'b0, col_cnt};
    assign data_out   = sram_rdata;
    assign data_valid = sram_rvalid && active;

endmodule
