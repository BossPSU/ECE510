// =============================================================================
// accel_pkg.sv -- SCOPED-DOWN package for the M3 OpenLane synth attempt
//
// Drop-in replacement for project/m2/rtl/accel_pkg.sv that scales the chip
// down to fit OpenLane 2's cell-count ceiling. Used ONLY by the OpenLane
// build of project/m3/synth/top_small.sv -- the QuestaSim co-simulation
// still uses the unmodified project/m2/rtl/accel_pkg.sv (full 64x64).
//
// Knobs that changed from M2:
//
//   ARRAY_ROWS / ARRAY_COLS / TILE_SIZE :  64  -> 4   (16-PE systolic)
//   D_MODEL / SEQ_LEN                   :  64  -> 4
//   D_FF                                :  256 -> 16  (4x ratio preserved)
//   N_HEADS                             :   4  -> 1   (D_HEAD stays 4)
//   SRAM_BANKS / SRAM_DEPTH             : 8/4K -> 2/64 (scratchpad shrinks)
//
// Q16.16 fixed-point format, command/status structs, enums, and LUT depth
// are UNCHANGED -- they're not size-dependent, and keeping them identical
// avoids width mismatches in chiplet_interface (which doesn't see ARRAY_*).
// =============================================================================
package accel_pkg;

  // Array dimensions (4x4 instead of 64x64)
  parameter int ARRAY_ROWS   = 4;
  parameter int ARRAY_COLS   = 4;
  parameter int DATA_WIDTH   = 32;
  parameter int TILE_SIZE    = 4;

  // Q16.16 fixed-point format (UNCHANGED -- format invariants)
  parameter int FRAC_BITS    = 16;
  parameter int INT_BITS     = 16;

  parameter logic signed [31:0] Q_ZERO     = 32'sh00000000;
  parameter logic signed [31:0] Q_ONE      = 32'sh00010000;
  parameter logic signed [31:0] Q_HALF     = 32'sh00008000;
  parameter logic signed [31:0] Q_TWO      = 32'sh00020000;
  parameter logic signed [31:0] Q_NEG_ONE  = 32'shFFFF0000;
  parameter logic signed [31:0] Q_NEG_BIG  = 32'sh80010000;
  parameter logic signed [31:0] Q_SQRT_2_PI = 32'sh0000CC38;
  parameter logic signed [31:0] Q_GELU_C1  = 32'sh00000B72;
  parameter logic signed [31:0] Q_GELU_C3  = 32'sh00002257;
  parameter logic signed [31:0] Q_SAT_POS  = 32'sh00040000;
  parameter logic signed [31:0] Q_SAT_NEG  = 32'shFFFC0000;
  parameter logic signed [31:0] Q_EXP_MIN  = 32'shFFF80000;

  // Model dimensions (scaled to match the 4x4 array)
  parameter int D_MODEL      = 4;
  parameter int D_FF         = 16;
  parameter int SEQ_LEN      = 4;
  parameter int N_HEADS      = 1;
  parameter int D_HEAD       = D_MODEL / N_HEADS;

  // SRAM scratchpad -- shrunk to fit Sky130A flop-inferred memory budget.
  // 2 banks x 64 entries = 128 entries x 32b = 4 K flops total. Enough for
  // one 4x4 GEMM working set: 16 A + 16 B + 16 aux + 16 out = 64 entries.
  parameter int SRAM_BANKS   = 2;
  parameter int SRAM_DEPTH   = 64;
  parameter int SRAM_ADDR_W  = $clog2(SRAM_DEPTH);

  // Per-lane tile-slot layout. SLOT_STRIDE scales with TILE_SIZE^2:
  //   N_SLOTS=2 * SLOT_STRIDE=64  ->  LANE_LOCAL_W = 7
  parameter int N_SLOTS      = 2;
  parameter int SLOT_STRIDE  = 4 * TILE_SIZE * TILE_SIZE;
  parameter int LANE_LOCAL_W = $clog2(N_SLOTS * SLOT_STRIDE);

  // LUT depth UNCHANGED (the LUT contents are external behavioral ROMs;
  // their address width doesn't depend on the array size).
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

  typedef enum logic [2:0] {
    FUSED_BYPASS    = 3'd0,
    FUSED_GELU      = 3'd1,
    FUSED_GELU_GRAD = 3'd2,
    FUSED_SOFTMAX   = 3'd3,
    FUSED_MASK      = 3'd4
  } fused_op_t;

  typedef struct packed {
    mode_t       mode;
    logic [15:0] addr_a;
    logic [15:0] addr_b;
    logic [15:0] addr_aux;
    logic [15:0] addr_out;
    logic [7:0]  tile_m;
    logic [7:0]  tile_n;
    logic [7:0]  tile_k;
    logic [7:0]  seq_len;
  } cmd_pkt_t;

  typedef struct packed {
    logic [7:0] tile_m;
    logic [7:0] tile_n;
    logic [7:0] tile_k;
    mode_t      mode;
    fused_op_t  fused_op;
    logic       last;
  } tile_meta_t;

  typedef struct packed {
    mode_t       mode;
    logic [15:0] addr_a;
    logic [15:0] addr_b;
    logic [15:0] addr_aux;
    logic [15:0] addr_out;
    logic [7:0]  num_m_tiles;
    logic [7:0]  num_n_tiles;
    logic [7:0]  tile_m;
    logic [7:0]  tile_n;
    logic [7:0]  tile_k;
  } macro_cmd_t;

  typedef struct packed {
    logic [DATA_WIDTH-1:0] data;
    logic [7:0]            txn_id;
    logic                  last;
    fused_op_t             op_mode;
  } stream_pkt_t;

  typedef struct packed {
    logic        done;
    logic        busy;
    logic        error;
    logic [31:0] active_cycles;
    logic [31:0] stall_cycles;
    logic [31:0] tiles_completed;
  } status_pkt_t;

  // Synthesizable Q16.16 helpers (unchanged from M2 accel_pkg)
  function automatic logic signed [31:0] q_mul(input logic signed [31:0] a,
                                               input logic signed [31:0] b);
    logic signed [63:0] product;
    product = $signed(a) * $signed(b);
    return product[31+FRAC_BITS:FRAC_BITS];
  endfunction

  function automatic logic signed [31:0] q_add_sat(input logic signed [31:0] a,
                                                   input logic signed [31:0] b);
    logic signed [32:0] sum;
    sum = $signed({a[31], a}) + $signed({b[31], b});
    if (sum[32] != sum[31])
      return sum[32] ? 32'sh80000000 : 32'sh7FFFFFFF;
    return sum[31:0];
  endfunction

endpackage
