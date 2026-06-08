// tile_if.sv — Structured tile transfer interface
interface tile_if #(
  parameter int DATA_WIDTH = 32
);
  logic                        valid;
  logic                        ready;
  logic [DATA_WIDTH-1:0]       data;
  accel_pkg::tile_meta_t       meta;

  modport src (output valid, data, meta, input  ready);
  modport dst (input  valid, data, meta, output ready);

endinterface
