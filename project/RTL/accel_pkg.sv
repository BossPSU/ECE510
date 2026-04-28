// accel_pkg.sv — Global parameters, enums, typedefs, fixed-point helpers
package accel_pkg;

  // Array dimensions
  parameter int ARRAY_ROWS   = 64;
  parameter int ARRAY_COLS   = 64;
  parameter int DATA_WIDTH   = 32;
  parameter int TILE_SIZE    = 64;

  // Q16.16 fixed-point format: 32-bit signed, 16 integer bits, 16 fractional bits
  // Range: [-32768.0, +32767.999985]  Resolution: ~1.5e-5
  parameter int FRAC_BITS    = 16;
  parameter int INT_BITS     = 16;

  // Common Q16.16 constants (sign-extended hex literals)
  parameter logic signed [31:0] Q_ZERO     = 32'sh00000000; // 0.0
  parameter logic signed [31:0] Q_ONE      = 32'sh00010000; // 1.0
  parameter logic signed [31:0] Q_HALF     = 32'sh00008000; // 0.5
  parameter logic signed [31:0] Q_TWO      = 32'sh00020000; // 2.0
  parameter logic signed [31:0] Q_NEG_ONE  = 32'shFFFF0000; // -1.0
  parameter logic signed [31:0] Q_NEG_BIG  = 32'sh80010000; // ~-32767 for masking
  // sqrt(2/pi) ~ 0.7978845608, in Q16.16 = round(0.7978845608 * 65536) = 52280 = 0x0000CC38
  parameter logic signed [31:0] Q_SQRT_2_PI = 32'sh0000CC38;
  // 0.044715 in Q16.16 = round(0.044715 * 65536) = 2930 = 0x00000B72
  parameter logic signed [31:0] Q_GELU_C1  = 32'sh00000B72;
  // 3 * 0.044715 = 0.134145 in Q16.16 = 8791 = 0x00002257
  parameter logic signed [31:0] Q_GELU_C3  = 32'sh00002257;

  // Saturation bounds for approximation domain
  parameter logic signed [31:0] Q_SAT_POS  = 32'sh00040000; // +4.0
  parameter logic signed [31:0] Q_SAT_NEG  = 32'shFFFC0000; // -4.0
  parameter logic signed [31:0] Q_EXP_MIN  = 32'shFFF80000; // -8.0

  // Model dimensions
  parameter int D_MODEL      = 64;
  parameter int D_FF         = 256;
  parameter int SEQ_LEN      = 64;
  parameter int N_HEADS      = 4;
  parameter int D_HEAD       = D_MODEL / N_HEADS;

  // SRAM
  parameter int SRAM_BANKS   = 8;
  parameter int SRAM_DEPTH   = 4096;
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

  // Command packet from host.
  // addr_aux holds the auxiliary input buffer pointer.
  // For MODE_FFN_BWD it points to the saved pre-activation h_pre that pairs
  // with the upstream gradient at addr_a (see fused_postproc_unit).
  // For other modes it is unused — load is skipped.
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

  // Tile metadata
  typedef struct packed {
    logic [7:0] tile_m;
    logic [7:0] tile_n;
    logic [7:0] tile_k;
    mode_t      mode;
    fused_op_t  fused_op;
    logic       last;
  } tile_meta_t;

  // Multi-tile ("macro") command — describes a full operation that the
  // tile_dispatcher will break into per-tile cmd_pkt_t micro-commands.
  // Output tile (m_idx, n_idx) base addresses (assuming 64x64 tiles
  // stored contiguously per tile in row-major tile order):
  //   addr_a_tile   = addr_a   + m_idx * (TILE_SIZE * tile_k)
  //   addr_b_tile   = addr_b   + n_idx * (tile_k * TILE_SIZE)
  //   addr_aux_tile = addr_aux + (m_idx*num_n_tiles + n_idx) * (TILE_SIZE^2)
  //   addr_out_tile = addr_out + (m_idx*num_n_tiles + n_idx) * (TILE_SIZE^2)
  typedef struct packed {
    mode_t       mode;
    logic [15:0] addr_a;
    logic [15:0] addr_b;
    logic [15:0] addr_aux;
    logic [15:0] addr_out;
    logic [7:0]  num_m_tiles;     // tiles along result rows (>=1)
    logic [7:0]  num_n_tiles;     // tiles along result cols (>=1)
    logic [7:0]  tile_m;          // rows in each output tile (<= TILE_SIZE)
    logic [7:0]  tile_n;          // cols in each output tile
    logic [7:0]  tile_k;          // shared dim per tile (no K-accumulation)
  } macro_cmd_t;

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

  // ----- Synthesizable Q16.16 helper functions -----

  // Multiply two Q16.16 numbers, return Q16.16 (truncated)
  // a (Q16.16) * b (Q16.16) = result (Q32.32), shift right by FRAC_BITS to get Q16.16
  function automatic logic signed [31:0] q_mul(input logic signed [31:0] a, input logic signed [31:0] b);
    logic signed [63:0] product;
    product = $signed(a) * $signed(b);
    return product[31+FRAC_BITS:FRAC_BITS]; // truncate
  endfunction

  // Saturating add
  function automatic logic signed [31:0] q_add_sat(input logic signed [31:0] a, input logic signed [31:0] b);
    logic signed [32:0] sum;
    sum = $signed({a[31], a}) + $signed({b[31], b});
    if (sum[32] != sum[31]) // overflow
      return sum[32] ? 32'sh80000000 : 32'sh7FFFFFFF;
    return sum[31:0];
  endfunction

endpackage
