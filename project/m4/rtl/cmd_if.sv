// cmd_if.sv — Host command/config interface
interface cmd_if;
  logic                    cmd_valid;
  logic                    cmd_ready;
  accel_pkg::cmd_pkt_t     cmd;

  modport host   (output cmd_valid, cmd, input  cmd_ready);
  modport device (input  cmd_valid, cmd, output cmd_ready);

endinterface
