// sram_bank.sv — Single SRAM bank (behavioral model)
module sram_bank
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int DEPTH      = SRAM_DEPTH,
  parameter int ADDR_WIDTH = SRAM_ADDR_W
)(
  input  logic                    clk,
  input  logic                    req,
  input  logic                    we,
  input  logic [ADDR_WIDTH-1:0]   addr,
  input  logic [DATA_WIDTH-1:0]   wdata,
  output logic [DATA_WIDTH-1:0]   rdata,
  output logic                    rvalid
);

  logic [DATA_WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    rvalid <= 1'b0;
    if (req) begin
      if (we) begin
        mem[addr] <= wdata;
      end else begin
        rdata  <= mem[addr];
        rvalid <= 1'b1;
      end
    end
  end

endmodule
