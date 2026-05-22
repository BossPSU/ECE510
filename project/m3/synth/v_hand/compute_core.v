/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// compute_core.v -- hand-flattened from project/m2/rtl/compute_core.sv
//
// Thin wrapper around accel_top exposing the M2 chip's public interface.
// =============================================================================
module compute_core #(
    parameter N_LANES         = 16,
    parameter TILE_DIM        = 64,
    parameter LANE_LOCAL_BITS = 15,
    parameter LANE_BITS       = (N_LANES <= 1) ? 1 : clog2_f(N_LANES),
    parameter DMA_ADDR_W      = LANE_LOCAL_BITS + LANE_BITS
) (
    clk,
    rst_n,
    macro_cmd_in,
    macro_cmd_valid,
    macro_cmd_ready,
    dma_wr_valid,
    dma_wr_addr,
    dma_wr_data,
    dma_wr_ready,
    dma_rd_req,
    dma_rd_addr,
    dma_rd_data,
    dma_rd_valid,
    busy,
    done,
    irq,
    perf_active_cycles,
    perf_stall_cycles,
    perf_tiles_completed
);

    localparam MACRO_W = 107;

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire [MACRO_W-1:0]      macro_cmd_in;
    input  wire                    macro_cmd_valid;
    output wire                    macro_cmd_ready;
    input  wire                    dma_wr_valid;
    input  wire [DMA_ADDR_W-1:0]   dma_wr_addr;
    input  wire [31:0]             dma_wr_data;
    output wire                    dma_wr_ready;
    input  wire                    dma_rd_req;
    input  wire [DMA_ADDR_W-1:0]   dma_rd_addr;
    output wire [31:0]             dma_rd_data;
    output wire                    dma_rd_valid;
    output wire                    busy;
    output wire                    done;
    output wire                    irq;
    output wire [31:0]             perf_active_cycles;
    output wire [31:0]             perf_stall_cycles;
    output wire [31:0]             perf_tiles_completed;

    accel_top #(
        .N_LANES        (N_LANES),
        .TILE_DIM       (TILE_DIM),
        .LANE_LOCAL_BITS(LANE_LOCAL_BITS),
        .LANE_BITS      (LANE_BITS),
        .DMA_ADDR_W     (DMA_ADDR_W)
    ) u_accel_top (
        .clk                  (clk),
        .rst_n                (rst_n),
        .macro_cmd_in         (macro_cmd_in),
        .macro_cmd_valid      (macro_cmd_valid),
        .macro_cmd_ready      (macro_cmd_ready),
        .dma_wr_valid         (dma_wr_valid),
        .dma_wr_addr          (dma_wr_addr),
        .dma_wr_data          (dma_wr_data),
        .dma_wr_ready         (dma_wr_ready),
        .dma_rd_req           (dma_rd_req),
        .dma_rd_addr          (dma_rd_addr),
        .dma_rd_data          (dma_rd_data),
        .dma_rd_valid         (dma_rd_valid),
        .busy                 (busy),
        .done                 (done),
        .irq                  (irq),
        .perf_active_cycles   (perf_active_cycles),
        .perf_stall_cycles    (perf_stall_cycles),
        .perf_tiles_completed (perf_tiles_completed)
    );

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
