/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// accel_controller.v -- hand-flattened from project/m2/rtl/accel_controller.sv
//
// Per-lane FSM driving boundary I/O (LOAD A/B/AUX -> STREAM -> WRITE).
// 8-state encoding inlined as localparams (was typedef enum).
// cmd_pkt_t fields sliced out of the 99-bit packed bus.
// =============================================================================
module accel_controller (
    clk,
    rst_n,
    cmd,
    cmd_valid,
    cmd_ready,
    cmd_tile_m,
    cmd_tile_n,
    cmd_tile_k,
    fused_sel,
    sram_req,
    sram_we,
    sram_addr,
    sram_wdata,
    sram_rdata,
    sram_rvalid,
    buf_a_wr_en,
    buf_b_wr_en,
    buf_aux_wr_en,
    buf_wr_idx,
    buf_wr_data,
    out_rd_idx,
    out_rd_data,
    pipeline_start,
    pipeline_done,
    busy,
    done
);

    // mode_t encoding
    localparam [2:0] MODE_FFN_FWD  = 3'd0;
    localparam [2:0] MODE_FFN_BWD  = 3'd1;
    localparam [2:0] MODE_ATTN_FWD = 3'd2;
    localparam [2:0] MODE_ATTN_BWD = 3'd3;

    // fused_op_t encoding
    localparam [2:0] FUSED_BYPASS    = 3'd0;
    localparam [2:0] FUSED_GELU      = 3'd1;
    localparam [2:0] FUSED_GELU_GRAD = 3'd2;
    localparam [2:0] FUSED_SOFTMAX   = 3'd3;

    // State encoding (was typedef enum logic [3:0])
    localparam [3:0] S_IDLE         = 4'd0;
    localparam [3:0] S_LOAD_A       = 4'd1;
    localparam [3:0] S_LOAD_B       = 4'd2;
    localparam [3:0] S_LOAD_AUX     = 4'd3;
    localparam [3:0] S_STREAM_START = 4'd4;
    localparam [3:0] S_STREAM_WAIT  = 4'd5;
    localparam [3:0] S_WRITE        = 4'd6;
    localparam [3:0] S_DONE         = 4'd7;

    // cmd_pkt_t packed layout (99 bits, LSB->MSB):
    //   [  0 +:  3] mode
    //   [  3 +: 16] addr_a
    //   [ 19 +: 16] addr_b
    //   [ 35 +: 16] addr_aux
    //   [ 51 +: 16] addr_out
    //   [ 67 +:  8] tile_m
    //   [ 75 +:  8] tile_n
    //   [ 83 +:  8] tile_k
    //   [ 91 +:  8] seq_len
    localparam CMD_W = 99;

    input  wire             clk;
    input  wire             rst_n;
    input  wire [CMD_W-1:0] cmd;
    input  wire             cmd_valid;
    output reg              cmd_ready;
    output wire [7:0]       cmd_tile_m;
    output wire [7:0]       cmd_tile_n;
    output wire [7:0]       cmd_tile_k;
    output reg  [2:0]       fused_sel;
    output reg              sram_req;
    output reg              sram_we;
    output reg  [15:0]      sram_addr;
    output reg  [31:0]      sram_wdata;
    input  wire [31:0]      sram_rdata;
    input  wire             sram_rvalid;
    output reg              buf_a_wr_en;
    output reg              buf_b_wr_en;
    output reg              buf_aux_wr_en;
    output reg  [11:0]      buf_wr_idx;
    output reg  [31:0]      buf_wr_data;
    output reg  [11:0]      out_rd_idx;
    input  wire [31:0]      out_rd_data;
    output reg              pipeline_start;
    input  wire             pipeline_done;
    output reg              busy;
    output reg              done;

    reg [3:0]       state;
    reg [CMD_W-1:0] cmd_reg;

    // M3-verified fix: widen counters and tile_size from 12 -> 13 bits.
    // 64*64 = 4096 = 13'h1000 overflows a 12-bit register to 12'h000=0,
    // which caused the LOAD/WRITE FSMs to exit after a single cycle.
    // See project/RTL/accel_controller.sv for the original SystemVerilog
    // fix (commit 199c40d).
    reg [12:0] load_cnt, write_cnt;
    reg [7:0]  load_row, load_col;
    reg [7:0]  wr_row,   wr_col;

    // Cmd-register slices for readability.
    wire [2:0]  cmd_reg_mode    = cmd_reg[2:0];
    wire [15:0] cmd_reg_addr_a  = cmd_reg[3 +: 16];
    wire [15:0] cmd_reg_addr_b  = cmd_reg[19 +: 16];
    wire [15:0] cmd_reg_addr_au = cmd_reg[35 +: 16];
    wire [15:0] cmd_reg_addr_o  = cmd_reg[51 +: 16];
    wire [7:0]  cmd_reg_tile_m  = cmd_reg[67 +: 8];
    wire [7:0]  cmd_reg_tile_n  = cmd_reg[75 +: 8];
    wire [7:0]  cmd_reg_tile_k  = cmd_reg[83 +: 8];

    wire [12:0] tile_a_size   = {5'b0, cmd_reg_tile_m} *
                                {5'b0, cmd_reg_tile_k};
    wire [12:0] tile_b_size   = {5'b0, cmd_reg_tile_k} *
                                {5'b0, cmd_reg_tile_n};
    wire [12:0] tile_out_size = {5'b0, cmd_reg_tile_m} *
                                {5'b0, cmd_reg_tile_n};

    assign cmd_tile_m = cmd_reg_tile_m;
    assign cmd_tile_n = cmd_reg_tile_n;
    assign cmd_tile_k = cmd_reg_tile_k;

    // Mode -> fused_sel combinational map.
    always @* begin
        case (cmd_reg_mode)
            MODE_FFN_FWD:  fused_sel = FUSED_GELU;
            MODE_FFN_BWD:  fused_sel = FUSED_GELU_GRAD;
            MODE_ATTN_FWD: fused_sel = FUSED_SOFTMAX;
            MODE_ATTN_BWD: fused_sel = FUSED_BYPASS;
            default:       fused_sel = FUSED_BYPASS;
        endcase
    end

    // ===== Combinational outputs =====
    always @* begin
        cmd_ready      = 1'b0;
        busy           = 1'b0;
        done           = 1'b0;
        sram_req       = 1'b0;
        sram_we        = 1'b0;
        sram_addr      = 16'h0;
        sram_wdata     = 32'h0;
        buf_a_wr_en    = 1'b0;
        buf_b_wr_en    = 1'b0;
        buf_aux_wr_en  = 1'b0;
        buf_wr_idx     = 12'h0;
        buf_wr_data    = 32'h0;
        out_rd_idx     = 12'h0;
        pipeline_start = 1'b0;

        case (state)
            S_IDLE: begin
                cmd_ready = 1'b1;
            end
            S_LOAD_A: begin
                busy        = 1'b1;
                sram_req    = 1'b1;
                sram_addr   = cmd_reg_addr_a + {3'b0, load_cnt};
                buf_a_wr_en = sram_rvalid;
                buf_wr_idx  = {load_row[5:0], load_col[5:0]};
                buf_wr_data = sram_rdata;
            end
            S_LOAD_B: begin
                busy        = 1'b1;
                sram_req    = 1'b1;
                sram_addr   = cmd_reg_addr_b + {3'b0, load_cnt};
                buf_b_wr_en = sram_rvalid;
                buf_wr_idx  = {load_row[5:0], load_col[5:0]};
                buf_wr_data = sram_rdata;
            end
            S_LOAD_AUX: begin
                busy          = 1'b1;
                sram_req      = 1'b1;
                sram_addr     = cmd_reg_addr_au + {3'b0, load_cnt};
                buf_aux_wr_en = sram_rvalid;
                buf_wr_idx    = {load_row[5:0], load_col[5:0]};
                buf_wr_data   = sram_rdata;
            end
            S_STREAM_START: begin
                busy           = 1'b1;
                pipeline_start = 1'b1;
            end
            S_STREAM_WAIT: begin
                busy = 1'b1;
            end
            S_WRITE: begin
                busy       = 1'b1;
                sram_req   = 1'b1;
                sram_we    = 1'b1;
                sram_addr  = cmd_reg_addr_o + {3'b0, write_cnt};
                out_rd_idx = {wr_row[5:0], wr_col[5:0]};
                sram_wdata = out_rd_data;
            end
            S_DONE: begin
                done = 1'b1;
            end
            default: ;
        endcase
    end

    // ===== Sequential state machine =====
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cmd_reg   <= {CMD_W{1'b0}};
            load_cnt  <= 13'd0;
            write_cnt <= 13'd0;
            load_row  <= 8'd0;
            load_col  <= 8'd0;
            wr_row    <= 8'd0;
            wr_col    <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        cmd_reg  <= cmd;
                        load_cnt <= 13'd0;
                        load_row <= 8'd0;
                        load_col <= 8'd0;
                        state    <= S_LOAD_A;
                    end
                end
                S_LOAD_A: begin
                    if (sram_rvalid) begin
                        if (load_cnt + 13'd1 >= tile_a_size) begin
                            load_cnt <= 13'd0;
                            load_row <= 8'd0;
                            load_col <= 8'd0;
                            state    <= S_LOAD_B;
                        end else begin
                            load_cnt <= load_cnt + 13'd1;
                            if (load_col + 8'd1 >= cmd_reg_tile_k) begin
                                load_col <= 8'd0;
                                load_row <= load_row + 8'd1;
                            end else begin
                                load_col <= load_col + 8'd1;
                            end
                        end
                    end
                end
                S_LOAD_B: begin
                    if (sram_rvalid) begin
                        if (load_cnt + 13'd1 >= tile_b_size) begin
                            load_cnt <= 13'd0;
                            load_row <= 8'd0;
                            load_col <= 8'd0;
                            if (cmd_reg_mode == MODE_FFN_BWD)
                                state <= S_LOAD_AUX;
                            else
                                state <= S_STREAM_START;
                        end else begin
                            load_cnt <= load_cnt + 13'd1;
                            if (load_col + 8'd1 >= cmd_reg_tile_n) begin
                                load_col <= 8'd0;
                                load_row <= load_row + 8'd1;
                            end else begin
                                load_col <= load_col + 8'd1;
                            end
                        end
                    end
                end
                S_LOAD_AUX: begin
                    if (sram_rvalid) begin
                        if (load_cnt + 13'd1 >= tile_out_size) begin
                            load_cnt <= 13'd0;
                            load_row <= 8'd0;
                            load_col <= 8'd0;
                            state    <= S_STREAM_START;
                        end else begin
                            load_cnt <= load_cnt + 13'd1;
                            if (load_col + 8'd1 >= cmd_reg_tile_n) begin
                                load_col <= 8'd0;
                                load_row <= load_row + 8'd1;
                            end else begin
                                load_col <= load_col + 8'd1;
                            end
                        end
                    end
                end
                S_STREAM_START: begin
                    state <= S_STREAM_WAIT;
                end
                S_STREAM_WAIT: begin
                    if (pipeline_done) begin
                        write_cnt <= 13'd0;
                        wr_row    <= 8'd0;
                        wr_col    <= 8'd0;
                        state     <= S_WRITE;
                    end
                end
                S_WRITE: begin
                    if (write_cnt + 13'd1 >= tile_out_size) begin
                        state <= S_DONE;
                    end else begin
                        write_cnt <= write_cnt + 13'd1;
                        if (wr_col + 8'd1 >= cmd_reg_tile_n) begin
                            wr_col <= 8'd0;
                            wr_row <= wr_row + 8'd1;
                        end else begin
                            wr_col <= wr_col + 8'd1;
                        end
                    end
                end
                S_DONE: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
