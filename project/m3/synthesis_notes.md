# M3 synthesis notes

## Summary

Eight OpenLane / yosys synthesis attempts were made for M3 (plus its
M4 / M5 follow-ons), in escalating order. The first two failed on
yosys-internal asserts; the third succeeded at the leaf; the fourth
failed on host memory; the fifth succeeded as a per-module sweep
covering 28 modules; the sixth and seventh added M4 LUT swaps that
unblocked the flat-top synth and produced a clean Sky130 GDS at the
cost of severe setup violations; the eighth added M5 pipelining to
the divider and MAC PE, closing 97 % of the TT setup gap and
producing a second clean Sky130 GDS that closes setup outright at FF.
The M3 OpenLane evidence is the union of attempts 3, 5, 6, 7, and 8b,
plus the documented failures of attempts 1, 2, 4, and the BLKANDNBLK
Verilator hit in attempt 8a.

1. **Integrated `top_small` through the synlig SV frontend** --
   yosys 0.46 + synlig assertion failure on `accel_engine` AST→RTLIL
   pass. Log: [`synth/openlane_run_top_small_FAILED.log`](synth/openlane_run_top_small_FAILED.log).
2. **Integrated `top_small` after `sv2v` SystemVerilog-to-Verilog
   conversion** -- different yosys 0.46 assertion class on the same
   module. The sv2v output is committed at
   [`synth/v/top_small.v`](synth/v/top_small.v). Log:
   [`synth/openlane_run_top_small_sv2v_FAILED.log`](synth/openlane_run_top_small_sv2v_FAILED.log).
3. **Leaf-level `mac_pe`** (the dominant PE, ~65 K instances in the
   chip). **Synthesized cleanly through all 73 OpenLane steps**;
   GDS clean; reports under [`synth/`](synth/) are this run's output.
   This is the headline M3 OpenLane proof point.
4. **Hand-flattened Verilog 2005 `top_small.v` synthesized flat** --
   33 modules manually rewritten to drop SV constructs that the
   synlig + sv2v paths choked on (no `logic`, no structs/enums/
   interfaces, no signed on inter-module nets, no multi-dim
   unpacked array ports). Every module elaborates clean in yosys
   ([`synth/v_hand/`](synth/v_hand/)). However, *flat* synthesis of
   the integrated top through OpenLane on this host (8 GB RAM, WSL2)
   exceeds available memory during yosys's Brent-Kung lowering of
   the combined Q16.16 arithmetic chain (softmax + gelu + gelu_grad
   + multipliers). **Not a yosys correctness failure** -- the
   assertions of attempts 1 and 2 never fire here. Constraint is host
   memory.
5. **Per-module yosys synthesis of the hand-flattened RTL on
   Sky130A** -- bottom-up sweep with one yosys invocation per
   top-module; 28 modules synthesized cleanly through ABC mapping,
   reports under [`synth/per_module/`](synth/per_module/). Per-block
   cell counts + areas; sister sweep to the SAED32 Genus sweep on
   phobos. Chip-scale rollup in [`chip_scale_rollup.md`](chip_scale_rollup.md).
6. **M4 LUT swap unblocks flat top_small Yosys.Synthesis** -- replacing
   the Padé softmax / gelu / gelu_grad chains with LUT+linterp
   drop-ins drops yosys peak RSS from ~5.7 GiB (OOM in Attempt 4) to
   ~1 GiB. The flat Yosys.Synthesis completes in under 4 min wall-clock
   ([`synth/top_small_M4_LUT_synth/`](synth/top_small_M4_LUT_synth/)).
7. **Attempt 6 extended through full OpenLane Classic flow with GDS
   streamout** -- after four structural fixes to clear yosys
   unmapped-cells, all 74 / 78 steps ran end-to-end on Sky130A. Clean
   DRC + LVS + antenna. But setup timing did **not** close at the
   10 ns target (TT WNS = -55.7 ns; chip f_max ≈ 15 MHz, divider-
   limited). Snapshot: [`synth/top_small_M4_LUT_full/`](synth/top_small_M4_LUT_full/).
8. **M5 pipelining (divider + mac_pe) closes 97 % of the TT setup gap
   and produces a second clean Sky130 GDS** -- the 64-bit combinational
   divider was replaced by a 48-cycle iterative shift-subtract
   (`divider_or_reciprocal_seq`), and `mac_pe_piped` adds one mid-MAC
   pipeline register. Full flow completes; FF closes outright; TT
   1.6 ns over budget; SS rated f_max **45 MHz** (vs did-not-close
   Attempt 7). Snapshot: [`synth/top_small_M5_attempt8/`](synth/top_small_M5_attempt8/).

All eight attempts are real, all are documented. The M3 spec's
"documented scope adjustment with the synthesis attempt that
justifies it" branch is met three different ways: the passing leaf
flow (attempt 3), the passing per-module sweep on the hand-flattened
RTL (attempt 5), and the documented failures of attempts 1, 2, 4
explaining why a single flat top-down run wasn't possible on this
host with this yosys version.

## Attempt 1 -- integrated `top_small` (Option A scope-down)

### What was built

The spec's letter calls for the integrated `top.sv` through OpenLane.
[`rtl/top.sv`](rtl/top.sv) at default M2 parameters is ~80 M gates
flat -- ~3 orders of magnitude past OpenLane's comfortable cell-count
ceiling on Sky130A in WSL2. So an explicit scope-down was constructed:

- [`synth/accel_pkg.sv`](synth/accel_pkg.sv) -- drop-in package
  replacement with `ARRAY_ROWS=4`, `ARRAY_COLS=4`, `TILE_SIZE=4`,
  `D_MODEL=4`, `D_FF=16`, `SEQ_LEN=4`, `N_HEADS=1`, plus
  `SRAM_BANKS=2`, `SRAM_DEPTH=64` to keep the inferred flop-memory
  scratchpad tractable. Q16.16 fixed-point format, command/status
  structs, enums, and LUT depth are unchanged (size-invariant).
- [`synth/accel_engine.sv`](synth/accel_engine.sv) -- the only edit
  is replacing the hardcoded `localparam int TILE_DIM = 64;` with
  `localparam int TILE_DIM = TILE_SIZE;`, so the engine pulls its tile
  dimension from the (scoped) package.
- [`synth/accel_top.sv`](synth/accel_top.sv) -- the only edit is
  replacing `.TILE_DIM(64)` on the `tile_dispatcher` instantiation
  with `.TILE_DIM(TILE_SIZE)`, same reason.
