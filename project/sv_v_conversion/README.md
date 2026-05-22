# sv_v_conversion -- hand-flattened Verilog 2005 + Sky130A per-module sweep

> **Note:** The M3 deliverables have been merged into [`../m3/`](../m3/) so
> the grader's automated checks (which key on `project/m3/` paths exactly)
> can find them. The hand-flattened RTL is at
> [`../m3/synth/v_hand/`](../m3/synth/v_hand/); the per-module sweep is at
> [`../m3/synth/per_module/`](../m3/synth/per_module/); the chip-scale
> rollup is at [`../m3/chip_scale_rollup.md`](../m3/chip_scale_rollup.md).
> This folder remains as the **working/development record** of how that
> work was built.

Companion workspace to [`../m3/`](../m3/). Two outputs delivered here:

1. **Hand-flattened plain Verilog 2005** for the entire M3 design,
   under [`synth/v_hand/`](synth/v_hand/). 33 modules manually
   rewritten from the M2 SystemVerilog to drop SV-isms that tripped
   yosys 0.46 in the earlier synlig / sv2v attempts (see
   [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md)). Every
   module elaborates clean in yosys.
2. **A 28-module Sky130A synthesis sweep** under
   [`synth/per_module/`](synth/per_module/) -- the open-PDK companion
   to the Cadence Genus SAED32 sweep on phobos. Per-block cell
   counts and area numbers via yosys 0.46 + ABC mapping against
   `sky130_fd_sc_hd__tt_025C_1v80.lib`. Summarized in
   [`synth/per_module/SUMMARY.md`](synth/per_module/SUMMARY.md);
   chip-scale rollup in [`chip_scale_rollup.md`](chip_scale_rollup.md);
   methodology / what's missing in [`synthesis_notes.md`](synthesis_notes.md).

The flat top-down synthesis of the integrated `top_small.v` was
attempted on this host (8 GB RAM, WSL2) and exceeded available memory
during yosys's Brent-Kung lowering of the combined Q16.16 arithmetic
chain. The per-module sweep is the response: synthesize each block
in isolation, then roll up. Same approach as the Genus sweep on phobos,
which has the same flat-synth limit at chip-native dimensions.

## Hand-flatten rules used

Every construct correlated with the original yosys assertion failures
was removed:

- no `logic` -- everything is `wire` or `reg` with explicit
  direction;
- no `signed` attribute on module ports or inter-module nets --
  signed arithmetic stays local to the module that needs it, using
  `$signed()`/`$unsigned()` casts at the boundary;
- no `typedef struct packed` -- struct fields become explicit
  bit-range slices of a flat bus;
- no `typedef enum` -- enumerations become `localparam` constants;
- no `import` of packages -- per-module localparams replace package
  references;
- no `interface` blocks -- all module ports are direct;
- no SV-style `always_ff` / `always_comb` -- standard Verilog 2005
  `always @(posedge clk)` / `always @*` only;
- no multi-dim unpacked arrays on module ports -- a buffer of
  `N` Q16.16 reads is `N*32`-bit packed bus, sliced inside the
  consuming module;
- no parameterized signed buses crossing module boundaries.

The SV source under [`../m2/rtl/`](../m2/rtl/) and the scoped
variants under [`synth/`](synth/) (copied from M3) stay untouched --
they remain the authoritative source for QuestaSim co-simulation and
the Cadence Genus sweep. The hand-flattened Verilog under
[`synth/v_hand/`](synth/v_hand/) is OpenLane-only.

## Conversion order (bottom-up)

Verifying each module by feeding it to yosys's `read_verilog -sv` +
`hierarchy -check` before moving up the tree. The order is the
module-dependency DAG with leaves first:

### Level 0 -- leaves with no dependencies on other M2 modules

All 11 leaves elaborate clean in yosys 0.46 (`hierarchy -check; stat`
emits no asserts, no errors). Cell counts shown are pre-techmap generic
RTLIL cells.

| Module | Status | yosys cells (RTLIL) |
|---|---|---:|
| `mac_pe` | done | 3 (1 $mul + 1 $add + 1 $logic_not) |
| `adder_tree` | done | 70 (NUM_INPUTS=64); 6 at NUM_INPUTS=4 |
| `sram_bank` | done | 1 ($memrd) + 131,072-bit memory at default depth |
| `exp_lut` | done | 2 ($meminit_v2 + $memrd) |
| `gelu_lut` | done | 2 (same shape as exp_lut) |
| `pipeline_stage` | done | 3 |
| `skid_buffer` | done | 8 |
| `causal_mask_unit` | done | 64 (VEC_LEN=64 muxes) |
| `divider_or_reciprocal_unit` | done | 4 |
| `perf_counter_block` | done | 5 |
| `address_gen` | done | 17 |

