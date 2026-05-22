/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// address_gen.v -- hand-flattened from project/m2/rtl/address_gen.sv
// Row-stride address generator (base + row*stride + col, walks the tile).
// =============================================================================
module address_gen (
    clk,
    rst_n,
    start,
    en,
    base_addr,
    row_stride,
    num_rows,
    num_cols,
    addr_out,
    addr_valid,
    addr_last,
    addr_ready
);

    parameter ADDR_WIDTH = 16;
    parameter TILE_DIM   = 64;

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    start;
    input  wire                    en;
    input  wire [ADDR_WIDTH-1:0]   base_addr;
    input  wire [ADDR_WIDTH-1:0]   row_stride;
    input  wire [7:0]              num_rows;
    input  wire [7:0]              num_cols;
    output wire [ADDR_WIDTH-1:0]   addr_out;
    output reg                     addr_valid;
    output reg                     addr_last;
    input  wire                    addr_ready;

    reg [7:0] row_cnt;
    reg [7:0] col_cnt;
    reg       active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active     <= 1'b0;
            row_cnt    <= 8'd0;
            col_cnt    <= 8'd0;
            addr_valid <= 1'b0;
            addr_last  <= 1'b0;
        end else if (start) begin
            active     <= 1'b1;
            row_cnt    <= 8'd0;
            col_cnt    <= 8'd0;
            addr_valid <= 1'b1;
            addr_last  <= 1'b0;
        end else if (active && en && addr_ready) begin
            if (col_cnt == num_cols - 8'd1) begin
                col_cnt <= 8'd0;
                if (row_cnt == num_rows - 8'd1) begin
                    active     <= 1'b0;
                    addr_valid <= 1'b0;
                    addr_last  <= 1'b1;
                end else begin
                    row_cnt <= row_cnt + 8'd1;
                end
            end else begin
                col_cnt <= col_cnt + 8'd1;
            end

            addr_last <= (col_cnt == num_cols - 8'd1) &&
                         (row_cnt == num_rows - 8'd1);
        end
    end

    assign addr_out = base_addr + ({8'b0, row_cnt} * row_stride)
                                + {8'b0, col_cnt};

endmodule