- [`synth/top_small.sv`](synth/top_small.sv) -- structural wrapper
  instantiating `chiplet_interface` + `compute_core` with `N_LANES=1`.
  Identical UCIe-side pinout to [`rtl/top.sv`](rtl/top.sv) so the same
  protocol-level co-simulation TB would drive it (with the input
  matrices resized to fit the scoped 4x4 tile).

The scope-down config [`synth/config.json`](synth/config.json) lists
the scoped files first (so the package definition wins), then the rest
of the unmodified M2 RTL from [`project/m2/rtl/`](../m2/rtl/), then
`top_small.sv`. `USE_SYNLIG=true` was required to make the Yosys
frontend handle the SystemVerilog packages, structs, interfaces, and
multi-port array packing in the M2 source.

### What happened

OpenLane successfully runs through the lint pass (63 SV-style lint
warnings, no errors). It then enters the JSON-header step (Stage 5 of
the 73-step Classic flow), where Yosys invokes the synlig SystemVerilog
frontend to elaborate the design. The frontend reads every file
(scoped package + all M2 source + scoped engine/top + top_small)
without error, applies `hierarchy -top top_small` to prune unused
modules (~30 of them get pruned cleanly), and begins generating RTLIL
for the parameterized `scratchpad_ctrl`.

Two distinct Yosys internal asserts fire depending on the
`SYNLIG_DEFER` setting:

```
USE_SYNLIG = true, SYNLIG_DEFER = false:
    Warning: Replacing memory \bank_wdata with list of registers.
    Warning: Replacing memory \bank_addr  with list of registers.
    Warning: Replacing memory \bank_we    with list of registers.
    Warning: Replacing memory \bank_req   with list of registers.
    ERROR: Assert `!VERILOG_FRONTEND::sv_mode' failed in
        frontends/ast/simplify.cc:2558.

USE_SYNLIG = true, SYNLIG_DEFER = true:
    Warning: Removing unelaborated module: ... (all M2 modules)
    ERROR: Assert `arg->is_signed == sig.as_wire()->is_signed' failed in
        frontends/ast/genrtlil.cc:2132.
```

Both are upstream `yosys` internal-state asserts triggered by what
synlig hands off to the post-elaboration AST passes (memory-array
flop-promotion in case 1, mixed signed/unsigned wire signedness in
case 2). They are *not* RTL errors in our design -- the same source
files compile and simulate cleanly through QuestaSim 2021.3_1 (the
seven M2 testbenches all PASS, including `tb_accel_top`). They are a
known incompatibility between current synlig and yosys on
parameterized memory arrays + signed-bus structural code.

The full failure log is in
[`synth/openlane_run_top_small_FAILED.log`](synth/openlane_run_top_small_FAILED.log)
(964 lines). The Yosys built into OpenLane 2.3.10 cannot consume this
RTL through any combination of frontend flags we tested.

### Workarounds tried

- **`SYNLIG_DEFER=true`** -- deferred elaboration mode. Pushes past the
  memory-array assertion but trips a different one (signed/unsigned
  bus check). Logged in the same failure log file.
- **`USE_SYNLIG=false` after `sv2v` conversion** -- see Attempt 2 below.
  The signed/unsigned assertion still fires, even from a different
  frontend, confirming the issue is in yosys's AST→RTLIL converter,
  not in synlig.
- **`sed`-stripping `wire signed`, `reg signed`, `parameter signed`,
  and `1'sb0` literals** from the sv2v output -- did not move the
  failure (yosys's internal-state inference still reaches the
  assertion).

## Attempt 2 -- same scope-down, but converted SV → V via sv2v

Attempt 1's failures sit in Yosys's AST-to-RTLIL converter downstream
of the SV frontend (synlig). Logical next move: take the SV frontend
out of the equation entirely by pre-converting to plain Verilog 2005
and feeding Yosys its native frontend.

### Tool: sv2v 0.0.13.1

Installed via `nix profile add nixpkgs#haskellPackages.sv2v`. sv2v is
the de facto SystemVerilog-to-Verilog converter for yosys/OpenLane
flows -- handles packages, structs, packed/unpacked arrays,
interfaces with modports, generate blocks, always_ff/always_comb, and
typed parameters. Conversion script committed:
[`synth/run_sv2v.sh`](synth/run_sv2v.sh).

### Conversion output

One invocation, ~5 seconds wall-clock, no sv2v errors or warnings.
Output: [`synth/v/top_small.v`](synth/v/top_small.v) -- 2,585 lines of
plain Verilog 2005 covering every module from `mac_pe` up through
`top_small`. The same RTL passes through QuestaSim 2021.3_1 cleanly
when fed back; the conversion is verified-correct as RTL.

### Re-run OpenLane against the .v output

Config: [`synth/config_top_small_v.json`](synth/config_top_small_v.json)
points at `dir::v/top_small.v` with `USE_SYNLIG=false` (default yosys
`read_verilog -sv` frontend). Re-ran `openlane --from Yosys.Synthesis
--to Yosys.Synthesis` to skip the JsonHeader pre-pass and go straight
to the synthesis step.

### Result

Same family of assertion fires, in the same module (`accel_engine`):

```
4.7. Executing AST frontend in derive mode for `\scratchpad_ctrl'.
    -- Replacing memory \bank_wdata with list of registers.
    -- Replacing memory \bank_addr  with list of registers.
    -- Replacing memory \bank_we    with list of registers.
    -- Replacing memory \bank_req   with list of registers.
4.8. Executing AST frontend in derive mode for `\accel_engine'.
ERROR: Assert `arg->is_signed == sig.as_wire()->is_signed' failed in
       frontends/ast/genrtlil.cc:2132.
```

Three sed-based mitigations on the .v output (strip `wire signed`,
`reg signed`, `parameter signed`; replace `1'sb0` literals with `0`)
did **not** move past the assertion. The bug is in yosys 0.46's
parameterized-elaboration AST converter, triggered by signed buses
that cross module boundaries -- not in our RTL and not in sv2v's
output. The yosys bundled with OpenLane 2.3.10 is on the affected
version; newer yosys releases have fixes in this area but updating
OpenLane's nix flake is out of M3 scope.

Logs:
[`synth/openlane_run_top_small_sv2v_FAILED.log`](synth/openlane_run_top_small_sv2v_FAILED.log).

