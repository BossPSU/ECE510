/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// scratchpad_ctrl.v -- hand-flattened from project/m2/rtl/scratchpad_ctrl.sv
//
// Banked scratchpad with three ports: A (read), B (write), C (DMA r/w).
// NUM_BANKS sram_bank instances arbitrated with A > B > C priority.
//
// Conversions:
//   - per-bank arrays flattened to packed buses; dynamic-index reads are
//     done with an explicit `bank_rdata[(idx*W) +: W]` slice;
//   - generate-block instantiation kept (yosys handles it);
//   - localparam BANK_ADDR_W = $clog2(BANK_DEPTH) replaced with a constant
//     function evaluated at elab.
// =============================================================================
module scratchpad_ctrl (
    clk,
    rst_n,
    a_req,
    a_addr,
    a_rdata,
    a_rvalid,
    b_req,
    b_we,
    b_addr,
    b_wdata,
    c_req,
    c_we,
    c_addr,
    c_wdata,
    c_rdata,
    c_rvalid
);

    parameter DATA_WIDTH = 32;
    parameter NUM_BANKS  = 2;
    parameter BANK_DEPTH = 64;
    parameter ADDR_WIDTH = 16;
    localparam BANK_ADDR_W = clog2_f(BANK_DEPTH);
    localparam BANK_SEL_W  = clog2_f(NUM_BANKS);

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    a_req;
    input  wire [ADDR_WIDTH-1:0]   a_addr;
    output wire [DATA_WIDTH-1:0]   a_rdata;
    output wire                    a_rvalid;
    input  wire                    b_req;
    input  wire                    b_we;
    input  wire [ADDR_WIDTH-1:0]   b_addr;
    input  wire [DATA_WIDTH-1:0]   b_wdata;
    input  wire                    c_req;
    input  wire                    c_we;
    input  wire [ADDR_WIDTH-1:0]   c_addr;
    input  wire [DATA_WIDTH-1:0]   c_wdata;
    output wire [DATA_WIDTH-1:0]   c_rdata;
    output wire                    c_rvalid;

    wire [BANK_SEL_W-1:0]  a_bank      = a_addr[BANK_SEL_W-1:0];
    wire [BANK_ADDR_W-1:0] a_bank_addr = a_addr[BANK_SEL_W +: BANK_ADDR_W];
    wire [BANK_SEL_W-1:0]  b_bank      = b_addr[BANK_SEL_W-1:0];
    wire [BANK_ADDR_W-1:0] b_bank_addr = b_addr[BANK_SEL_W +: BANK_ADDR_W];
    wire [BANK_SEL_W-1:0]  c_bank      = c_addr[BANK_SEL_W-1:0];
    wire [BANK_ADDR_W-1:0] c_bank_addr = c_addr[BANK_SEL_W +: BANK_ADDR_W];

    // Per-bank arrays flattened to packed buses, indexed [bank*W +: W].
    reg  [NUM_BANKS-1:0]                  bank_req_pkt;
    reg  [NUM_BANKS-1:0]                  bank_we_pkt;
    reg  [(NUM_BANKS*BANK_ADDR_W)-1:0]    bank_addr_pkt;
    reg  [(NUM_BANKS*DATA_WIDTH)-1:0]     bank_wdata_pkt;
    wire [(NUM_BANKS*DATA_WIDTH)-1:0]     bank_rdata_pkt;
    wire [NUM_BANKS-1:0]                  bank_rvalid_pkt;

    // ----- Bank instances -----
    genvar i;
    generate
        for (i = 0; i < NUM_BANKS; i = i + 1) begin : gen_bank
            sram_bank #(
                .DATA_WIDTH (DATA_WIDTH),
                .DEPTH      (BANK_DEPTH),
                .ADDR_WIDTH (BANK_ADDR_W)
            ) u_bank (
                .clk    (clk),
                .req    (bank_req_pkt[i]),
                .we     (bank_we_pkt[i]),
                .addr   (bank_addr_pkt[(i*BANK_ADDR_W) +: BANK_ADDR_W]),
                .wdata  (bank_wdata_pkt[(i*DATA_WIDTH) +: DATA_WIDTH]),
                .rdata  (bank_rdata_pkt[(i*DATA_WIDTH) +: DATA_WIDTH]),
                .rvalid (bank_rvalid_pkt[i])
            );
        end
    endgenerate

    // ----- Priority arbiter: A (read) > B (write) > C (DMA) -----
    integer bi;
    always @* begin
        for (bi = 0; bi < NUM_BANKS; bi = bi + 1) begin
            bank_req_pkt[bi]                                = 1'b0;
            bank_we_pkt[bi]                                 = 1'b0;
            bank_addr_pkt[(bi*BANK_ADDR_W) +: BANK_ADDR_W]  =
                {BANK_ADDR_W{1'b0}};
            bank_wdata_pkt[(bi*DATA_WIDTH) +: DATA_WIDTH]   =
                {DATA_WIDTH{1'b0}};

            if (a_req && (a_bank == bi)) begin
                bank_req_pkt[bi]                                = 1'b1;
                bank_we_pkt[bi]                                 = 1'b0;
                bank_addr_pkt[(bi*BANK_ADDR_W) +: BANK_ADDR_W]  = a_bank_addr;
            end else if (b_req && (b_bank == bi)) begin
                bank_req_pkt[bi]                                = 1'b1;
                bank_we_pkt[bi]                                 = b_we;
                bank_addr_pkt[(bi*BANK_ADDR_W) +: BANK_ADDR_W]  = b_bank_addr;
                bank_wdata_pkt[(bi*DATA_WIDTH) +: DATA_WIDTH]   = b_wdata;
            end else if (c_req && (c_bank == bi)) begin
                bank_req_pkt[bi]                                = 1'b1;
                bank_we_pkt[bi]                                 = c_we;
                bank_addr_pkt[(bi*BANK_ADDR_W) +: BANK_ADDR_W]  = c_bank_addr;
                bank_wdata_pkt[(bi*DATA_WIDTH) +: DATA_WIDTH]   = c_wdata;
            end
        end
    end

    // ----- Read-data routing back to A / C ports -----
    assign a_rdata  = bank_rdata_pkt[(a_bank*DATA_WIDTH) +: DATA_WIDTH];
    assign a_rvalid = bank_rvalid_pkt[a_bank];
    assign c_rdata  = bank_rdata_pkt[(c_bank*DATA_WIDTH) +: DATA_WIDTH];
    assign c_rvalid = bank_rvalid_pkt[c_bank];

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
