// status_if.sv — Completion / counters / errors interface
interface status_if;
  logic        done;
  logic        busy;
  logic        error;
  logic [31:0] active_cycles;
  logic [31:0] stall_cycles;
  logic [31:0] tiles_completed;

  modport src (output done, busy, error, active_cycles, stall_cycles, tiles_completed);
  modport dst (input  done, busy, error, active_cycles, stall_cycles, tiles_completed);

endinterface