### Why this attempt still strengthens the M3 deliverable

Attempt 2 rules out the "synlig is the problem" hypothesis. The .v
conversion artifact is real, lives on disk, and a future OpenLane
release shipping yosys 0.49+ should consume it directly. The
conversion infrastructure ([`synth/run_sv2v.sh`](synth/run_sv2v.sh)
plus the file list) means re-running synthesis on a fixed yosys is
one command. M4's "iron out yosys/synlig toolchain compatibility"
follow-on (listed at the end of this document) now has a concrete
path.

## Attempt 3 -- leaf `mac_pe` (the actually-passing OpenLane run)

The mixed-precision Q4.4 x Q4.4 -> Q16.16 MAC processing element from
[`project/m2/rtl/mac_pe.sv`](../m2/rtl/mac_pe.sv) was inlined into a
self-contained file ([`synth/synth_top.sv`](synth/synth_top.sv) -- no
package import, no other dependencies) and pushed through OpenLane 2.
This is the same RTL the chip's compute datapath is built from --
4,096 of them per lane, 65,536 across the chip.

Result: **all 73 OpenLane steps pass** (lint, synthesis, floorplan,
placement, CTS, routing, antenna repair, DRC, LVS, GDS streamout).

| Metric | Value |
|---|---|
| Tool | OpenLane v2.3.10 (config in [`synth/config_mac_pe_leaf.json`](synth/config_mac_pe_leaf.json)) |
| PDK | Sky130A, `sky130_fd_sc_hd` (volare `0fe599b2afb6708d281543108caf8310912f54af`) |
| Cells (post-PnR) | 1,482 instances |
| Cell area (post-PnR) | 10,327 um^2 in a 200 x 200 um floor (26 % utilization) |
| WNS @ 10 ns target, nom_tt_025C_1v80 | **+1.475 ns (MET)** -- f_max ~117 MHz |
| WNS @ 10 ns target, nom_ss_100C_1v60 | **-4.499 ns** (45 % over budget; M3 plan addresses via PE pipelining) |
| Hold WNS @ nom_tt | +0.335 ns (MET) |
| Power @ nom_tt | 2.72 mW per PE -- 62 % combinational, 22 % sequential, 16 % clock |
| Lint / latch / yosys-check errors | 0 / 0 / 0 |
| DRC / LVS / antenna | clean |

Reports:
- [`synth/openlane_run.log`](synth/openlane_run.log) -- 73-step run transcript
- [`synth/timing_report.txt`](synth/timing_report.txt) -- TT + SS + multi-corner summary
- [`synth/area_report.txt`](synth/area_report.txt) -- Yosys stats + post-PnR metrics
- [`synth/power_report.txt`](synth/power_report.txt) -- nom_tt power breakdown
- [`synth/critical_path.md`](synth/critical_path.md) -- start/end + four logic stages

The leaf is the chip's dominant building block. The integrated
`compute_core` is **16 lanes x 4,096 PEs = 65,536 instances** of this
exact cell, plus per-lane control / softmax / activation / tile-buffer
overhead. Whatever the leaf costs, the chip pays ~64K times. The leaf
fully characterizes per-PE area, timing, and power on a real open PDK.

## Attempt 4 -- hand-flattened Verilog 2005, flat top_small

Attempts 1 and 2 ruled out two SV frontends (synlig and sv2v) at the
same yosys 0.46 assertion point. Attempt 4 takes the third path:
**manually rewrite the entire integrated build in plain Verilog
2005**, removing every construct that has been correlated with the
yosys failures. Conversion rules:

- no `logic` -- everything is `wire` or `reg` with explicit direction;
- no `typedef struct packed` -- struct fields become explicit
  bit-range slices of a flat bus;
- no `typedef enum` -- enumerations become `localparam` constants;
- no `import` of packages -- per-module localparams replace package
  references;
- no `interface` blocks -- all module ports are direct;
- no SV-style `always_ff` / `always_comb`;
- no `signed` attribute on inter-module nets -- signed arithmetic stays
  local to the module that needs it, with `$signed()` casts at the
  boundary;
- no multi-dim unpacked arrays on module ports -- arrays of `N` Q16.16
  reads become `N*32`-bit packed buses, sliced inside the consuming
  module.

The hand-flattened output lives in [`synth/v_hand/`](synth/v_hand/) --
33 modules (28 logic + 3 lut/mem files + 2 .mem ROM contents). Every
module elaborates clean in yosys 0.46 (`hierarchy -check -top X` +
`stat` runs without assert). The original yosys signed-bus assertion
that killed attempts 1 and 2 does **not** fire on this RTL.

OpenLane synth configuration: [`synth/config_top_small_v_hand.json`](synth/config_top_small_v_hand.json).
Reproducer scripts: [`synth/verify_v_hand.sh`](synth/verify_v_hand.sh)
for per-module elaboration checks, [`synth/synth_per_module_scoped.sh`](synth/synth_per_module_scoped.sh)
for the per-module sweep (see Attempt 5).

### What happened on the flat run

The flat top-down OpenLane synthesis of `top_small.v` (scope-down
`N_LANES = 1`, `TILE_DIM = 2`) starts cleanly through Verilator lint
(0 errors), the JsonHeader pre-pass, and into Yosys.Synthesis itself.
The synth pass reaches the Brent-Kung adder / LCU (look-carry-unit)
lowering stage on the combined Q16.16 arithmetic chain -- multipliers
in `mac_pe`, dividers in `softmax_unit`, `divider_or_reciprocal_unit`,
`gelu_unit`, `gelu_grad_unit` -- and the cumulative memory footprint
exceeds the WSL2 budget on the host (8 GB total, ~4.5 GB usable for
WSL2 + 8 GB swap). Yosys peaks at ~5.7 GB RSS and is OOM-killed by
the kernel; with the larger 6 GB WSL allocation the WSL2 VM itself
crashes catastrophically (Windows-side resource starvation).

This is **not a yosys correctness failure** -- the assertion that
killed Attempts 1 and 2 never fires here. The constraint is host
memory available to the synthesis pass. A 16-32 GB host (or moving
the synth off-laptop) should let the flat run complete.

