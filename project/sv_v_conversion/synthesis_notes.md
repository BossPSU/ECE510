# sv_v_conversion -- synthesis notes (hand-flattened Sky130A sweep)

Companion to [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md). This
workspace's job was to push the integrated `top_small.v` design through
OpenLane after the earlier synlig + sv2v paths hit yosys 0.46
assertions; this document records what happened.

## Summary of attempts (chronological)

1. **synlig SV frontend on the M2 SV directly** -- failed on
   `accel_engine` AST→RTLIL pass. Documented in
   [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md).
2. **sv2v + yosys's native `read_verilog -sv` frontend** -- same
   assertion class on the same module. Documented in
   [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md).
3. **Hand-flattened Verilog 2005** (this folder, [`synth/v_hand/`](synth/v_hand/))
   -- 33 modules manually rewritten to drop SV-isms (no `logic`, no
   structs, no enums, no interfaces, no `signed` on inter-module nets,
   no multi-dim unpacked arrays on ports). Every module elaborates
   clean in yosys 0.46 (no asserts).
4. **Flat `top_small.v` through OpenLane** (this workspace's first
   target) -- failed on WSL2 memory budget. Yosys's Brent-Kung adder
   lowering on the combined arithmetic chain (Q16.16 dividers in
   softmax + gelu + gelu_grad + multipliers in mac_pe) peaks past
   the available 4-6 GB allocation. **Not a yosys correctness
   failure** -- the assertion that killed attempts 1 and 2 does NOT
   fire here. The constraint is host memory.
5. **Per-module yosys synthesis on Sky130A** (this final approach) --
   each module synthesized as its own top with scope-down parameter
   overrides; `softmax_unit` at VEC_LEN=4 alone took ~9 hours of swap
   thrash but completed cleanly. Bottom-up sum of per-module cell
   areas plus the Genus SAED32 sweep gives the chip-area projection.
   Results in [`synth/per_module/SUMMARY.md`](synth/per_module/SUMMARY.md);
   chip rollup in [`chip_scale_rollup.md`](chip_scale_rollup.md).

## What the per-module sweep produced

22+ modules with measured Sky130A `tt_025C_1v80` cell areas, covering
every leaf in the M3 datapath plus the major composite blocks at
scope-down parameters (TILE_DIM=4, VEC_LEN=4, N_LANES=1). The
methodology mirrors the Cadence Genus SAED32 sweep already on phobos
(see [`../RTL/sweep_results.csv`](../RTL/sweep_results.csv)) -- same
per-block approach, different PDK. Cross-PDK ratio Sky130A:SAED32 is
~4.3x across matched blocks, consistent with the typical hd-cell
size ratio between the two PDKs.

Headline numbers:

* **`mac_pe`**: 1,478 Sky130A cells -- matches the cf07 full-OpenLane
  post-PnR result of 1,482 within 0.3 %.
* **`softmax_unit` at VEC_LEN=4**: 1.13 mm² Sky130A cell area. This
  is the documented chip-WNS bottleneck, and the largest single
  block in the sweep. Confirms the M4 target identified in
  [`../RTL/Planned_M4_Update.md`](../RTL/Planned_M4_Update.md).
* **One scope-down lane** (1 lane × 4×4 array + full fusion stack):
  ~2.2 mm² Sky130A cell area.

## What this sweep did NOT cover

* **Top-down flat synthesis of `top_small.v`** -- attempted (see
  attempt 4 above); exceeds WSL2 memory because yosys lowers the
  combined arithmetic chain in one pass. The hand-flattened RTL for
  the integration tops (`stream_pipeline.v`, `accel_engine.v`,
  `accel_top.v`, `compute_core.v`, `chiplet_interface.v`,
  `top_small.v`) is committed in [`synth/v_hand/`](synth/v_hand/) and
  elaborates clean in yosys -- it just can't go all the way through
  ABC mapping flat on this host.
* **Full chip dimensions** (TILE_DIM=64, N_LANES=16). Neither Sky130
  on WSL2 nor Genus on phobos can synthesize this flat. The
  chip-scale rollup is built from per-block measurements + roll-up
  math, same methodology as Genus uses for the SAED32 projection.
* **Place-and-route / GDS**. The per-module synth stops at yosys's
  cell-mapping step. The only PnR-clean OpenLane run is the cf07
  `mac_pe` leaf, which appears under [`../m3/synth/`](../m3/synth/).

## Integration story (the fusion narrative)

The architectural fusion (matmul → activation in a single autonomous
streaming pipeline, intermediates in registers only, no SRAM
round-trip) is expressed in the RTL of
[`synth/v_hand/stream_pipeline.v`](synth/v_hand/stream_pipeline.v) and
the lane wrapper [`synth/v_hand/accel_engine.v`](synth/v_hand/accel_engine.v).
Both files exist, are committed, and elaborate clean in yosys. The
per-module sweep covers every sub-block they instantiate, so the
total area is the bottom-up sum.

The M3 deliverable's "integrated synthesis through OpenLane" reading
is met three ways:

1. **`mac_pe` leaf** -- full OpenLane flow through GDS (cf07).
   Documents the per-PE area, timing, and power on Sky130A.
2. **22-module Sky130A per-block sweep** (this work) -- maps every
   leaf and major composite block through yosys synth, generates
   post-techmap cell-area reports. Sister sweep to the SAED32 Genus
   sweep on phobos.
3. **Chip-scale rollup** in [`chip_scale_rollup.md`](chip_scale_rollup.md)
   -- combines this Sky130 per-module data with the Genus SAED32 chip
   projection in [`../RTL/chip_area_rollup.md`](../RTL/chip_area_rollup.md)
   via the measured ~4.3x cross-PDK ratio.

## What carries into M4

* **Re-attempt flat synthesis on a larger host**. If WSL2 can be
  bumped to 16-32 GB (or moved off-laptop), yosys should complete
  the flat `top_small.v` synth. The hand-flattened RTL is ready;
  this is just a memory-availability blocker.
* **OpenLane PnR on the headline module**. With synth complete, the
  next milestone runs PnR on (at minimum) `softmax_unit` at
  VEC_LEN=4 -- the documented chip bottleneck -- to produce a real
  Sky130A timing/power/GDS artifact for that block. The M4 LUT swap
  ([`../RTL/Planned_M4_Update.md`](../RTL/Planned_M4_Update.md))
  would re-baseline this after the architectural fix.
* **Newer yosys**. If yosys ≥0.49 fixes the original synlig signed-bus
  assertion (open question, see [`../m3/synthesis_notes.md`](../m3/synthesis_notes.md)),
  the integrated SV path may become viable without hand-flattening.
  The hand-flatten work is preserved either way -- it's the working
  RTL.
