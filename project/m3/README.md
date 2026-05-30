# M3 -- Integration and Synthesis Milestone

This folder is the M3 deliverable for the mixed-precision (Q4.4 x Q4.4 ->
Q16.16) transformer accelerator chiplet. Three things live here:

1. The integrated top module ([`rtl/top.sv`](rtl/top.sv)) that wires the
   M2 `chiplet_interface` (UCIe protocol adapter) to the M2 `compute_core`
   (16-lane fused matmul+activation engine).
2. The end-to-end co-simulation ([`tb/tb_top.sv`](tb/tb_top.sv)) driving
   a 64 x 64 FFN forward tile through the UCIe-side ports only.
3. The OpenLane 2 synthesis artifacts ([`synth/`](synth/)) -- the leaf
   `mac_pe` cell that the chip is built from, plus the scope-adjustment
   rationale in [`synthesis_notes.md`](synthesis_notes.md).

## File catalog

| Path | Description |
|---|---|
| [`README.md`](README.md) | this file -- catalog + reproduction instructions |
| [`rtl/top.sv`](rtl/top.sv) | integrated top: `chiplet_interface` + `compute_core`, no glue |
| [`tb/tb_top.sv`](tb/tb_top.sv) | end-to-end cosim TB; drives UCIe pins only, prints PASS/FAIL |
| [`sim/run_top.do`](sim/run_top.do) | QuestaSim driver script -- compiles RTL + TB, runs `tb_top` |
| [`sim/wave.do`](sim/wave.do) | wave-window setup (UCIe link + interface/core boundary + lane-0 internals) |
| [`sim/cosim_run.log`](sim/cosim_run.log) | QuestaSim transcript containing `=== TB_TOP: PASS ===` |
| [`sim/cosim_waveform.png`](sim/cosim_waveform.png) | end-to-end waveform: host write -> compute -> host read |
| [`synth/config.json`](synth/config.json) | OpenLane config for the **scope-down integrated build** (`top_small`, Option A) -- the one that did not synthesize |
| [`synth/accel_pkg.sv`](synth/accel_pkg.sv) | scoped-down package: ARRAY=4x4, TILE=4, scratchpad shrunk |
| [`synth/accel_engine.sv`](synth/accel_engine.sv) | scoped fork of M2 engine -- `TILE_DIM = TILE_SIZE` instead of hardcoded 64 |
| [`synth/accel_top.sv`](synth/accel_top.sv) | scoped fork of M2 top -- `.TILE_DIM(TILE_SIZE)` on dispatcher |
| [`synth/top_small.sv`](synth/top_small.sv) | integrated top wired same as `rtl/top.sv`, with `N_LANES=1` |
| [`synth/exp_lut.mem`](synth/exp_lut.mem), [`synth/gelu_tanh_lut.mem`](synth/gelu_tanh_lut.mem) | LUT ROM contents (copied for `$readmemh`) |
| [`synth/openlane_run_top_small_FAILED.log`](synth/openlane_run_top_small_FAILED.log) | Attempt 1 failure: integrated `top_small` via yosys+synlig SV frontend (memory-array / signed assertions) |
| [`synth/run_sv2v.sh`](synth/run_sv2v.sh) | script that converts the integrated SV stack to plain Verilog 2005 via sv2v 0.0.13.1 |
| [`synth/v/top_small.v`](synth/v/top_small.v) | sv2v output -- 2,585 lines of plain Verilog 2005, verified-correct against the SV source by QuestaSim |
| [`synth/config_top_small_v.json`](synth/config_top_small_v.json) | OpenLane config that consumes `v/top_small.v` (USE_SYNLIG=false, native yosys SV-lite frontend) |
| [`synth/openlane_run_top_small_sv2v_FAILED.log`](synth/openlane_run_top_small_sv2v_FAILED.log) | Attempt 2 failure: same RTL after sv2v, still hits yosys 0.46 signed-bus assertion (rules out the SV frontend as the cause) |
| [`synth/config_mac_pe_leaf.json`](synth/config_mac_pe_leaf.json) | OpenLane config for the **leaf `mac_pe`** run -- the one that did synthesize |
| [`synth/synth_top.sv`](synth/synth_top.sv) | self-contained inline of `mac_pe.sv` (the synthesized leaf RTL) |
| [`synth/openlane_run.log`](synth/openlane_run.log) | full 73-step OpenLane log from the successful `mac_pe` leaf run |
| [`synth/timing_report.txt`](synth/timing_report.txt) | leaf STA: typical, slow, multi-corner summary |
| [`synth/area_report.txt`](synth/area_report.txt) | leaf yosys stats + post-PnR area metrics |
| [`synth/power_report.txt`](synth/power_report.txt) | leaf power breakdown at `nom_tt_025C_1v80` |
| [`synth/critical_path.md`](synth/critical_path.md) | leaf critical path start/end + logic stages, with chip-scale framing |
| [`synth/v_hand/`](synth/v_hand/) | **Attempt 4** -- 33 hand-flattened Verilog 2005 modules (no `logic`, no structs, no SV-isms). Every module elaborates clean in yosys. Plus M4 LUT-based drop-ins staged for the M4 sweep: [`synth/v_hand/softmax_unit_lut.v`](synth/v_hand/softmax_unit_lut.v) (LUT exp + sequential 1/sum), [`synth/v_hand/gelu_unit_lut.v`](synth/v_hand/gelu_unit_lut.v) and [`synth/v_hand/gelu_grad_unit_lut.v`](synth/v_hand/gelu_grad_unit_lut.v) (256-entry direct LUT + linear interp), plus the two ROM modules + .mem contents. |
| [`synth/config_top_small_v_hand.json`](synth/config_top_small_v_hand.json) | OpenLane config for the hand-flattened flat top_small synth (**Attempt 6**: passes through Yosys.Synthesis at 1 GiB peak RSS with M4 LUT swaps wired into the chain; previously OOM'd at 5.7 GiB with the Padé chain) |
| [`synth/top_small_M4_LUT_synth/`](synth/top_small_M4_LUT_synth/) | **Attempt 6 artifacts** -- snapshot of the first successful flat OpenLane Yosys.Synthesis of `top_small.v` (gate-level netlist + reports + log). 41,537 Sky130 cells, 0.47 mm² cell area, 3 min 45 s wall-clock |
| [`synth/top_small_M4_LUT_full/`](synth/top_small_M4_LUT_full/) | **Attempt 7 artifacts** -- first end-to-end OpenLane full flow on `top_small.v` (74/78 steps including GDS streamout). Clean DRC + LVS. Setup violations at 10 ns target (chip f_max ≈ 15 MHz, divider bottleneck). KLayout GDS (63 MB), final DEF (60 MB), post-PnR netlist, STA + power summaries |
| [`synth/top_small_M5_attempt8/`](synth/top_small_M5_attempt8/) | **Attempt 8b artifacts** -- second clean Sky130 GDS, now with M5 pipelined divider + piped MAC. Full 74-step Classic flow completed. DRC/LVS/XOR/antenna clean. **M5 closes 97 % of the TT setup gap (-55.7 → -1.6 ns) and is the first run to close setup outright at FF.** Rated worst-case f_max **45 MHz at SS** (vs did-not-close in Attempt 7). 38,521 cells / 0.45 mm² (7.6 % smaller than Attempt 7 because the combinational divider was replaced). Text-only snapshot (sta_summary.rpt, power_nom_tt.rpt, yosys_stat.rpt); GDS / DEF / netlist live in the gitignored OpenLane run dir |
| [`synth/verify_v_hand.sh`](synth/verify_v_hand.sh) | yosys elaboration check per module (`hierarchy -check; stat`) |
| [`synth/synth_per_module_scoped.sh`](synth/synth_per_module_scoped.sh) | **Attempt 5** -- per-module Sky130A synthesis sweep with scope-down `chparam` overrides |
| [`synth/synth_remaining_small.sh`](synth/synth_remaining_small.sh) | follow-up sweep for the small control modules |
| [`synth/collect_summary.sh`](synth/collect_summary.sh) | walks `per_module/*/stat.rpt`, emits the table |
| [`synth/per_module/`](synth/per_module/) | per-module synth outputs: one subdir per module with `stat.rpt`, `synth.log`, `<top>.synth.v` -- **28 modules** total |
| [`synth/per_module/SUMMARY.md`](synth/per_module/SUMMARY.md) | sortable cell-count / area table across all 28 modules |
| [`synth/per_module/summary.csv`](synth/per_module/summary.csv) | machine-readable summary (module, cells, area, scope) |
| [`chip_scale_rollup.md`](chip_scale_rollup.md) | bottom-up chip-area projection from the per-module measurements; cross-PDK validation against the SAED32 Genus sweep in `project/RTL/` |
| [`synthesis_notes.md`](synthesis_notes.md) | narrative: eight synthesis attempts (Attempt 7 = full OpenLane PnR + GDS streamout on top_small with M4 LUT swaps; Attempt 8b = M5 pipelining closes 97 % of the TT setup gap and produces a second clean GDS that closes setup at FF; rated worst-case f_max 45 MHz at SS), what failed and why, what passed, chip-scale rollup, what carries forward |

## Tool versions

| Tool | Version | Used for |
|---|---|---|
| QuestaSim | **2021.3_1** (phobos) | co-simulation (`vsim`/`vlog`); SystemVerilog 2017 |
| OpenLane 2 | **v2.3.10** (WSL2) | physical synthesis through GDS |
| Sky130A PDK (volare) | commit `0fe599b2afb6708d281543108caf8310912f54af` | OpenLane PDK |
| Std-cell lib | `sky130_fd_sc_hd` | OpenLane standard cells |
| Cadence Genus (cross-reference, see `project/RTL/`) | 21.12-s068_1 | per-block area sweep on SAED32 |

## Reproduce the co-simulation

The cosim runs on QuestaSim 2021.3_1 (same flow as M2). Same simulator
SystemVerilog support, same `.do`-script idioms, same `vlog`/`vsim`
invocation. The path inside the repo is `project/m3/sim/`; the script
re-uses the unmodified M2 RTL under `project/m2/rtl/`.

```sh
cd project/m3/sim
vsim -do run_top.do
# -> writes cosim_run.log
# -> populates the wave window; export via File -> Export -> Image
#    as cosim_waveform.png (see the run_top.do tail for the path)
```

To grep the result:

```sh
grep -E '^=== TB_TOP:' cosim_run.log
```

You should see one `=== TB_TOP: PASS ===` line. The testbench drives
the chiplet through `ucie_cmd_*`, `ucie_wr_*`, `ucie_rd_*` only -- no
direct access to `compute_core`'s DMA ports.

### What `tb_top` exercises

| Phase | What happens | Interface used |
|---|---|---|
| 1. Load A (64x64 all-ones) | 4,096 host writes into lane-0 scratchpad | `ucie_wr_valid/data/ready` |
| 2. Load B (64x64 identity) | 4,096 host writes into lane-0 scratchpad | `ucie_wr_valid/data/ready` |
| 3. Issue `MODE_FFN_FWD` macro | packed `macro_cmd_t` -> 64 x 64 tile, 1 tile total | `ucie_cmd_valid/data/ready` |
| 4. Internal compute | matmul -> GELU streaming pipeline runs autonomously | (inside `compute_core`) |
| 5. Wait for completion | `ucie_irq` (= `compute_core.irq`) asserts | `ucie_irq` |
| 6. Sample 16 outputs | reads at corners, diagonal, edges, interior of the output tile | `ucie_rd_req/addr/data/valid` |
| 7. Verify each ~= GELU(1.0) | SV `real` golden, tolerance 0.05 | (testbench) |

Kernel size matches the M1 dominant kernel: d_model = 64 from
[`project/m1/sw_baseline.md`](../m1/sw_baseline.md). The 64 x 64 tile
fills the systolic array completely (4,096 active PEs).

## Reproduce the OpenLane synthesis (two runs)

Two synthesis attempts are committed under [`synth/`](synth/). See
[`synthesis_notes.md`](synthesis_notes.md) for the full narrative of
what each one did and why.

### Run 1 (the one that failed) -- integrated `top_small`

`synth/config.json` targets `DESIGN_NAME = top_small` and lists the
scoped-down RTL ([`synth/accel_pkg.sv`](synth/accel_pkg.sv) etc.) plus
the unmodified M2 RTL. To reproduce the failing run on WSL2 with
OpenLane 2.3.10 and the volare Sky130A PDK already installed:

```sh
cd project/m3/synth
# Strip Windows-side /mnt/ entries from PATH so WSL doesn't try to
# exec Windows binaries by mistake:
export PATH=$(echo $PATH | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)
openlane --to Yosys.Synthesis config.json
# -> stops at Stage 5 (Generate JSON Header) with a yosys assertion
# -> failure log: synth/openlane_run_top_small_FAILED.log
```

The failure is in yosys's AST passes downstream of the synlig
SystemVerilog frontend (memory-array flop-promotion / signed-bus
checks). The same RTL passes QuestaSim 2021.3_1 cleanly.

### Run 2 (the one that passed) -- leaf `mac_pe`

[`synth/config_mac_pe_leaf.json`](synth/config_mac_pe_leaf.json) targets
the self-contained `synth_top.sv` (inlined `mac_pe`, no package import).
To reproduce:

```sh
cd project/m3/synth
openlane --pdk-root ~/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af \
    config_mac_pe_leaf.json
# -> writes runs/RUN_<timestamp>/{flow.log, final/, ...} -- all 73 steps,
#    ~30 min on a 16 GB WSL2 host
```

Outputs of this run (the M3 OpenLane evidence): `openlane_run.log`,
`timing_report.txt`, `area_report.txt`, `power_report.txt`,
`critical_path.md`.

### Why this combination satisfies the spec

The M3 deliverable checklist accepts "documented synthesis failure with
revised scope" or "documented scope adjustment with synthesis attempt
that justifies it." Run 1 IS the documented failure (real attempt, real
error, scope explicitly designed to fit the tool ceiling at 1 lane x
4 x 4); Run 2 IS the passing synthesis result on the dominant leaf cell
that the chip is built from. The Genus per-block sweep in
[`project/RTL/`](../RTL/) plus
[`project/RTL/chip_area_rollup.md`](../RTL/chip_area_rollup.md) supply
the chip-scale numbers that the integrated-build OpenLane would have
provided if it had completed.

## Cross-references

- [`project/m3_plan.md`](../m3_plan.md) -- working M3 project plan
- [`project/RTL/chip_area_rollup.md`](../RTL/chip_area_rollup.md) -- chip-scale projection
- [`project/RTL/timing_analysis.md`](../RTL/timing_analysis.md) -- Phase 1 timing sweep
- [`project/RTL/Planned_M4_Update.md`](../RTL/Planned_M4_Update.md) -- softmax LUT M4 plan
- [`codefest/cf07/synth/synth_interpretation.md`](../../codefest/cf07/synth/synth_interpretation.md) -- original cf07 analysis (the OpenLane run committed in `synth/` here is from cf07)

## Filename deviations

None. Every file path in [`synth/`](synth/), [`rtl/`](rtl/),
[`tb/`](tb/), and [`sim/`](sim/) matches the M3 deliverable checklist
character for character.
