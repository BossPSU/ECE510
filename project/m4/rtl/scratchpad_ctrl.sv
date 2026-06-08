// scratchpad_ctrl.sv — Controller for banked on-chip SRAM scratchpad
module scratchpad_ctrl
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32,
  parameter int NUM_BANKS  = SRAM_BANKS,
  parameter int BANK_DEPTH = SRAM_DEPTH,
  parameter int ADDR_WIDTH = 16
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // Port A: tile loader reads
  input  logic                    a_req,
  input  logic [ADDR_WIDTH-1:0]   a_addr,
  output logic [DATA_WIDTH-1:0]   a_rdata,
  output logic                    a_rvalid,

  // Port B: tile writer writes
  input  logic                    b_req,
  input  logic                    b_we,
  input  logic [ADDR_WIDTH-1:0]   b_addr,
  input  logic [DATA_WIDTH-1:0]   b_wdata,

  // Port C: DMA / host access
  input  logic                    c_req,
  input  logic                    c_we,
  input  logic [ADDR_WIDTH-1:0]   c_addr,
  input  logic [DATA_WIDTH-1:0]   c_wdata,
  output logic [DATA_WIDTH-1:0]   c_rdata,
  output logic                    c_rvalid
);

  localparam int BANK_ADDR_W = $clog2(BANK_DEPTH);
  localparam int BANK_SEL_W  = $clog2(NUM_BANKS);

  // Bank select = lower bits of address
  wire [BANK_SEL_W-1:0] a_bank = a_addr[BANK_SEL_W-1:0];
  wire [BANK_ADDR_W-1:0] a_bank_addr = a_addr[BANK_SEL_W +: BANK_ADDR_W];
  wire [BANK_SEL_W-1:0] b_bank = b_addr[BANK_SEL_W-1:0];
  wire [BANK_ADDR_W-1:0] b_bank_addr = b_addr[BANK_SEL_W +: BANK_ADDR_W];
  wire [BANK_SEL_W-1:0] c_bank = c_addr[BANK_SEL_W-1:0];
  wire [BANK_ADDR_W-1:0] c_bank_addr = c_addr[BANK_SEL_W +: BANK_ADDR_W];

  // Per-bank signals
  logic                    bank_req   [NUM_BANKS];
  logic                    bank_we    [NUM_BANKS];
  logic [BANK_ADDR_W-1:0]  bank_addr  [NUM_BANKS];
  logic [DATA_WIDTH-1:0]   bank_wdata [NUM_BANKS];
  logic [DATA_WIDTH-1:0]   bank_rdata [NUM_BANKS];
  logic                    bank_rvalid[NUM_BANKS];

  // Instantiate banks
  genvar i;
  generate
    for (i = 0; i < NUM_BANKS; i++) begin : gen_bank
      sram_bank #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (BANK_DEPTH),
        .ADDR_WIDTH (BANK_ADDR_W)
      ) u_bank (
        .clk    (clk),
        .req    (bank_req[i]),
        .we     (bank_we[i]),
        .addr   (bank_addr[i]),
        .wdata  (bank_wdata[i]),
        .rdata  (bank_rdata[i]),
        .rvalid (bank_rvalid[i])
      );
    end
  endgenerate

  // Simple priority arbiter: Port A (read) > Port B (write) > Port C (DMA)
  always_comb begin
    for (int b = 0; b < NUM_BANKS; b++) begin
      bank_req[b]   = 1'b0;
      bank_we[b]    = 1'b0;
      bank_addr[b]  = '0;
      bank_wdata[b] = '0;

      if (a_req && int'(a_bank) == b) begin
        bank_req[b]  = 1'b1;
        bank_we[b]   = 1'b0;
        bank_addr[b] = a_bank_addr;
      end else if (b_req && int'(b_bank) == b) begin
        bank_req[b]   = 1'b1;
        bank_we[b]    = b_we;
        bank_addr[b]  = b_bank_addr;
        bank_wdata[b] = b_wdata;
      end else if (c_req && int'(c_bank) == b) begin
        bank_req[b]   = 1'b1;
        bank_we[b]    = c_we;
        bank_addr[b]  = c_bank_addr;
        bank_wdata[b] = c_wdata;
      end
    end
  end

  // Read data routing
  assign a_rdata  = bank_rdata[a_bank];
  assign a_rvalid = bank_rvalid[a_bank];
  assign c_rdata  = bank_rdata[c_bank];
  assign c_rvalid = bank_rvalid[c_bank];

endmodule
