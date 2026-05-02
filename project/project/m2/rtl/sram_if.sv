// sram_if.sv — Scratchpad SRAM access interface
interface sram_if #(
  parameter int DATA_WIDTH = 32,
  parameter int ADDR_WIDTH = 16
);
  logic                    req;
  logic                    we;
  logic [ADDR_WIDTH-1:0]   addr;
  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH-1:0]   rdata;
  logic                    rvalid;

  modport master (output req, we, addr, wdata, input  rdata, rvalid);
  modport slave  (input  req, we, addr, wdata, output rdata, rvalid);

endinterface
