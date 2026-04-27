// accel_controller.sv — Minimal FSM for streaming fused accelerator
//
// FSM ONLY handles boundary I/O:
//   IDLE  -> latch command
//   LOAD  -> read inputs from SRAM into tile buffers (row-major in buffer)
//   STREAM -> pulse pipeline start, wait for pipeline_done
//   WRITE -> drain output buffer to SRAM
//   DONE  -> assert done
//
// Uses a 2-process FSM:
//   - sequential block:  state, cmd_reg, counters
//   - combinational block: outputs derived from state + counters
//
// Buffer layout: wr_idx = {row[5:0], col[5:0]}, so the FSM tracks
// (load_row, load_col) and (wr_row, wr_col) separately from the linear
// SRAM-side count. This keeps the buffer's (row, col) view consistent
// with the streaming pipeline's parallel reads via mem_out.
module accel_controller
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Command input
  input  cmd_pkt_t    cmd,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  // Latched command (exposed to pipeline)
  output logic [7:0]  cmd_tile_m,
  output logic [7:0]  cmd_tile_n,
  output logic [7:0]  cmd_tile_k,
  output fused_op_t   fused_sel,

  // SRAM read/write port
  output logic        sram_req,
  output logic        sram_we,
  output logic [15:0] sram_addr,
  output logic [31:0] sram_wdata,
  input  logic [31:0] sram_rdata,
  input  logic        sram_rvalid,

  // Input buffer write ports (FSM fills these during LOAD)
  output logic        buf_a_wr_en,
  output logic        buf_b_wr_en,
  output logic [11:0] buf_wr_idx,
  output logic [31:0] buf_wr_data,

  // Output buffer read port (FSM drains during WRITE)
  output logic [11:0] out_rd_idx,
  input  logic [31:0] out_rd_data,

  // Pipeline boundary handshake
  output logic        pipeline_start,
  input  logic        pipeline_done,

  // Status
  output logic        busy,
  output logic        done
);

  typedef enum logic [2:0] {
    S_IDLE,
    S_LOAD_A,
    S_LOAD_B,
    S_STREAM_START,
    S_STREAM_WAIT,
    S_WRITE,
    S_DONE
  } state_t;

  state_t state;
  cmd_pkt_t cmd_reg;

  // Linear counters (for SRAM addressing and exit conditions)
  logic [11:0] load_cnt, write_cnt;
  // 2D counters (for buffer indexing)
  logic [7:0]  load_row, load_col;
  logic [7:0]  wr_row,   wr_col;

  logic [11:0] tile_a_size, tile_b_size, tile_out_size;
  assign tile_a_size   = {4'b0, cmd_reg.tile_m} * {4'b0, cmd_reg.tile_k};
  assign tile_b_size   = {4'b0, cmd_reg.tile_k} * {4'b0, cmd_reg.tile_n};
  assign tile_out_size = {4'b0, cmd_reg.tile_m} * {4'b0, cmd_reg.tile_n};

  assign cmd_tile_m = cmd_reg.tile_m;
  assign cmd_tile_n = cmd_reg.tile_n;
  assign cmd_tile_k = cmd_reg.tile_k;

  // Map mode to fused operation (combinational, derived from latched cmd)
  always_comb begin
    case (cmd_reg.mode)
      MODE_FFN_FWD:  fused_sel = FUSED_GELU;
      MODE_FFN_BWD:  fused_sel = FUSED_GELU_GRAD;
      MODE_ATTN_FWD: fused_sel = FUSED_SOFTMAX;
      MODE_ATTN_BWD: fused_sel = FUSED_BYPASS;
      default:       fused_sel = FUSED_BYPASS;
    endcase
  end

  // ============= Combinational outputs =============
  always_comb begin
    cmd_ready      = 1'b0;
    busy           = 1'b0;
    done           = 1'b0;
    sram_req       = 1'b0;
    sram_we        = 1'b0;
    sram_addr      = '0;
    sram_wdata     = '0;
    buf_a_wr_en    = 1'b0;
    buf_b_wr_en    = 1'b0;
    buf_wr_idx     = '0;
    buf_wr_data    = '0;
    out_rd_idx     = '0;
    pipeline_start = 1'b0;

    case (state)
      S_IDLE: begin
        cmd_ready = 1'b1;
      end

      S_LOAD_A: begin
        busy        = 1'b1;
        sram_req    = 1'b1;
        sram_we     = 1'b0;
        sram_addr   = cmd_reg.addr_a + {4'b0, load_cnt};
        buf_a_wr_en = sram_rvalid;
        buf_wr_idx  = {load_row[5:0], load_col[5:0]};
        buf_wr_data = sram_rdata;
      end

      S_LOAD_B: begin
        busy        = 1'b1;
        sram_req    = 1'b1;
        sram_we     = 1'b0;
        sram_addr   = cmd_reg.addr_b + {4'b0, load_cnt};
        buf_b_wr_en = sram_rvalid;
        buf_wr_idx  = {load_row[5:0], load_col[5:0]};
        buf_wr_data = sram_rdata;
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
        sram_addr  = cmd_reg.addr_out + {4'b0, write_cnt};
        out_rd_idx = {wr_row[5:0], wr_col[5:0]};
        sram_wdata = out_rd_data;
      end

      S_DONE: begin
        done = 1'b1;
      end

      default: ;
    endcase
  end

  // ============= Sequential state and counters =============
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      cmd_reg   <= '0;
      load_cnt  <= '0;
      write_cnt <= '0;
      load_row  <= '0;
      load_col  <= '0;
      wr_row    <= '0;
      wr_col    <= '0;
    end else begin
      case (state)
        // ----------------------------------------------------
        S_IDLE: begin
          if (cmd_valid) begin
            cmd_reg  <= cmd;
            load_cnt <= '0;
            load_row <= '0;
            load_col <= '0;
            state    <= S_LOAD_A;
          end
        end

        // ----------------------------------------------------
        // LOAD A: tile_m rows x tile_k cols. Row-major in SRAM and buffer.
        S_LOAD_A: begin
          if (sram_rvalid) begin
            if (load_cnt + 12'd1 >= tile_a_size) begin
              load_cnt <= '0;
              load_row <= '0;
              load_col <= '0;
              state    <= S_LOAD_B;
            end else begin
              load_cnt <= load_cnt + 12'd1;
              if (load_col + 8'd1 >= cmd_reg.tile_k) begin
                load_col <= '0;
                load_row <= load_row + 8'd1;
              end else begin
                load_col <= load_col + 8'd1;
              end
            end
          end
        end

        // ----------------------------------------------------
        // LOAD B: tile_k rows x tile_n cols. Row-major in SRAM and buffer.
        S_LOAD_B: begin
          if (sram_rvalid) begin
            if (load_cnt + 12'd1 >= tile_b_size) begin
              load_cnt <= '0;
              load_row <= '0;
              load_col <= '0;
              state    <= S_STREAM_START;
            end else begin
              load_cnt <= load_cnt + 12'd1;
              if (load_col + 8'd1 >= cmd_reg.tile_n) begin
                load_col <= '0;
                load_row <= load_row + 8'd1;
              end else begin
                load_col <= load_col + 8'd1;
              end
            end
          end
        end

        // ----------------------------------------------------
        // STREAM_START: pipeline_start pulses (combinational), then advance
        S_STREAM_START: begin
          state <= S_STREAM_WAIT;
        end

        // ----------------------------------------------------
        // STREAM_WAIT: pipeline runs autonomously. FSM is idle.
        // No FSM transitions during compute -- this is fusion.
        S_STREAM_WAIT: begin
          if (pipeline_done) begin
            write_cnt <= '0;
            wr_row    <= '0;
            wr_col    <= '0;
            state     <= S_WRITE;
          end
        end

        // ----------------------------------------------------
        // WRITE: tile_m x tile_n cells, row-major. Read buffer at (wr_row,wr_col),
        //   write SRAM at addr_out + write_cnt.
        S_WRITE: begin
          if (write_cnt + 12'd1 >= tile_out_size) begin
            state <= S_DONE;
          end else begin
            write_cnt <= write_cnt + 12'd1;
            if (wr_col + 8'd1 >= cmd_reg.tile_n) begin
              wr_col <= '0;
              wr_row <= wr_row + 8'd1;
            end else begin
              wr_col <= wr_col + 8'd1;
            end
          end
        end

        // ----------------------------------------------------
        S_DONE: begin
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
