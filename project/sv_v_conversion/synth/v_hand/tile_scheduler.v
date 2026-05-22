/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// tile_scheduler.v -- hand-flattened from project/m2/rtl/tile_scheduler.sv
//
// Iterates (m, n, k) tile indices for a matmul of dimensions (dim_m, dim_n,
// dim_k) tiled at TILE_DIM. Issues `tile_start` on transitions to each new
// (m,n,k) coordinate, waits for `tile_done`, advances. `all_done` pulses on
// the last tile.
//
// SV typedef enum replaced with localparam state encoding.
// =============================================================================
module tile_scheduler (
    clk,
    rst_n,
    start,
    tile_done,
    dim_m,
    dim_n,
    dim_k,
    tile_m_idx,
    tile_n_idx,
    tile_k_idx,
    tile_start,
    all_done,
    active
);

    parameter TILE_DIM = 64;
    localparam TILE_SHIFT = clog2_f(TILE_DIM);

    // State encoding (was `typedef enum` in SV)
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_ISSUE = 2'd1;
    localparam [1:0] S_WAIT  = 2'd2;
    localparam [1:0] S_DONE  = 2'd3;

    input  wire        clk;
    input  wire        rst_n;
    input  wire        start;
    input  wire        tile_done;
    input  wire [7:0]  dim_m;
    input  wire [7:0]  dim_n;
    input  wire [7:0]  dim_k;
    output reg  [7:0]  tile_m_idx;
    output reg  [7:0]  tile_n_idx;
    output reg  [7:0]  tile_k_idx;
    output reg         tile_start;
    output reg         all_done;
    output reg         active;

    wire [7:0] num_m_tiles;
    wire [7:0] num_n_tiles;
    wire [7:0] num_k_tiles;
    assign num_m_tiles = (dim_m + TILE_DIM - 1) >> TILE_SHIFT;
    assign num_n_tiles = (dim_n + TILE_DIM - 1) >> TILE_SHIFT;
    assign num_k_tiles = (dim_k + TILE_DIM - 1) >> TILE_SHIFT;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tile_m_idx <= 8'd0;
            tile_n_idx <= 8'd0;
            tile_k_idx <= 8'd0;
            tile_start <= 1'b0;
            all_done   <= 1'b0;
            active     <= 1'b0;
        end else begin
            tile_start <= 1'b0;
            all_done   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        tile_m_idx <= 8'd0;
                        tile_n_idx <= 8'd0;
                        tile_k_idx <= 8'd0;
                        state      <= S_ISSUE;
                        active     <= 1'b1;
                    end
                end
                S_ISSUE: begin
                    tile_start <= 1'b1;
                    state      <= S_WAIT;
                end
                S_WAIT: begin
                    if (tile_done) begin
                        if (tile_k_idx < num_k_tiles - 8'd1) begin
                            tile_k_idx <= tile_k_idx + 8'd1;
                            state      <= S_ISSUE;
                        end else if (tile_n_idx < num_n_tiles - 8'd1) begin
                            tile_k_idx <= 8'd0;
                            tile_n_idx <= tile_n_idx + 8'd1;
                            state      <= S_ISSUE;
                        end else if (tile_m_idx < num_m_tiles - 8'd1) begin
                            tile_k_idx <= 8'd0;
                            tile_n_idx <= 8'd0;
                            tile_m_idx <= tile_m_idx + 8'd1;
                            state      <= S_ISSUE;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end
                S_DONE: begin
                    all_done <= 1'b1;
                    active   <= 1'b0;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    function integer clog2_f;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2_f = 0;
            while (v > 0) begin v = v >> 1; clog2_f = clog2_f + 1; end
        end
    endfunction

endmodule
