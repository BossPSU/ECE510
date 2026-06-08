/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTH */
/* verilator lint_off UNUSED */
/* verilator lint_off UNOPTFLAT */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// adder_tree.v -- hand-flattened Verilog 2005 of project/m2/rtl/adder_tree.sv
//
// Pipelined Q16.16 reduction tree, parameterized by NUM_INPUTS. Conversions:
//   - `in_data [NUM_INPUTS]` unpacked-array port -> flat NUM_INPUTS*32-bit
//     packed bus; consumers slice with [i*DATA_WIDTH +: DATA_WIDTH].
//   - `stage [LEVELS+1][NUM_INPUTS]` 2D array -> linear `[0:total-1]` memory
//     indexed by (lv * NUM_INPUTS + i).
//   - `valid_pipe[LEVELS+1]` -> packed reg [LEVELS:0] valid_pipe.
//   - Removed `import accel_pkg::*` (only DATA_WIDTH/Q16.16 sizes referenced,
//     and DATA_WIDTH is already a module parameter).
//   - `always_ff` -> `always @(posedge clk or negedge rst_n)`.
//   - `'0` -> {DATA_WIDTH{1'b0}}.
//   - Generate-block `localparam`s replaced with shift expressions written
//     out at each use site (Verilog-2005 allows localparam inside generate
//     blocks but yosys's elaborator has been touchier with them).
//
// Caller contract: pack inputs LSB-aligned by index:
//   in_data_packed[(i*DATA_WIDTH) +: DATA_WIDTH]   for i in [0, NUM_INPUTS).
// =============================================================================
module adder_tree (
    clk,
    rst_n,
    en,
    in_data,
    in_valid,
    sum_out,
    out_valid
);

    parameter DATA_WIDTH = 32;
    parameter NUM_INPUTS = 64;
    localparam LEVELS = clog2_f(NUM_INPUTS);

    input  wire clk;
    input  wire rst_n;
    input  wire en;
    input  wire [(NUM_INPUTS*DATA_WIDTH)-1:0] in_data;
    input  wire in_valid;
    output wire signed [DATA_WIDTH-1:0] sum_out;
    output wire out_valid;

    // Flat 2D pipeline storage: stage[lv * NUM_INPUTS + i].
    // Size is (LEVELS+1)*NUM_INPUTS Q16.16 words.
    reg signed [DATA_WIDTH-1:0] stage [0:((LEVELS+1)*NUM_INPUTS)-1];
    reg                          valid_pipe [0:LEVELS];

    integer init_i;
    integer load_i;
    integer red_i;

    // ----- Input stage (level 0) -----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe[0] <= 1'b0;
            for (init_i = 0; init_i < NUM_INPUTS; init_i = init_i + 1)
                stage[init_i] <= {DATA_WIDTH{1'b0}};
        end else if (en) begin
            valid_pipe[0] <= in_valid;
            for (load_i = 0; load_i < NUM_INPUTS; load_i = load_i + 1)
                stage[load_i] <= $signed(
                    in_data[(load_i*DATA_WIDTH) +: DATA_WIDTH]);
        end
    end

    // ----- Reduction levels -----
    // At level `lv` the row width is (NUM_INPUTS >> lv). Pair adjacent
    // entries, leave the trailing odd element if the row width is odd.
    genvar lv;
    generate
        for (lv = 0; lv < LEVELS; lv = lv + 1) begin : gen_level
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_pipe[lv+1] <= 1'b0;
                    for (red_i = 0; red_i < NUM_INPUTS; red_i = red_i + 1)
                        stage[((lv+1)*NUM_INPUTS) + red_i]
                            <= {DATA_WIDTH{1'b0}};
                end else if (en) begin
                    valid_pipe[lv+1] <= valid_pipe[lv];
                    for (red_i = 0;
                         red_i < (NUM_INPUTS >> (lv+1));
                         red_i = red_i + 1) begin
                        stage[((lv+1)*NUM_INPUTS) + red_i]
                            <= stage[(lv*NUM_INPUTS) + (2*red_i)]
                             + stage[(lv*NUM_INPUTS) + (2*red_i) + 1];
                    end
                    // Odd carry-through: if this level's width is odd,
                    // the last input has no pair and is forwarded.
                    if (((NUM_INPUTS >> lv) & 1) == 1) begin
                        stage[((lv+1)*NUM_INPUTS) + ((NUM_INPUTS >> (lv+1)))]
                            <= stage[(lv*NUM_INPUTS)
                                     + ((NUM_INPUTS >> lv) - 1)];
                    end
                end
            end
        end
    endgenerate

    assign sum_out   = stage[LEVELS*NUM_INPUTS];
    assign out_valid = valid_pipe[LEVELS];

    // -------------------------------------------------------------------
    // Verilog-2005 ceil-log2 function (constant-folded by yosys at elab).
    // Used only to size LEVELS at compile time.
    // -------------------------------------------------------------------
    function integer clog2_f;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2_f = 0;
            while (v > 0) begin
                v = v >> 1;
                clog2_f = clog2_f + 1;
            end
        end
    endfunction

endmodule