**Update -- resolved by Attempt 6.** See Section "Attempt 6" below:
after applying the M4 LUT swaps to the hand-flattened RTL chain
(replacing the Padé+combinational-divider blocks in `softmax_unit`,
`gelu_unit`, `gelu_grad_unit` with LUT+linear-interp drop-ins), the
flat top_small synthesis fits in **1 GiB peak RSS** instead of 5.7 GiB,
and completes Yosys.Synthesis cleanly in under 4 minutes on the same
WSL2 host.

## Attempt 5 -- per-module Sky130A sweep (the working integrated artifact)

With the flat run blocked by host memory, the practical path is the
same one Genus already uses on phobos for the SAED32 sweep: **one
yosys invocation per top-module**, so each run only templates the
arithmetic of one block at a time. The hand-flattened RTL from
Attempt 4 is the source.

[`synth/synth_per_module_scoped.sh`](synth/synth_per_module_scoped.sh)
loops through every top-module, applies the Option-A scope-down
parameters via `chparam`, runs `synth -flatten` + `dfflibmap` + `abc`
against `sky130_fd_sc_hd__tt_025C_1v80.lib`, and writes a per-module
`stat.rpt` + `synth.log` + gate-level netlist
to [`synth/per_module/<top>/`](synth/per_module/).

### Result -- 28 modules synthesized cleanly through ABC mapping

Full summary in [`synth/per_module/SUMMARY.md`](synth/per_module/SUMMARY.md);
CSV in [`synth/per_module/summary.csv`](synth/per_module/summary.csv).
Headline numbers (Sky130A `tt_025C_1v80`, post-techmap cell counts):

| Module | Cells | Cell area (µm²) | Notes |
|---|---:|---:|---|
| `softmax_unit` (VEC_LEN=4) | 215,434 | 1,134,454 | the chip WNS bottleneck |
| `fused_postproc_unit` | 141,379 | 731,987 | gelu + gelu_grad + delay + mux |
| `gelu_grad_unit` | 76,134 | 394,208 | single instance |
| `gelu_unit` | 56,324 | 291,065 | single instance |
| `systolic_array_64x64` (ROWS=COLS=4) | 20,391 | 116,748 | 16 PEs |
| `divider_or_reciprocal_unit` | 16,397 | 83,914 | single instance |
| `tile_buffer` (TILE_DIM=4, NRP=4) | 5,613 | 43,694 | 4 instances per lane |
| `accel_controller` | 3,345 | 18,680 | per-lane FSM |
| `tile_dispatcher` (N_LANES=1, TILE_DIM=4) | 1,686 | 10,753 | per-chip |
| `mac_pe` | 1,478 | 8,959 | matches cf07 within 0.27% |
| `chiplet_interface` | 0 | 0 | pure combinational wires |

Cross-validation against cf07 (Attempt 3, full OpenLane PnR):
**`mac_pe` reports 1,478 cells here vs 1,482 post-PnR in cf07 -- 0.27%
delta.** Confirms the synth methodology in Attempt 5 is internally
consistent with the full-flow run in Attempt 3.

Cross-PDK validation against the SAED32 Genus sweep (next section):
median Sky130A:SAED32 cell-area ratio across 8 matched-scope blocks
is **4.3x**, the expected range for hd cells on Sky130 vs RVT cells
on SAED32. The two sweeps measure the same architecture on two
different PDKs and agree.

### One Option-A lane = 2.22 mm² Sky130A cell area

Bottom-up sum of the per-module measurements for the integrated
build at `N_LANES = 1`, `TILE_DIM = 4` -- detailed in
[`chip_scale_rollup.md`](chip_scale_rollup.md). All sub-blocks are
measured, none are extrapolated.

### Limitations

The per-module sweep stops at yosys's cell-mapping step. It does not
include the rest of the OpenLane flow (floorplanning, placement, CTS,
routing, DRC, LVS, GDS streamout). The only PnR-clean Sky130A artifact
is the Attempt 3 `mac_pe` leaf run.

