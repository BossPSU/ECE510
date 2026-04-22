// csr_block.sv — Configuration/status registers
module csr_block
  import accel_pkg::*;
#(
  parameter int ADDR_WIDTH = 8,
  parameter int DATA_WIDTH = 32
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Register access (from host/DMA)
  input  logic                    wr_en,
  input  logic                    rd_en,
  input  logic [ADDR_WIDTH-1:0]   addr,
  input  logic [DATA_WIDTH-1:0]   wdata,
  output logic [DATA_WIDTH-1:0]   rdata,

  // Control outputs
  output cmd_pkt_t                cmd_out,
  output logic                    cmd_valid,
  input  logic                    cmd_ready,

  // Status inputs
  input  logic                    accel_done,
  input  logic                    accel_busy,
  input  logic [31:0]             perf_active,
  input  logic [31:0]             perf_stall,
  input  logic [31:0]             perf_tiles,

  // Interrupt
  output logic                    irq
);

  // Register map
  // 0x00: Control (write 1 to bit 0 = start)
  // 0x04: Mode
  // 0x08: Addr A
  // 0x0C: Addr B
  // 0x10: Addr Out
  // 0x14: Tile M
  // 0x18: Tile N
  // 0x1C: Tile K
  // 0x20: Seq Len
  // 0x24: Status (read-only: bit 0=done, bit 1=busy)
  // 0x28: Perf active cycles
  // 0x2C: Perf stall cycles
  // 0x30: Perf tiles completed

  logic [DATA_WIDTH-1:0] reg_ctrl;
  logic [DATA_WIDTH-1:0] reg_mode;
  logic [DATA_WIDTH-1:0] reg_addr_a;
  logic [DATA_WIDTH-1:0] reg_addr_b;
  logic [DATA_WIDTH-1:0] reg_addr_out;
  logic [DATA_WIDTH-1:0] reg_tile_m;
  logic [DATA_WIDTH-1:0] reg_tile_n;
  logic [DATA_WIDTH-1:0] reg_tile_k;
  logic [DATA_WIDTH-1:0] reg_seq_len;

  // Write
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_ctrl     <= '0;
      reg_mode     <= '0;
      reg_addr_a   <= '0;
      reg_addr_b   <= '0;
      reg_addr_out <= '0;
      reg_tile_m   <= '0;
      reg_tile_n   <= '0;
      reg_tile_k   <= '0;
      reg_seq_len  <= '0;
    end else if (wr_en) begin
      case (addr)
        8'h00: reg_ctrl     <= wdata;
        8'h04: reg_mode     <= wdata;
        8'h08: reg_addr_a   <= wdata;
        8'h0C: reg_addr_b   <= wdata;
        8'h10: reg_addr_out <= wdata;
        8'h14: reg_tile_m   <= wdata;
        8'h18: reg_tile_n   <= wdata;
        8'h1C: reg_tile_k   <= wdata;
        8'h20: reg_seq_len  <= wdata;
        default: ;
      endcase
    end else begin
      // Auto-clear start bit
      reg_ctrl[0] <= 1'b0;
    end
  end

  // Read
  always_comb begin
    case (addr)
      8'h00: rdata = reg_ctrl;
      8'h04: rdata = reg_mode;
      8'h08: rdata = reg_addr_a;
      8'h0C: rdata = reg_addr_b;
      8'h10: rdata = reg_addr_out;
      8'h14: rdata = reg_tile_m;
      8'h18: rdata = reg_tile_n;
      8'h1C: rdata = reg_tile_k;
      8'h20: rdata = reg_seq_len;
      8'h24: rdata = {30'b0, accel_busy, accel_done};
      8'h28: rdata = perf_active;
      8'h2C: rdata = perf_stall;
      8'h30: rdata = perf_tiles;
      default: rdata = '0;
    endcase
  end

  // Build command packet
  assign cmd_out.mode     = mode_t'(reg_mode[2:0]);
  assign cmd_out.addr_a   = reg_addr_a[15:0];
  assign cmd_out.addr_b   = reg_addr_b[15:0];
  assign cmd_out.addr_out = reg_addr_out[15:0];
  assign cmd_out.tile_m   = reg_tile_m[7:0];
  assign cmd_out.tile_n   = reg_tile_n[7:0];
  assign cmd_out.tile_k   = reg_tile_k[7:0];
  assign cmd_out.seq_len  = reg_seq_len[7:0];
  assign cmd_valid        = reg_ctrl[0];

  // Interrupt on completion
  assign irq = accel_done;

endmodule