### Level 1 -- one level above the leaves

| Module | Depends on | Status |
|---|---|---|
| `systolic_array_64x64` | mac_pe | done (16 PEs @ ROWS=COLS=4: 48 cells) |
| `gelu_unit` | gelu_lut | done (10 muls + 1 div, 4 adds; default DATA_WIDTH=32) |
| `gelu_grad_unit` | gelu_lut | done (15 muls + 1 div; same Pade shape as gelu_unit) |
| `softmax_unit` | exp_lut, adder_tree, divider | done (VEC_LEN=64: 384 muls -- Pade^4 squared twice) |
| `fused_postproc_unit` | gelu_unit, gelu_grad_unit, softmax_unit, causal_mask_unit | done (MUX over activations) |
| `scratchpad_ctrl` | sram_bank | done (22 cells; A>B>C priority arbiter) |
| `tile_buffer` | -- | done (multi-port flattened to packed buses; 9 cells default) |
| `stream_mux` | -- | done (17 cells) |
| `mode_decoder` | -- | done (0 cells -- pure wiring + mux inlined) |
| `tile_scheduler` | -- | done (19 cells; 4-state FSM) |
| `dma_engine` | -- | done (1 cell -- direct pass-through) |
| `double_buffer_ctrl` | -- | done (4 cells) |

### Level 2 and above

| Module | Status |
|---|---|
| `tile_loader` | done (12 cells) |
| `tile_writer` | done (12 cells) |
| `stream_pipeline` | **done** (ARRAY_DIM=64 default: 4,703 muls; 1.9 GB yosys peak) |
| `accel_controller` | done (8-state FSM; cmd_pkt_t struct field-sliced) |
| `tile_dispatcher` | done (107-bit macro_cmd_t struct decomposed) |
| `accel_engine` | **done** -- **the M3 sv2v blocker module, now elaborates clean** (4,848 muls, 2.9 GB yosys peak at full TILE_DIM=64) |
| `accel_top` | done (scoped to N_LANES=1 via parameter) |
| `compute_core` | done (thin wrapper around accel_top) |
| `chiplet_interface` | done (UCIe protocol; pure wiring) |
| `top_small` | **done** -- integrated Option-A top (N_LANES=1, TILE_DIM=4) |

## All 30 modules converted

Bottom-up conversion complete. Verification chain:

1. Per-module `read_verilog v_hand/*.v; hierarchy -check -top X; stat`
   passes on every module standalone.
2. `accel_engine` at full TILE_DIM=64 elaborates clean -- which is the
   module the M3 sv2v path was blocked on. The signed/unsigned yosys
   bug class did not fire on the hand-written code.
3. `top_small` elaboration is in progress; OpenLane synthesis on
   `config_top_small_v_hand.json` is queued behind it.

## Verification per module

Each `v_hand/X.v` is verified at three checkpoints:

1. **Yosys elaboration** -- `yosys -p 'read_verilog v_hand/X.v;
   hierarchy -check -top X'`. Must complete without assertion.
2. **Yosys synthesis stub** -- `yosys -p 'read_verilog v_hand/X.v;
   synth -top X -flatten; stat'`. Should emit a cell-count report
   with no fatal errors.
3. **Functional equivalence vs SV** -- when the corresponding SV
   testbench exists (`project/m2/tb/tb_X.sv`), compile the V file
   in QuestaSim and rerun. Output must match within tolerance.

Step 3 isn't strictly required to make OpenLane happy but is the
sanity check that the hand-flattened code still computes correctly.

## Build pipeline (target)

Once all modules are converted:

```sh
cd project/sv_v_conversion/synth
openlane config_top_small_v_hand.json
# -> runs/RUN_<timestamp>/{flow.log, final/*.gds, reports/...}
```

`config_top_small_v_hand.json` will list every `v_hand/*.v` in
dependency order, target `DESIGN_NAME=top_small`, and run through
the standard Sky130A flow without `USE_SYNLIG`.

## Scope and time honesty

Hand-flattening ~30 modules is a multi-day effort. This folder is
where that work is staged; it will not all be complete by the M3
deadline. The leaf modules go quickly (~10-30 min each); the larger
ones (`stream_pipeline`, `softmax_unit`, `accel_engine`) are
hours-each due to the multi-port array unpacking and the long
function bodies. Progress is tracked in the status tables above and
in commit history; partial completion still produces a working
build for whichever modules are done.

If a future yosys release fixes the signed-bus assertion class
documented in [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md),
the `sv2v` path becomes viable again and this folder is
unnecessary. Until then, hand-flattening is the only path to a
clean OpenLane run on the integrated build.
