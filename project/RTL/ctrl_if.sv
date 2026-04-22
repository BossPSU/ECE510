// ctrl_if.sv — Control interface between scheduler/controller and subblocks
interface ctrl_if;
  logic                    start;
  logic                    flush;
  accel_pkg::mode_t        mode;
  accel_pkg::fused_op_t    fused_sel;
  logic                    tile_boundary;
  logic                    done;

  modport ctrl (output start, flush, mode, fused_sel, tile_boundary, input  done);
  modport sub  (input  start, flush, mode, fused_sel, tile_boundary, output done);

endinterface
