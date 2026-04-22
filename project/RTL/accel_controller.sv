// accel_controller.sv — Top-level control FSM
// Orchestrates tile loops, triggers loaders/writers, configures fused units
module accel_controller
  import accel_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  // Command input
  input  cmd_pkt_t    cmd,
  input  logic        cmd_valid,
  output logic        cmd_ready,

  // Tile scheduler interface
  output logic        sched_start,
  input  logic        sched_done,
  input  logic        sched_tile_start,
  input  logic [7:0]  sched_tile_m,
  input  logic [7:0]  sched_tile_n,
  input  logic [7:0]  sched_tile_k,

  // Tile loader/writer control
  output logic        loader_a_start,
  output logic        loader_b_start,
  input  logic        loader_a_done,
  input  logic        loader_b_done,
  output logic        writer_start,
  input  logic        writer_done,

  // Systolic array control
  output logic        array_en,
  output logic        array_clear_acc,

  // Fused unit control
  output fused_op_t   fused_sel,

  // Address generation
  output logic [15:0] loader_a_base,
  output logic [15:0] loader_b_base,
  output logic [15:0] writer_base,

  // Status
  output logic        busy,
  output logic        done
);

  typedef enum logic [3:0] {
    FSM_IDLE,
    FSM_DECODE,
    FSM_LOAD_TILES,
    FSM_COMPUTE,
    FSM_FUSED_POST,
    FSM_WRITE_RESULT,
    FSM_NEXT_TILE,
    FSM_COMPLETE
  } fsm_t;

  fsm_t state;
  cmd_pkt_t cmd_reg;
  mode_t    current_mode;
  logic [7:0] compute_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state           <= FSM_IDLE;
      busy            <= 1'b0;
      done            <= 1'b0;
      cmd_ready       <= 1'b1;
      sched_start     <= 1'b0;
      loader_a_start  <= 1'b0;
      loader_b_start  <= 1'b0;
      writer_start    <= 1'b0;
      array_en        <= 1'b0;
      array_clear_acc <= 1'b0;
      fused_sel       <= FUSED_BYPASS;
    end else begin
      // Defaults
      sched_start    <= 1'b0;
      loader_a_start <= 1'b0;
      loader_b_start <= 1'b0;
      writer_start   <= 1'b0;
      array_clear_acc <= 1'b0;
      done           <= 1'b0;

      case (state)
        FSM_IDLE: begin
          cmd_ready <= 1'b1;
          if (cmd_valid) begin
            cmd_reg      <= cmd;
            current_mode <= cmd.mode;
            cmd_ready    <= 1'b0;
            busy         <= 1'b1;
            state        <= FSM_DECODE;
          end
        end

        FSM_DECODE: begin
          // Configure fused operation based on mode
          case (current_mode)
            MODE_FFN_FWD:  fused_sel <= FUSED_GELU;
            MODE_FFN_BWD:  fused_sel <= FUSED_GELU_GRAD;
            MODE_ATTN_FWD: fused_sel <= FUSED_SOFTMAX;
            MODE_ATTN_BWD: fused_sel <= FUSED_BYPASS;
            default:       fused_sel <= FUSED_BYPASS;
          endcase

          // Start tile scheduler
          sched_start <= 1'b1;
          state       <= FSM_LOAD_TILES;
        end

        FSM_LOAD_TILES: begin
          if (sched_tile_start) begin
            // Compute base addresses for current tile
            loader_a_base <= cmd_reg.addr_a +
                             {8'b0, sched_tile_m} * {8'b0, cmd_reg.tile_k} +
                             {8'b0, sched_tile_k};
            loader_b_base <= cmd_reg.addr_b +
                             {8'b0, sched_tile_k} * {8'b0, cmd_reg.tile_n} +
                             {8'b0, sched_tile_n};

            loader_a_start  <= 1'b1;
            loader_b_start  <= 1'b1;
            array_clear_acc <= (sched_tile_k == '0); // Clear on first K tile
            state           <= FSM_COMPUTE;
            compute_cnt     <= '0;
          end else if (sched_done) begin
            state <= FSM_COMPLETE;
          end
        end

        FSM_COMPUTE: begin
          array_en <= 1'b1;
          if (loader_a_done && loader_b_done) begin
            compute_cnt <= compute_cnt + 1;
            if (compute_cnt >= TILE_SIZE - 1) begin
              array_en <= 1'b0;
              state    <= FSM_FUSED_POST;
            end
          end
        end

        FSM_FUSED_POST: begin
          // Fused post-processing happens combinationally / pipelined
          // Wait for pipeline to drain (5 cycles for GELU)
          compute_cnt <= compute_cnt + 1;
          if (compute_cnt >= TILE_SIZE + 8'd6) begin
            state <= FSM_WRITE_RESULT;
          end
        end

        FSM_WRITE_RESULT: begin
          writer_base  <= cmd_reg.addr_out +
                          {8'b0, sched_tile_m} * {8'b0, cmd_reg.tile_n} +
                          {8'b0, sched_tile_n};
          writer_start <= 1'b1;
          if (writer_done) begin
            state <= FSM_NEXT_TILE;
          end
        end

        FSM_NEXT_TILE: begin
          state <= FSM_LOAD_TILES; // scheduler advances automatically
        end

        FSM_COMPLETE: begin
          busy  <= 1'b0;
          done  <= 1'b1;
          state <= FSM_IDLE;
        end

        default: state <= FSM_IDLE;
      endcase
    end
  end

endmodule
