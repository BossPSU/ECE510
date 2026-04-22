// accel_pkg.sv — Global parameters, enums, and typedefs
package accel_pkg;

  // Array dimensions
  parameter int ARRAY_ROWS   = 64;
  parameter int ARRAY_COLS   = 64;
  parameter int DATA_WIDTH   = 32;  // FP32
  parameter int TILE_SIZE    = 64;

  // Model dimensions
  parameter int D_MODEL      = 64;
  parameter int D_FF         = 256;
  parameter int SEQ_LEN      = 64;
  parameter int N_HEADS      = 4;
  parameter int D_HEAD       = D_MODEL / N_HEADS;

  // SRAM
  parameter int SRAM_BANKS   = 8;
  parameter int SRAM_DEPTH   = 4096;  // words per bank
  parameter int SRAM_ADDR_W  = $clog2(SRAM_DEPTH);

  // LUT sizes
  parameter int LUT_DEPTH    = 256;
  parameter int LUT_ADDR_W   = $clog2(LUT_DEPTH);

  // Operation modes
  typedef enum logic [2:0] {
    MODE_FFN_FWD    = 3'd0,
    MODE_FFN_BWD    = 3'd1,
    MODE_ATTN_FWD   = 3'd2,
    MODE_ATTN_BWD   = 3'd3,
    MODE_IDLE       = 3'd7
  } mode_t;

  // Fused post-processing select
  typedef enum logic [2:0] {
    FUSED_BYPASS    = 3'd0,
    FUSED_GELU      = 3'd1,
    FUSED_GELU_GRAD = 3'd2,
    FUSED_SOFTMAX   = 3'd3,
    FUSED_MASK      = 3'd4
  } fused_op_t;

  // Command packet from host
  typedef struct packed {
    mode_t      mode;
    logic [15:0] addr_a;
    logic [15:0] addr_b;
    logic [15:0] addr_out;
    logic [7:0]  tile_m;
    logic [7:0]  tile_n;
    logic [7:0]  tile_k;
    logic [7:0]  seq_len;
  } cmd_pkt_t;

  // Tile metadata
  typedef struct packed {
    logic [7:0]  tile_m;
    logic [7:0]  tile_n;
    logic [7:0]  tile_k;
    mode_t       mode;
    fused_op_t   fused_op;
    logic        last;
  } tile_meta_t;

  // Stream packet
  typedef struct packed {
    logic [DATA_WIDTH-1:0] data;
    logic [7:0]            txn_id;
    logic                  last;
    fused_op_t             op_mode;
  } stream_pkt_t;

  // Status packet
  typedef struct packed {
    logic        done;
    logic        busy;
    logic        error;
    logic [31:0] active_cycles;
    logic [31:0] stall_cycles;
    logic [31:0] tiles_completed;
  } status_pkt_t;

endpackage
