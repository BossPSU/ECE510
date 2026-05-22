/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// tile_buffer.v -- hand-flattened from project/m2/rtl/tile_buffer.sv
//
// TILE_DIM x TILE_DIM Q16.16 register file with:
//   * a write port (linear 12-bit index, top 6 bits = row, bottom 6 = col)
//   * a single-element 2D read port
//   * a single-element linear read port
//   * NUM_RD_PORTS parallel scattered read ports
//
// Conversions:
//   - 2D `mem [TILE_DIM][TILE_DIM]` flattened to linear `[0:N-1]` for
//     friendlier yosys memory inference;
//   - multi-port arrays on the boundary lowered to packed buses;
//   - The 12-bit (rd_lin_idx, wr_idx) indexing convention is preserved:
//     row = idx[11:6], col = idx[5:0], so callers wired for TILE_DIM=64 still
//     work, and scoped builds (TILE_DIM=4) just ignore upper address bits.
// =============================================================================
module tile_buffer (
    clk,
    rst_n,
    wr_en,
    wr_idx,
    wr_data,
    rd_row,
    rd_col,
    rd_data,
    rd_lin_idx,
    rd_lin_data,
    mp_rd_row,
    mp_rd_col,
    mp_rd_data
);

    parameter DATA_WIDTH   = 32;
    parameter TILE_DIM     = 64;
    parameter NUM_RD_PORTS = 1;

    input  wire                       clk;
    input  wire                       rst_n;
    input  wire                       wr_en;
    input  wire [11:0]                wr_idx;
    input  wire [DATA_WIDTH-1:0]      wr_data;

    input  wire [7:0]                 rd_row;
    input  wire [7:0]                 rd_col;
    output wire [DATA_WIDTH-1:0]      rd_data;

    input  wire [11:0]                rd_lin_idx;
    output wire [DATA_WIDTH-1:0]      rd_lin_data;

    input  wire [(NUM_RD_PORTS*8)-1:0]              mp_rd_row;
    input  wire [(NUM_RD_PORTS*8)-1:0]              mp_rd_col;
    output wire [(NUM_RD_PORTS*DATA_WIDTH)-1:0]     mp_rd_data;

    // Flattened storage: mem[row*TILE_DIM + col].
    reg [DATA_WIDTH-1:0] mem [0:(TILE_DIM*TILE_DIM)-1];

    integer init_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (init_i = 0;
                 init_i < TILE_DIM*TILE_DIM;
                 init_i = init_i + 1)
                mem[init_i] <= {DATA_WIDTH{1'b0}};
        end else if (wr_en) begin
            // Use the lower bits of the row/col fields that actually fit
            // in TILE_DIM (the slicing math is constant-folded at elab).
            mem[(wr_idx[11:6] * TILE_DIM) + wr_idx[5:0]] <= wr_data;
        end
    end

    // Single-element reads (combinational)
    assign rd_data     = mem[(rd_row[5:0] * TILE_DIM) + rd_col[5:0]];
    assign rd_lin_data =
        mem[(rd_lin_idx[11:6] * TILE_DIM) + rd_lin_idx[5:0]];

    // ----- Multi-port scattered reads -----
    // Each parallel port has its own (row, col) input -- slice them out of
    // the packed buses and present the result on the corresponding
    // mp_rd_data slot.
    genvar p;
    generate
        for (p = 0; p < NUM_RD_PORTS; p = p + 1) begin : gen_rd_port
            wire [7:0] r = mp_rd_row[(p*8) +: 8];
            wire [7:0] c = mp_rd_col[(p*8) +: 8];
            assign mp_rd_data[(p*DATA_WIDTH) +: DATA_WIDTH] =
                mem[(r[5:0] * TILE_DIM) + c[5:0]];
        end
    endgenerate

endmodule
