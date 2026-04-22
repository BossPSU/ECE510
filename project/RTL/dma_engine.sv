// dma_engine.sv — Host-to-chiplet data movement
// Moves tensors between host-visible memory and scratchpad
module dma_engine
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int ADDR_WIDTH = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Host-side (UCIe-facing)
  input  logic                    host_wr_valid,
  input  logic [ADDR_WIDTH-1:0]   host_wr_addr,
  input  logic [DATA_WIDTH-1:0]   host_wr_data,
  output logic                    host_wr_ready,

  input  logic                    host_rd_req,
  input  logic [ADDR_WIDTH-1:0]   host_rd_addr,
  output logic [DATA_WIDTH-1:0]   host_rd_data,
  output logic                    host_rd_valid,

  // Scratchpad-side
  output logic                    sram_req,
  output logic                    sram_we,
  output logic [ADDR_WIDTH-1:0]   sram_addr,
  output logic [DATA_WIDTH-1:0]   sram_wdata,
  input  logic [DATA_WIDTH-1:0]   sram_rdata,
  input  logic                    sram_rvalid
);

  // Simple pass-through — no buffering
  // In a real design: add burst support, double-buffering

  assign host_wr_ready = 1'b1; // Always accept writes

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sram_req <= 1'b0;
      sram_we  <= 1'b0;
    end else begin
      if (host_wr_valid) begin
        sram_req   <= 1'b1;
        sram_we    <= 1'b1;
        sram_addr  <= host_wr_addr;
        sram_wdata <= host_wr_data;
      end else if (host_rd_req) begin
        sram_req  <= 1'b1;
        sram_we   <= 1'b0;
        sram_addr <= host_rd_addr;
      end else begin
        sram_req <= 1'b0;
        sram_we  <= 1'b0;
      end
    end
  end

  assign host_rd_data  = sram_rdata;
  assign host_rd_valid = sram_rvalid;

endmodule
