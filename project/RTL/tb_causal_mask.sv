// tb_causal_mask.sv — Unit TB for causal mask
// Verify upper-triangle elements are masked to -1e9
`timescale 1ns/1ps

module tb_causal_mask;
  import accel_pkg::*;

  localparam int VEC = 4;

  logic [31:0] data_in  [VEC];
  logic [31:0] data_out [VEC];
  logic [7:0]  row_idx;
  logic        in_valid, out_valid;

  causal_mask_unit #(.DATA_WIDTH(32), .VEC_LEN(VEC)) dut (.*);

  function automatic shortreal fp32(logic [31:0] bits);
    return $bitstoshortreal(bits);
  endfunction

  initial begin
    $display("=== tb_causal_mask: START ===");

    // Fill all scores with 1.0
    for (int i = 0; i < VEC; i++)
      data_in[i] = $shortrealtobits(shortreal'(1.0));
    in_valid = 1;

    // Row 0: only col 0 should pass, cols 1-3 masked
    row_idx = 8'd0;
    #1;
    $display("  Row 0: [%0.1f, %0.1f, %0.1f, %0.1f]",
             fp32(data_out[0]), fp32(data_out[1]),
             fp32(data_out[2]), fp32(data_out[3]));
    if (fp32(data_out[0]) == 1.0 && fp32(data_out[1]) < -1e8)
      $display("    PASS: row 0 correctly masked");
    else
      $display("    FAIL: row 0 masking incorrect");

    // Row 2: cols 0-2 pass, col 3 masked
    row_idx = 8'd2;
    #1;
    $display("  Row 2: [%0.1f, %0.1f, %0.1f, %0.1f]",
             fp32(data_out[0]), fp32(data_out[1]),
             fp32(data_out[2]), fp32(data_out[3]));
    if (fp32(data_out[2]) == 1.0 && fp32(data_out[3]) < -1e8)
      $display("    PASS: row 2 correctly masked");
    else
      $display("    FAIL: row 2 masking incorrect");

    // Row 3: all pass (last row, no future tokens)
    row_idx = 8'd3;
    #1;
    $display("  Row 3: [%0.1f, %0.1f, %0.1f, %0.1f]",
             fp32(data_out[0]), fp32(data_out[1]),
             fp32(data_out[2]), fp32(data_out[3]));
    if (fp32(data_out[3]) == 1.0)
      $display("    PASS: row 3 all unmasked");
    else
      $display("    FAIL: row 3 masking incorrect");

    $display("=== tb_causal_mask: DONE ===");
    $finish;
  end

endmodule
