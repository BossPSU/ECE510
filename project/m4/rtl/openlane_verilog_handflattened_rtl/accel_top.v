/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// accel_top.v -- hand-flattened from project/m2/rtl/accel_top.sv
//
// Multi-lane, data-parallel top: tile_dispatcher + N_LANES x accel_engine +
// N_LANES x scratchpad_ctrl + dma_engine. macro_cmd_t / cmd_pkt_t arrive as
// flat buses; per-lane arrays are packed.
//
// Sizing for the M3 OpenLane scope-down: instantiate with N_LANES=1,
// TILE_DIM=4 via top-level parameter overrides. Default values mirror the
// full chip (16, 64).
// =============================================================================
module accel_top #(
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
    localparam CMD_W   = 99;

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

    output reg  [31:0]             perf_active_cycles;
    output reg  [31:0]             perf_stall_cycles;
    output reg  [31:0]             perf_tiles_completed;

    // ===== Dispatcher <-> per-lane buses =====
    wire [(N_LANES*CMD_W)-1:0] lane_cmd;
    wire [N_LANES-1:0]         lane_cmd_valid;
    wire [N_LANES-1:0]         lane_cmd_ready;
    wire [N_LANES-1:0]         lane_done;
    wire [N_LANES-1:0]         lane_busy;

    // Per-lane scratchpad SRAM ports
    wire [N_LANES-1:0]         lane_sram_req;
    wire [N_LANES-1:0]         lane_sram_we;
    wire [(N_LANES*16)-1:0]    lane_sram_addr;
    wire [(N_LANES*32)-1:0]    lane_sram_wdata;
    wire [(N_LANES*32)-1:0]    lane_sram_rdata;
    wire [N_LANES-1:0]         lane_sram_rvalid;

    wire [(N_LANES*32)-1:0]    lane_perf_active;
    wire [(N_LANES*32)-1:0]    lane_perf_stall;
    wire [(N_LANES*32)-1:0]    lane_perf_tiles;

    // ===== Tile dispatcher =====
    wire dispatcher_done;
    tile_dispatcher #(
        .N_LANES (N_LANES),
        .TILE_DIM(TILE_DIM)
    ) u_dispatcher (
        .clk            (clk),
        .rst_n          (rst_n),
        .macro_cmd      (macro_cmd_in),
        .macro_valid    (macro_cmd_valid),
        .macro_ready    (macro_cmd_ready),
        .macro_done     (dispatcher_done),
        .lane_cmd       (lane_cmd),
        .lane_cmd_valid (lane_cmd_valid),
        .lane_cmd_ready (lane_cmd_ready),
        .lane_done      (lane_done)
    );

    // ===== DMA engine =====
    wire                    dma_sram_req, dma_sram_we;
    wire [DMA_ADDR_W-1:0]   dma_sram_addr;
    wire [31:0]             dma_sram_wdata, dma_sram_rdata;
    wire                    dma_sram_rvalid;

    dma_engine #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (DMA_ADDR_W)
    ) u_dma (
        .clk           (clk),
        .rst_n         (rst_n),
        .host_wr_valid (dma_wr_valid),
        .host_wr_addr  (dma_wr_addr),
        .host_wr_data  (dma_wr_data),
        .host_wr_ready (dma_wr_ready),
        .host_rd_req   (dma_rd_req),
        .host_rd_addr  (dma_rd_addr),
        .host_rd_data  (dma_rd_data),
        .host_rd_valid (dma_rd_valid),
        .sram_req      (dma_sram_req),
        .sram_we       (dma_sram_we),
        .sram_addr     (dma_sram_addr),
        .sram_wdata    (dma_sram_wdata),
        .sram_rdata    (dma_sram_rdata),
        .sram_rvalid   (dma_sram_rvalid)
    );

    // Lane id from upper DMA addr bits; lower bits are the lane-local addr.
    wire [LANE_BITS-1:0]       dma_lane_sel   =
        dma_sram_addr[LANE_LOCAL_BITS +: LANE_BITS];
    wire [LANE_LOCAL_BITS-1:0] dma_local_addr =
        dma_sram_addr[LANE_LOCAL_BITS-1:0];

    // ===== Per-lane DMA-side fan-out (only the addressed bank sees a req) =====
    reg  [N_LANES-1:0]      bank_dma_req;
    reg  [N_LANES-1:0]      bank_dma_we;
    reg  [(N_LANES*16)-1:0] bank_dma_addr;
    reg  [(N_LANES*32)-1:0] bank_dma_wdata;
    wire [(N_LANES*32)-1:0] bank_dma_rdata;
    wire [N_LANES-1:0]      bank_dma_rvalid;

    integer di;
    always @* begin
        for (di = 0; di < N_LANES; di = di + 1) begin
            bank_dma_req[di]                 = 1'b0;
            bank_dma_we[di]                  = 1'b0;
            bank_dma_addr[(di*16) +: 16]     = 16'h0;
            bank_dma_wdata[(di*32) +: 32]    = 32'h0;
        end
        bank_dma_req[dma_lane_sel]            = dma_sram_req;
        bank_dma_we[dma_lane_sel]             = dma_sram_we;
        bank_dma_addr[(dma_lane_sel*16) +: 16] =
            {{(16-LANE_LOCAL_BITS){1'b0}}, dma_local_addr};
        bank_dma_wdata[(dma_lane_sel*32) +: 32] = dma_sram_wdata;
    end

    // Read-side: register the lane select to align with scratchpad's
    // 1-cycle read latency, then mux back.
    reg [LANE_BITS-1:0] dma_lane_sel_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) dma_lane_sel_q <= {LANE_BITS{1'b0}};
        else        dma_lane_sel_q <= dma_lane_sel;
    end
    assign dma_sram_rdata  =
        bank_dma_rdata[(dma_lane_sel_q*32) +: 32];
    assign dma_sram_rvalid = bank_dma_rvalid[dma_lane_sel_q];

    // ===== Lanes =====
    genvar gl;
    generate
        for (gl = 0; gl < N_LANES; gl = gl + 1) begin : gen_lane
            accel_engine #(
                .TILE_DIM (TILE_DIM)
            ) u_engine (
                .clk                  (clk),
                .rst_n                (rst_n),
                .cmd_in               (lane_cmd[(gl*CMD_W) +: CMD_W]),
                .cmd_valid            (lane_cmd_valid[gl]),
                .cmd_ready            (lane_cmd_ready[gl]),
                .sram_req             (lane_sram_req[gl]),
                .sram_we              (lane_sram_we[gl]),
                .sram_addr            (lane_sram_addr[(gl*16) +: 16]),
                .sram_wdata           (lane_sram_wdata[(gl*32) +: 32]),
                .sram_rdata           (lane_sram_rdata[(gl*32) +: 32]),
                .sram_rvalid          (lane_sram_rvalid[gl]),
                .busy                 (lane_busy[gl]),
                .done                 (lane_done[gl]),
                .perf_active_cycles   (lane_perf_active[(gl*32) +: 32]),
                .perf_stall_cycles    (lane_perf_stall [(gl*32) +: 32]),
                .perf_tiles_completed (lane_perf_tiles [(gl*32) +: 32])
            );

            scratchpad_ctrl u_bank (
                .clk     (clk),
                .rst_n   (rst_n),
                .a_req   (lane_sram_req[gl] && !lane_sram_we[gl]),
                .a_addr  (lane_sram_addr[(gl*16) +: 16]),
                .a_rdata (lane_sram_rdata[(gl*32) +: 32]),
                .a_rvalid(lane_sram_rvalid[gl]),
                .b_req   (lane_sram_req[gl] && lane_sram_we[gl]),
                .b_we    (lane_sram_we[gl]),
                .b_addr  (lane_sram_addr[(gl*16) +: 16]),
                .b_wdata (lane_sram_wdata[(gl*32) +: 32]),
                .c_req   (bank_dma_req[gl]),
                .c_we    (bank_dma_we[gl]),
                .c_addr  (bank_dma_addr[(gl*16) +: 16]),
                .c_wdata (bank_dma_wdata[(gl*32) +: 32]),
                .c_rdata (bank_dma_rdata[(gl*32) +: 32]),
                .c_rvalid(bank_dma_rvalid[gl])
            );
        end
    endgenerate

    // ===== Aggregate status / perf =====
    reg any_busy;
    integer li;
    always @* begin
        any_busy = 1'b0;
        for (li = 0; li < N_LANES; li = li + 1)
            if (lane_busy[li]) any_busy = 1'b1;
    end
    assign busy = any_busy || !macro_cmd_ready;
    assign done = dispatcher_done;
    assign irq  = dispatcher_done;

    always @* begin
        perf_active_cycles   = 32'h0;
        perf_stall_cycles    = 32'h0;
        perf_tiles_completed = 32'h0;
        for (li = 0; li < N_LANES; li = li + 1) begin
            perf_active_cycles   = perf_active_cycles   +
                lane_perf_active[(li*32) +: 32];
            perf_stall_cycles    = perf_stall_cycles    +
                lane_perf_stall [(li*32) +: 32];
            perf_tiles_completed = perf_tiles_completed +
                lane_perf_tiles [(li*32) +: 32];
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
