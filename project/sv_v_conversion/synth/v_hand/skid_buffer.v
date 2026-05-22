/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// skid_buffer.v -- hand-flattened from project/m2/rtl/skid_buffer.sv
// Two-entry FIFO that absorbs one cycle of downstream backpressure.
// =============================================================================
module skid_buffer (
    clk,
    rst_n,
    in_data,
    in_valid,
    in_ready,
    out_data,
    out_valid,
    out_ready
);

    parameter DATA_WIDTH = 32;

    input  wire                   clk;
    input  wire                   rst_n;
    input  wire [DATA_WIDTH-1:0]  in_data;
    input  wire                   in_valid;
    output wire                   in_ready;
    output wire [DATA_WIDTH-1:0]  out_data;
    output wire                   out_valid;
    input  wire                   out_ready;

    reg [DATA_WIDTH-1:0] skid_data;
    reg                  skid_valid;
    reg [DATA_WIDTH-1:0] main_data;
    reg                  main_valid;

    assign out_data  = main_data;
    assign out_valid = main_valid;
    assign in_ready  = !skid_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_valid <= 1'b0;
            skid_valid <= 1'b0;
            main_data  <= {DATA_WIDTH{1'b0}};
            skid_data  <= {DATA_WIDTH{1'b0}};
        end else begin
            // Main register: load from skid if it holds something,
            // otherwise from the upstream.
            if (out_ready || !main_valid) begin
                if (skid_valid) begin
                    main_data  <= skid_data;
                    main_valid <= 1'b1;
                    skid_valid <= 1'b0;
                end else begin
                    main_data  <= in_data;
                    main_valid <= in_valid;
                end
            end

            // Skid register: catch the upstream beat when main is held by
            // a downstream that isn't yet ready.
            if (in_valid && in_ready && main_valid && !out_ready) begin
                skid_data  <= in_data;
                skid_valid <= 1'b1;
            end
        end
    end

endmodule
