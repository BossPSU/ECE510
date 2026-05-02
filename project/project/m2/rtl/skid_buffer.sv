// skid_buffer.sv — Two-entry buffer to absorb transient backpressure
module skid_buffer
  import accel_pkg::*;
#(
  parameter int DATA_WIDTH = 32
)(
  input  logic                   clk,
  input  logic                   rst_n,

  input  logic [DATA_WIDTH-1:0]  in_data,
  input  logic                   in_valid,
  output logic                   in_ready,

  output logic [DATA_WIDTH-1:0]  out_data,
  output logic                   out_valid,
  input  logic                   out_ready
);

  logic [DATA_WIDTH-1:0] skid_data;
  logic                  skid_valid;
  logic [DATA_WIDTH-1:0] main_data;
  logic                  main_valid;

  assign out_data  = main_data;
  assign out_valid = main_valid;
  assign in_ready  = !skid_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      main_valid <= 1'b0;
      skid_valid <= 1'b0;
    end else begin
      // Main register
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

      // Skid register: catch input when main is stalled
      if (in_valid && !in_ready) begin
        // This shouldn't happen if in_ready is respected
      end else if (in_valid && in_ready && main_valid && !out_ready) begin
        skid_data  <= in_data;
        skid_valid <= 1'b1;
      end
    end
  end

endmodule
