// stream_if.sv — Valid/ready streaming interface
interface stream_if #(
  parameter int DATA_WIDTH = 32
);
  logic                    valid;
  logic                    ready;
  logic [DATA_WIDTH-1:0]   data;
  logic                    last;
  accel_pkg::fused_op_t    op_mode;

  modport src (output valid, data, last, op_mode, input  ready);
  modport dst (input  valid, data, last, op_mode, output ready);

endinterface
