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

  // Latched command dimensions (exposed for scheduler and loaders)
  output logic [7:0]  cmd_tile_m,
  output logic [7:0]  cmd_tile_n,
  output logic [7:0]  cmd_tile_k,
  output logic [15:0] cmd_addr_a,
  output logic [15:0] cmd_addr_b,
  output logic [15:0] cmd_addr_out,

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
    FSM_WAIT_LOAD,
    FSM_COMPUTE,
    FSM_WAIT_WRITE,
    FSM_NEXT_TILE,
    FSM_COMPLETE
  } fsm_t;

  fsm_t state;
  mode_t    current_mode;
  logic [7:0] compute_cnt;
  logic [7:0] total_compute_cycles;

  // Latch done pulses so they aren't missed
  logic loader_a_done_r, loader_b_done_r, writer_done_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      loader_a_done_r <= 1'b0;
      loader_b_done_r <= 1'b0;
      writer_done_r   <= 1'b0;
    end else begin
      if (loader_a_start) loader_a_done_r <= 1'b0;
      else if (loader_a_done) loader_a_done_r <= 1'b1;

      if (loader_b_start) loader_b_done_r <= 1'b0;
      else if (loader_b_done) loader_b_done_r <= 1'b1;

      if (writer_start) writer_done_r <= 1'b0;
      else if (writer_done) writer_done_r <= 1'b1;
    end
  end

  // Total compute cycles: tile_k * 2 (for systolic drain) + 10 (fused pipeline drain)
  assign total_compute_cycles = {cmd_tile_k[6:0], 1'b0} + 8'd10;

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
      current_mode    <= MODE_IDLE;
      cmd_tile_m      <= '0;
      cmd_tile_n      <= '0;
      cmd_tile_k      <= '0;
      cmd_addr_a      <= '0;
      cmd_addr_b      <= '0;
      cmd_addr_out    <= '0;
      compute_cnt     <= '0;
    end else begin
      // Defaults — single-cycle pulses
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
            // Latch entire command
            current_mode <= cmd.mode;
            cmd_tile_m   <= cmd.tile_m;
            cmd_tile_n   <= cmd.tile_n;
            cmd_tile_k   <= cmd.tile_k;
            cmd_addr_a   <= cmd.addr_a;
            cmd_addr_b   <= cmd.addr_b;
            cmd_addr_out <= cmd.addr_out;
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
            loader_a_base <= cmd_addr_a;
            loader_b_base <= cmd_addr_b;

            loader_a_start  <= 1'b1;
            loader_b_start  <= 1'b1;
            array_clear_acc <= 1'b1;
            state           <= FSM_WAIT_LOAD;
          end else if (sched_done) begin
            state <= FSM_COMPLETE;
          end
        end

        FSM_WAIT_LOAD: begin
          // Wait for both loaders to finish
          if (loader_a_done_r && loader_b_done_r) begin
            compute_cnt <= '0;
            array_en    <= 1'b1;
            // Start writer immediately — it will capture fused output as it streams
            writer_base  <= cmd_addr_out;
            writer_start <= 1'b1;
            state        <= FSM_COMPUTE;
          end
        end

        FSM_COMPUTE: begin
          // Array stays enabled, fused output streams to writer in real-time
          array_en    <= 1'b1;
          compute_cnt <= compute_cnt + 1;

          // Run for enough cycles: systolic drain + fused pipeline drain
          if (compute_cnt >= total_compute_cycles) begin
            array_en    <= 1'b0;
            compute_cnt <= '0;
            state       <= FSM_WAIT_WRITE;
          end
        end

        FSM_WAIT_WRITE: begin
          // Writer should have captured all data during compute
          // Give it a few more cycles, then check done
          compute_cnt <= compute_cnt + 1;
          if (writer_done_r || compute_cnt >= 8'd20) begin
            compute_cnt <= '0;
            state       <= FSM_NEXT_TILE;
          end
        end

        FSM_NEXT_TILE: begin
          // Check if scheduler has more tiles
          if (sched_done) begin
            state <= FSM_COMPLETE;
          end else begin
            state <= FSM_LOAD_TILES;
          end
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