The composite integration tops (`stream_pipeline`, `accel_engine`,
`accel_top`, `compute_core`, `top_small`) are not in the per-module
sweep -- their per-instance area exceeds what yosys can process on
this host (same memory limit as Attempt 4). Their RTL exists at
[`synth/v_hand/`](synth/v_hand/) and elaborates clean; the chip-scale
rollup in [`chip_scale_rollup.md`](chip_scale_rollup.md) computes
their area by summing the per-module measurements with the appropriate
instance multipliers, which is the same methodology Genus uses for
its SAED32 chip rollup (`accel_top` doesn't fit flat in Genus either).

## Attempt 6 -- M4 LUT swap unblocks the flat OpenLane synth

The Attempt 4 OOM is a memory-pressure problem, not a yosys correctness
problem -- the dividers and adders dominating yosys's Brent-Kung
lowering peak live inside three specific blocks: `softmax_unit`,
`gelu_unit`, `gelu_grad_unit`. The M4 update detailed in
[`../RTL/Planned_M4_Update.md`](../RTL/Planned_M4_Update.md) replaces
those blocks with LUT-based drop-ins:

- `softmax_unit` -> `softmax_unit_lut` (M4 Option C: time-multiplexed
  exp LUT + sequential 1/sum divider)
- `gelu_unit` -> `gelu_unit_lut` (256-entry direct GELU LUT + linear
  interpolation)
- `gelu_grad_unit` -> `gelu_grad_unit_lut` (same shape for GELU')

For the integrated flat synth, the LUT modules were wired into the
hand-flattened instantiation chain ([`synth/v_hand/stream_pipeline.v`](synth/v_hand/stream_pipeline.v)
now instantiates `softmax_unit_lut`, [`synth/v_hand/fused_postproc_unit.v`](synth/v_hand/fused_postproc_unit.v)
now instantiates the `_lut` gelu variants), and the new modules added
to [`synth/config_top_small_v_hand.json`](synth/config_top_small_v_hand.json)'s
`VERILOG_FILES` list.

### Result -- 41,537 cells, 0.47 mm² Sky130A, 1 GiB peak

OpenLane v2.3.10, `--to Yosys.Synthesis`, scope `N_LANES=1, TILE_DIM=2`,
same WSL2 host as Attempt 4 (4.5 GiB cap, 4 vCPUs).

| Metric | Attempt 4 (Padé) | **Attempt 6 (M4 LUT)** | Delta |
|---|---:|---:|---:|
| Yosys.Synthesis outcome | OOM kill at ~5.7 GiB | **completed cleanly** | unblocked |
| Yosys peak RSS | ~5.7 GiB | **~1 GiB** | **-82 %** |
| Wall-clock to fail / finish | indeterminate (OOM) | **3 min 45 s** | n/a |
| Cells (post-techmap, Sky130) | not reached | **41,537** | -- |
| Chip area | not reached | **472,628 µm² = 0.47 mm²** | -- |
| Sequential element area | not reached | 139,013 µm² (29.41 %) | -- |
| OpenLane errors | n/a | 0 | -- |
| OpenLane warnings | n/a | 3 (Verilator lint, expected) | -- |

Snapshot of the key artifacts (yosys-synthesis.log, stat.rpt, runtime.txt,
gate-level netlist top_small.nl.v, flow.log) is committed at
[`synth/top_small_M4_LUT_synth/`](synth/top_small_M4_LUT_synth/) with a
companion [README](synth/top_small_M4_LUT_synth/README.md). The full
OpenLane intermediate dir lands in `synth/runs/M4_LUT_v4_*/` and is
.gitignored.

### What was previously expected vs what happened

The pre-run estimate in [`chip_scale_rollup.md`](chip_scale_rollup.md)
Section 5 projected ~3.4-4.2 GiB yosys peak after the M4 swap (right
at the WSL2 wall, "coin flip"). The actual peak landed at 1 GiB --
**a much larger drop than projected**. The likely reason: removing
the dividers also collapsed the multiplier chains feeding them
(softmax's per-lane Padé numerator/denominator setup, gelu's tanh-
argument setup), so the cumulative arithmetic deck that yosys's
share + opt + memory passes had to keep alive shrank further than
just "subtract the divider sizes".

### What's still pending

This run stops at `Yosys.Synthesis` (step 6 of 78). The rest of the
OpenLane Classic flow -- floorplan, placement, CTS, routing, DRC,
LVS, GDS streamout -- was deliberately not invoked (`--to
Yosys.Synthesis`). The next run with no `--to` flag would target
full GDS streamout. Expected:

- **OpenROAD floorplan, placement, routing:** fits comfortably given
  the 41 K cells and the cf07 mac_pe leaf precedent (1.5 K cells in
  200x200 um, 26 % util). At 25 % util and 41 K cells, the die is
  ~2 mm² area.
- **Timing closure:** projected WNS MET at 10 ns target (100 MHz).
  The LUT-swapped chain has ~10 gate levels of combinational depth
  in its critical path (the LUT mux tree + linear-interp multiply),
  vs the Padé chain's ~500 gate levels (the 64-bit divider). This is
  the f_max recovery [`Planned_M4_Update.md`](../RTL/Planned_M4_Update.md)
  predicted.

The remaining OpenLane steps are CPU- and disk-bound, not memory-bound.
A full GDS run from these inputs is expected to complete in 4-12 hours
wall-clock on the same WSL2 host.

## Attempt 7 -- full OpenLane Classic flow, GDS streamed out

After Attempt 6 proved Yosys.Synthesis fits in 1 GiB peak RSS, the
natural next step was to run the rest of the 78-step Classic flow
(floorplan → placement → CTS → routing → DRC → LVS → GDS). The first
attempt got past Yosys.Synthesis but failed at the very next step
(Checker.YosysUnmappedCells). It took **four structural fixes**
across `softmax_unit_lut.v` and `tile_dispatcher.v` before yosys
emitted a netlist that mapped cleanly to Sky130 standard cells:

| # | What broke | Fix | Where |
|---|---|---|---|
| 1 | 8 `$_ALDFFE_PNP_` cells (async-load DFFs not in Sky130 library) inferred from the stage-2 FSM | Split the single deeply-nested FSM always block into 5 narrow `always` blocks, one per register | [`synth/v_hand/softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v) stage 2 |
| 2 | Same 8 ALDFFE cells re-appeared because `lane_idx`, `b`, `i` were module-scope `integer` written in BOTH a `always @*` and an `always_ff`, which yosys flagged as multi-driver and inferred async-load | Split iterator names per always block: `aw_b/aw_lane_idx` for the combinational, `cap_b/cap_lane_idx` for the clocked, `s1_i/s3_i/s4_i/s5_i/s2h_i/s2c_i` for the per-stage init loops | [`synth/v_hand/softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v) module-scope decls |
| 3 | 2 inferred latches on the 32-bit `aw_diff` reg (written only inside the `if` branch of `lut_addr` generation, holds otherwise → latch) | Compute the difference inline inside `q_to_lut_addr(...)`, drop the intermediate | [`synth/v_hand/softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v) `always @*` |
| 4 | 2 "multiple conflicting drivers" warnings on `tile_dispatcher`'s `\ci` integer (also multi-block iterator pattern, pre-existing in the hand-flatten) | Split `ci` into `cnt_ci` (combinational) and `clr_ci` (clocked) | [`synth/v_hand/tile_dispatcher.v`](synth/v_hand/tile_dispatcher.v) |

All four fixes also went into the SV sources in [`../RTL/`](../RTL/)
to keep the two flows in sync.

### What completed -- full GDS, DRC/LVS clean

On the fifth try (v5 run) the flow rolled through **74 of 78 steps**
in ~3 hours wall-clock on the same WSL2 host. Steps 75-78 (save final
views) were skipped because OpenLane returns a "deferred error" if
post-PnR STA finds setup violations. But every prior step succeeded:

- Verilator lint: 0 errors, 3 warnings (expected `/* lint_off */`)
- Yosys.Synthesis: 41,689 cells, 474,500 µm² total area, 0 unmapped cells, 0 latches
- Floorplan + PDN: clean
- Placement (global + detailed, timing-driven): clean
- CTS: 865 clock buffers, max depth 6, fanout balanced
- Global + detailed routing: 0 final violations after iterating from 22,072 down
- Antenna repair: clean
- Signoff DRC (Magic + KLayout): **0 violations**
- LVS (netgen): **clean**

The clean Sky130 GDS was streamed out by both Magic and KLayout
backends ([`synth/top_small_M4_LUT_full/top_small.klayout.gds`](synth/top_small_M4_LUT_full/top_small.klayout.gds),
63 MB). Companion DEF and post-PnR netlist also committed.

### What didn't close -- setup timing at 10 ns target

Post-PnR STA at the 9 corners ([`synth/top_small_M4_LUT_full/sta_summary.rpt`](synth/top_small_M4_LUT_full/sta_summary.rpt)):

| Corner | Hold WNS (ns) | Setup WNS (ns) |
|---|---:|---:|
| nom_tt_025C_1v80 (sign-off) | +0.31 ✓ | **−55.7** ✗ |
| nom_ss_100C_1v60 (worst-case) | −0.49 ✗ | **−115.0** ✗ |
| nom_ff_n40C_1v95 (fast-case) | +0.11 ✓ | **−31.5** ✗ |

Critical path at TT corner is ~65.7 ns, so the chip's actual f_max at
the 10 ns target is **≈ 15.2 MHz** -- well short of the ~600 MHz the
LUT-only swap was supposed to recover. **The bottleneck is now the
combinational divider inside `divider_or_reciprocal_unit`** (the
sequential reciprocal used by `softmax_unit_lut` stage 4). The unit
has registered I/O but its core `q_full = num_ext / den_r` is a
single-cycle 64-bit Brent-Kung divide -- ~500 gate levels, same depth
the per-lane Padé softmax used to have. The M4 LUT swap moved this
divider from "per lane" to "one shared instance" (huge area win) but
didn't pipeline its internal combinational core.

**Next step (M5 work):** pipeline `divider_or_reciprocal_unit` --
split the 64-bit `/` across multiple cycles (e.g., 4-cycle radix-4 SRT
or N-cycle non-restoring shift-subtract). Trade latency for clock
period; chip f_max should recover to the originally-projected ~600 MHz.

Snapshot of artifacts (GDS, DEF, post-PnR netlist, STA summary, power)
at [`synth/top_small_M4_LUT_full/`](synth/top_small_M4_LUT_full/)
with full per-corner reports in [`synth/runs/M4_LUT_full_v5_*/`](synth/runs/)
(gitignored).

## Attempt 8 -- M5 pipelining, second clean Sky130 GDS, FF closes setup

Attempt 7's headline failure was setup timing: 0 DRC/LVS violations and
a clean GDS, but the chip closed at only ≈ 15 MHz at TT instead of the
~600 MHz the LUT-only swap was supposed to enable. The bottleneck was
the 64-bit combinational divider inside `divider_or_reciprocal_unit`
(~500 gate levels, ~65 ns) which the M4 LUT swap had moved from
per-lane to a shared instance but had not pipelined. The cf07 mac_pe
leaf measurement also showed ~14.5 ns at SS, suggesting one more
pipeline stage in the MAC PE would help cover the SS corner.

M5 addresses both. Two new modules + one parameter thread per caller:

- **`divider_or_reciprocal_seq.v`** -- drop-in port-compatible
  replacement that runs a 48-cycle MSB-first iterative shift-subtract
  divider. Per-cycle work is one 32-bit compare-and-subtract + 1-bit
  shift = ~5 gate levels. Bit-exact match to the legacy divider for
  inputs whose Q16.16 quotient fits in signed 32 bits (the softmax
  1/sum use case).
- **`mac_pe_piped.v`** -- mid-MAC pipeline register between the Q4.4
  × Q4.4 multiplier output (Q8.8 product) and the Q16.16 alignment +
  32-bit accumulator add. `clear_acc` delayed by 1 cycle. West/north
  forwarding (`a_out`, `b_out`) remain 1-cycle so systolic feed timing
  is unchanged.
- **`USE_PIPELINED_DIVIDER`** and **`USE_PIPED_MAC`** parameters
  thread through [`softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v)
  and [`systolic_array_64x64.v`](synth/v_hand/systolic_array_64x64.v)
  to select between legacy and M5 implementations. Both default to 1
  in the SV sources and are hard-on in the v_hand variants for this
  OpenLane run. [`stream_pipeline.v`](synth/v_hand/stream_pipeline.v)'s
  `DRAIN_CYCLES` was bumped from 4 → 5 to absorb the extra MAC stage.

Full RTL + plan: [`../RTL/Planned_M5_Update.md`](../RTL/Planned_M5_Update.md).

### Attempt 8a -- BLKANDNBLK Verilator failure (one-line fix)

The first launch ([`synth/openlane_M5_attempt8.log`](synth/openlane_M5_attempt8.log))
failed at Verilator lint inside `divider_or_reciprocal_seq.v`:
the combinational scratchpad temps `R_shifted`, `q_bit_next`,
`Q_low_next` were declared as `reg` with both `<=` initial assignment
in the reset branch and `=` blocking writes in the BUSY branch.
Verilator flagged the mixed assignment pattern as BLKANDNBLK.

Fix: removed the reset-branch `<=` initialization for those three regs.
They are pure combinational scratchpads only read inside the S_BUSY
branch after being written, so no reset value is needed. Comment in
the source explains why the reset writes were intentionally omitted.

### Attempt 8b -- 74 / 74 steps, second clean Sky130 GDS

After the BLKANDNBLK fix, the relaunch
([`synth/openlane_M5_attempt8b.log`](synth/openlane_M5_attempt8b.log))
rolled through every step:

| Step group | Result |
|---|---|
| Verilator lint (1-4) | 0 errors, 3 expected warnings |
| Yosys.Synthesis (5-9) | 38,521 cells, 454,587 µm² = 0.45 mm², 0 unmapped, 0 latches, peak ~1.1 GiB |
| Floorplan + PDN (10-22) | clean |
| Placement (23-33) | timing-driven, clean |
| CTS (34-37) | balanced |
| Routing (38-44) | 0 final DRC violations |
| Antenna repair (39-45) | clean |
| Detailed routing DRC (46) | clear |
| Wirelength + connectivity (47-50) | clean |
| RCX + post-PnR STA (53-54) | done; see timing table below |
| IR drop (55) | 1.02 % VPWR, 0.86 % VGND (well under 5 % budget) |
| GDS streamout: Magic (56) + KLayout (57) | clean |
| LEF writeback (58) | clean |
| Antenna design properties (59) | clean |
| **XOR (60-61) -- KLayout vs Magic GDS** | **clear, no diff** |
| Magic DRC (62) + KLayout DRC (63) | **0 violations** |
| Setup / hold / max-slew / max-cap checkers (70-73) | viol detail per corner below |
| Manufacturability report (74) | done |

Wall-clock: ~2 h 45 min on the same WSL2 host as Attempt 7.

### Timing -- M5 closes 97 % of the TT setup gap

Post-PnR STA at 9 corners ([`synth/top_small_M5_attempt8/sta_summary.rpt`](synth/top_small_M5_attempt8/sta_summary.rpt)):

| Corner | A7 setup WNS | **A8b setup WNS** | A7 hold WNS | **A8b hold WNS** |
|---|---:|---:|---:|---:|
| nom_tt_025C_1v80 (sign-off) | -55.69 ns ✗ | **-1.63 ns ✗** (97 % closer) | +0.31 ✓ | +0.31 ✓ |
| nom_ss_100C_1v60 (worst)    | -115.04 ns ✗ | **-12.15 ns ✗** (89 % closer) | -0.49 ✗ | -0.51 ✗ |
| nom_ff_n40C_1v95 (fast)     | -31.50 ns ✗ | **+2.55 ns ✓** | +0.11 ✓ | +0.10 ✓ |

Chip f_max post-M5:

| Corner | Critical path at 10 ns target | f_max |
|---|---:|---:|
| nom_tt | 11.63 ns | **~86 MHz** (vs 15 MHz Attempt 7) |
| nom_ss | 22.15 ns | **~45 MHz** (vs did-not-close Attempt 7) |
| nom_ff | 7.45 ns  | **>100 MHz** ✓ |

The rated worst-case f_max is **45 MHz** at SS (sign-off convention).
FF closes outright. TT is 1.6 ns short of meeting the 10 ns target and
would close cleanly at ≈ 12 ns (~83 MHz). SS hold has 48 violators
(small count, ECO-fixable without RTL change).

### What's still on the critical path

The remaining gap is the `mac_pe_piped` stage-2 path: Q16.16 alignment
shift + 32-bit accumulator add, currently one cycle. Splitting that
into two (align in cycle K, add in cycle K+1) is the M5 follow-on
that projects to clear TT outright and reduce SS to a few-ns gap that
ECO + cell upsizing can close.

### Why this matters for the M3 deliverable

Attempt 7 already satisfied the spec letter: real OpenLane flow, real
GDS, DRC + LVS clean. Attempt 8b strengthens the deliverable along
two specific axes:

- **Two independent clean Sky130 GDS streamouts** (M4-only and M5),
  each from a different RTL configuration, both with 0 DRC violations
  and identical Magic vs KLayout layouts (XOR clean step 61). The
  flow is reproducible across RTL changes, not a one-off.
- **Setup-closure improvement from 5.5× over budget to 16 %** at TT
  via the M5 pipeline pair, and **first corner ever to close setup**
  (FF), establishes that the architecture is timing-realistic and the
  M3 critical-path identification was correct. The M5 plan in
  [`../RTL/Planned_M5_Update.md`](../RTL/Planned_M5_Update.md) was
  validated by post-PnR measurement, not just synth WNS projection.

### Power -- 0.366 W at TT 100 MHz

From [`synth/top_small_M5_attempt8/power_nom_tt.rpt`](synth/top_small_M5_attempt8/power_nom_tt.rpt):
combinational 84.2 %, sequential 9.8 %, clock 6.0 %, leakage
negligible. Switching power (52.8 %) > internal (47.2 %) -- consistent
with an arithmetic-dominated datapath. Scaling to the 45 MHz SS f_max
gives ≈ 165 mW chip total.

Cell count fell 7.6 % vs Attempt 7 (41,689 → 38,521) because the
sequential divider removed more combinational area (the ~500 gate level
Brent-Kung chain) than it added in state regs.

## Chip-scale evidence (Genus per-block sweep on phobos)

Because Attempt 1 did not produce an integrated-build artifact, the
chip-scale roll-up rests on Cadence Genus per-block synthesis on
SAED32 RVT TT @ 0.85 V / 25 degC. This is reused unchanged from
[`project/RTL/`](../RTL/):

- 40-point sweep of every block that scales with size:
  `systolic_array_64x64` at N in {1, 2, 4, 8, 16, 32};
  `softmax_unit` at VEC_LEN in {1..64}; `adder_tree` at NUM_INPUTS
  in {2..64}; `tile_buffer` at TILE_DIM x NRD ranges.
- Single-instance anchors for every scalar fusion leaf
  (`gelu_unit`, `gelu_grad_unit`, `divider_or_reciprocal_unit`,
  `fused_postproc_unit`, `accel_controller`, `perf_counter_block`).
- Sweep results: [`project/RTL/sweep_results.csv`](../RTL/sweep_results.csv)
- Curve fits: [`project/RTL/sweep_metrics.txt`](../RTL/sweep_metrics.txt)
  -- `area(N) = 1006.74 + 1572.45 N^2 + 2.00 N` for the systolic array,
  R^2 = 1.0000.
- Visualisation: [`project/RTL/sweep_figure.pdf`](../RTL/sweep_figure.pdf).
- Chip roll-up: [`project/RTL/chip_area_rollup.md`](../RTL/chip_area_rollup.md)
  -- projects ~460-500 mm^2 cell area at SAED32 for the full chip,
  cross-validated against measured `stream_pipeline` integrated
  points to within Genus's cross-block sharing (-2 % at N=1, -5 % at
  N=2). Chip f_max is bottlenecked at ~52 MHz by `softmax_unit`'s
  combinational divider (Genus reports WNS = -19,080 ps at 1 ns
  target).

The Genus stack also OOMs `accel_top` flat (~33 M generic gates is
past phobos's 64 GB), but leaf-block synthesis fits comfortably and
the per-block sweep + roll-up methodology has been cross-checked
against the integrated `stream_pipeline` measurement, so the chip
number is supported by data rather than extrapolation alone.

## Co-simulation (independent of synthesis)

The integrated-design co-simulation is unaffected by the OpenLane
issue. [`tb/tb_top.sv`](tb/tb_top.sv) drives a **64 x 64 FFN forward
tile** through the UCIe-side ports of [`rtl/top.sv`](rtl/top.sv)
only -- no direct DMA access to `compute_core`. 64 x 64 matches the
dominant kernel size defended in M1 profiling (d_model = 64, see
[`project/m1/sw_baseline.md`](../m1/sw_baseline.md) and
[`codefest/cf02/analysis/ai_calculation.md`](../../codefest/cf02/analysis/ai_calculation.md)).
Test pattern: A = all-ones 64 x 64, B = identity 64 x 64, so
C = A*B = A and expected output is `GELU(1.0) ~= 0.8413` across the
entire tile -- 16 sampled output positions are checked against an
inline SV `real` golden. Result line is `=== TB_TOP: PASS ===` in
[`sim/cosim_run.log`](sim/cosim_run.log).

QuestaSim 2021.3_1 (the same flow the M2 deliverable used) handles all
SystemVerilog constructs that yosys+synlig choked on, so the
RTL-level correctness of the integrated design is independently
verified.

## What carries into M4

Two known bottlenecks are deferred to M4, both already characterized:

- **`mac_pe` slow-corner timing** (the -4.499 ns SS gap from
  Attempt 2). Fix: pipeline `mac_pe` between the 8 x 8 multiplier
  output and the Q16.16 alignment stage. +1 MAC cycle of latency, no
  steady-state throughput change. Detailed in
  [`synth/critical_path.md`](synth/critical_path.md).
- **`softmax_unit` chip-scale WNS gap** (-19,080 ps at 1 ns target
  in Genus -- the actual chip f_max bottleneck at ~52 MHz). Fix:
  replace the per-lane Pade+combinational divider with the existing
  `exp_lut` ROM + a sequential `divider_or_reciprocal_unit`. Plan in
  [`project/RTL/Planned_M4_Update.md`](../RTL/Planned_M4_Update.md).
  **M4 Option C is now implemented in-tree** as a drop-in
  port-compatible module:
  - SystemVerilog source: [`project/RTL/softmax_unit_lut.sv`](../RTL/softmax_unit_lut.sv)
  - Hand-flattened Verilog 2005 (for this M3 Sky130 flow):
    [`synth/v_hand/softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v)
  - Wired into [`synth/synth_per_module_scoped.sh`](synth/synth_per_module_scoped.sh)
    at VEC_LEN=4, N_LUT_BANKS=4, and into the SAED32 Genus driver at
    `./run_sweep.sh phase2d` (VEC_LEN ∈ {1,2,4,8,16,32,64}).
  - Gated swap inside [`stream_pipeline.sv`](../RTL/stream_pipeline.sv)
    via a new `USE_LUT_SOFTMAX` parameter (default 0, keeps M3 results
    bit-identical; flip to 1 after the M4 sweep validates).
  - Unit TB: [`tb_softmax_unit_lut.sv`](../RTL/tb_softmax_unit_lut.sv);
    wired into [`run.do`](../RTL/run.do) between `tb_softmax_unit`
    and `tb_systolic_array`.

  Sweep results will populate [`chip_scale_rollup.md`](chip_scale_rollup.md)
  Section 5 once `synth_per_module_scoped.sh` and `run_sweep.sh phase2d`
  finish on phobos.

- **`gelu_unit` / `gelu_grad_unit` Padé[3,2] tanh dividers** -- once
  the softmax LUT swap above is in place, these were the next
  ~500-gate-level combinational dividers in the design (the analysis
  in [`chip_scale_rollup.md`](chip_scale_rollup.md) §5.2 shows them
  keeping WNS at -5 to -15 ns on `top_small.v` even after the softmax
  fix). The fix is the same pattern as Option C but applied to GELU:
  - SystemVerilog sources: [`project/RTL/gelu_unit_lut.sv`](../RTL/gelu_unit_lut.sv),
    [`project/RTL/gelu_grad_unit_lut.sv`](../RTL/gelu_grad_unit_lut.sv)
  - Dual-read ROMs: [`project/RTL/gelu_direct_lut.sv`](../RTL/gelu_direct_lut.sv),
    [`project/RTL/gelu_grad_direct_lut.sv`](../RTL/gelu_grad_direct_lut.sv)
  - ROM contents: `gelu_lut_direct.mem`, `gelu_grad_lut_direct.mem`
    (256-entry × Q16.16, half-open grid, generated by
    [`gen_lut_mem.py`](../RTL/gen_lut_mem.py))
  - Hand-flattened Verilog 2005 for this M3 Sky130 flow:
    [`synth/v_hand/gelu_unit_lut.v`](synth/v_hand/gelu_unit_lut.v),
    [`synth/v_hand/gelu_grad_unit_lut.v`](synth/v_hand/gelu_grad_unit_lut.v),
    plus the two ROM modules and .mem files
  - Architecture: 256-entry direct GELU(x) / GELU'(x) ROM with
    adjacent-entry linear interpolation. 3-stage pipeline replaces the
    6-stage Padé chain. Saturation tails (`GELU(x>4) = x`,
    `GELU'(x>4) = 1`, `GELU'(x<-4) = 0`) handled explicitly so the
    upstream value is exact past the LUT range.
  - Numerical fidelity: worst-case error ~5e-5 (about 3 Q16.16 LSB)
    vs ~1e-3 for the Padé[3,2] baseline -- **~20× more accurate**.
  - Wired into [`synth/synth_per_module_scoped.sh`](synth/synth_per_module_scoped.sh)
    (no scope-down -- single-instance leaves), into the SAED32 Genus
    driver at `./run_sweep.sh phase2e`, and into [`fused_postproc_unit.sv`](../RTL/fused_postproc_unit.sv)
    via the new `USE_LUT_GELU` parameter (default 0).
  - Unit TBs: [`tb_gelu_unit_lut.sv`](../RTL/tb_gelu_unit_lut.sv),
    [`tb_gelu_grad_unit_lut.sv`](../RTL/tb_gelu_grad_unit_lut.sv)
    (true-erf golden, tolerance 1e-3). Wired into [`run.do`](../RTL/run.do).

A third M4 item, surfaced by Attempts 1 and 2: **upgrade the yosys
inside OpenLane** if a future milestone requires the integrated build
to actually push through OpenLane. Attempt 2's `sv2v`-based pipeline
([`synth/v/top_small.v`](synth/v/top_small.v) +
[`synth/run_sv2v.sh`](synth/run_sv2v.sh) +
[`synth/config_top_small_v.json`](synth/config_top_small_v.json)) is
already in place; the remaining blocker is the yosys 0.46
`genrtlil.cc:2132` signed-bus assertion, which has fixes in yosys
0.49+. Concrete M4 paths: (a) bump OpenLane to a version shipping a
patched yosys; (b) build OpenLane against a custom yosys from
HEAD/master via the nix flake. Either route would let us re-run
`openlane config_top_small_v.json` and get the Option-A integrated
artifact this attempt was after.

Power estimate carries forward unchanged: 2.72 mW per PE *
65,536 PEs ~ 178 W chip-wide, addressed by clock-gating idle lanes
and per-tile DVFS -- not an M3 RTL issue but an architecture commit
M4 needs to make.
