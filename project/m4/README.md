# M4 — Final Deliverable Package

ECE 410/510 Spring 2026, project: **mixed-precision (Q4.4 × Q4.4 → Q16.16) transformer FFN accelerator chiplet** with a 64×64 output-stationary systolic array, on-chip activation LUTs (GELU / GELU′), softmax, and a UCIe-style host interface.

This folder is the M4 deliverable per the milestone checklist (Rev. 1, 2026-05-20). The package is a synthesizable, verified, benchmarked accelerator with a 9-section design justification report.

**Headline numbers.** Genus 21.12 close on SAED32 RVT, 2 ns clock (500 MHz), **0 violators, WNS +0.1 ps**. **Cell area 9.07 mm²** (2.37 M leaf cells, 596 k sequential). Power 2.347 W typ (vectorless, `tt0p85v25c`). **Verification: 8/8 testbench PASS** through QuestaSim 2021.3_1 on phobos; 4 RTL bugs found and fixed during the campaign. **Architectural peak compute 4.096 TFLOP/s; measured single-tile FFN_BWD 8.07 GFLOP/s** (fill/drain-bound on a 64×64×64 tile). Speedup vs M1 software baseline: **2.4× sustained-on-tile, 29.5× peak-vs-CPU-attainable**.

## File catalog

| Path | Description | Supports |
|---|---|---|
| [README.md](README.md) | this file | item 1 (M4 folder README) |
| **rtl/** | **complete verified source tree** — 50 SystemVerilog files + 8 `.mem` LUT contents. Every `.sv` is byte-identical to its source under [`project/RTL/`](../RTL/), [`project/m2/rtl/`](../m2/rtl/), or [`project/m3/rtl/`](../m3/rtl/), and is the exact version compiled by `sim/run_verification.sh` to produce the 8/8 PASS result. | item 2 (Source code) |
| [rtl/top.sv](rtl/top.sv) | M3 integration wrapper — UCIe interface + 16-lane compute_core | §4 Dataflow and architecture |
| [rtl/compute_core.sv](rtl/compute_core.sv) | 16-lane compute_core (M2 wrapper — interfaces match latest sub-RTL) | §4 |
| [rtl/interface.sv](rtl/interface.sv) | UCIe-style chiplet interface (M2 wrapper) | §5 Hardware interface |
| [rtl/accel_pkg.sv](rtl/accel_pkg.sv) | shared package — `MODE_FFN_FWD/BWD/ATTN_FWD/BWD` enum, `macro_cmd_t`, `q_mul`/`q_add_sat` arithmetic helpers, parameter defaults | §3, §4 |
| `rtl/{accel_top,accel_engine,accel_chiplet_wrapper}.sv` | per-lane and chiplet-wrapper RTL underneath `compute_core` | §4 |
| `rtl/{accel_controller,tile_dispatcher,tile_scheduler,mode_decoder}.sv` | control plane — macro FSM, tile dispatch, mode decode | §4 |
| `rtl/{systolic_array_64x64,mac_pe,mac_pe_piped,mac_pe_piped4,adder_tree}.sv` | 64×64 output-stationary systolic + per-PE MACs + reduction tree | §4 |
| `rtl/{stream_pipeline,fused_postproc_unit,pipeline_stage,skid_buffer,stream_mux}.sv` | streaming postproc pipeline + flow-control primitives | §4 |
| `rtl/{gelu_unit,gelu_unit_lut,gelu_grad_unit,gelu_grad_unit_lut,gelu_lut,gelu_direct_lut,gelu_grad_direct_lut,exp_lut}.sv` | activation units (LUT-based GELU/GELU′) + their backing ROMs | §3 |
| `rtl/{softmax_unit,softmax_unit_lut,divider_or_reciprocal_unit,divider_or_reciprocal_seq,causal_mask_unit}.sv` | softmax + sequential reciprocal divider + attention causal mask | §3, §4 |
| `rtl/{scratchpad_ctrl,sram_bank,dma_engine,double_buffer_ctrl,tile_loader,tile_writer,tile_buffer,address_gen}.sv` | memory subsystem — scratchpad, DMA, tile load/store | §4 |
| `rtl/{stream_if,sram_if,cmd_if,tile_if,ctrl_if,status_if}.sv` | SystemVerilog interfaces used by the modules above | §4 |
| `rtl/{csr_block,perf_counter_block}.sv` | CSR block + performance counters (for host visibility) | §4 |
| `rtl/{exp_lut,gelu_lut_direct,gelu_grad_lut_direct,gelu_tanh_lut}.mem` (+ `_64`/`_128` variants) | LUT ROM contents loaded by `$readmemh` at simulation time and at synthesis-elaboration | §3 |
| **rtl/openlane_verilog_handflattened_rtl/** | 45 hand-flattened Verilog-2005 files (+ 4 `.mem`) — the **OpenLane Sky130 synthesis source set** referenced by `synth/config.json` via `dir::v_hand/*.v`. Functionally equivalent to the SystemVerilog set in `rtl/`, with all four M4 verified RTL fixes back-ported in. Hand-flattened because Yosys' SV frontend OOM'd on the SV set; this `.v` set parses natively. | §7, item 3 (OpenLane source) |
| **tb/** | final testbenches — the eight-TB suite referenced from report §6, byte-identical to [`project/m3/tb/`](../m3/tb/) | item 2 |
| [tb/tb_fused_postproc_unit.sv](tb/tb_fused_postproc_unit.sv) | leaf — `dh = dy · GELU′(h_pre)` post-processor vs FP32 golden | §6 |
| [tb/tb_gelu_unit_lut.sv](tb/tb_gelu_unit_lut.sv) | leaf — 256-entry LUT GELU vs FP32 golden | §6 |
| [tb/tb_gelu_grad_unit_lut.sv](tb/tb_gelu_grad_unit_lut.sv) | leaf — 256-entry LUT GELU′ vs FP32 golden | §6 |
| [tb/tb_softmax_unit_lut.sv](tb/tb_softmax_unit_lut.sv) | leaf — sequential softmax (exp LUT + reciprocal) vs FP32 golden | §6 |
| [tb/tb_stream_pipeline_tile.sv](tb/tb_stream_pipeline_tile.sv) | subsystem — matmul → GELU → softmax tile-stream pipeline | §6 |
| [tb/tb_compute_core.sv](tb/tb_compute_core.sv) | chip — FFN_FWD, FFN_BWD, back-to-back FWD↔BWD, FFN_BWD @ h=2.0 (4 scenarios) | §6 |
| [tb/tb_top.sv](tb/tb_top.sv) | chip — end-to-end UCIe-side cosim driving one 64×64 FFN forward macro | §6, §8 Benchmark |
| [tb/tb_ff_backward_e2e.sv](tb/tb_ff_backward_e2e.sv) | chip — UCIe-side host drives four FFN backward macros (h = 1, 2, −1, 0); source of the 32,989 cycle/macro measurement | §6, §8 |
| **sim/** | final simulation outputs | item 2 |
| [sim/final_run.log](sim/final_run.log) | verification summary — `Total: 8 Pass: 8 Fail: 0`, `=== VERIFICATION: PASS ===` | §6 |
| [sim/final_waveform.png](sim/final_waveform.png) | end-to-end UCIe transaction waveform | §6 (Figure 2 in report) |
| [sim/run_verification.sh](sim/run_verification.sh) | master test runner — compiles all RTL, runs all 8 TBs, emits summary | §6 (reproducibility) |
| [sim/run_top.do](sim/run_top.do) | QuestaSim driver script for `tb_top` — single-TB cosim invocation | §6 |
| [sim/wave.do](sim/wave.do) | QuestaSim wave-window setup (UCIe link + interface/core boundary + lane-0 internals) | §6 |
| [sim/cosim_waveform.do](sim/cosim_waveform.do) | wave export script that produces `final_waveform.png` from a vsim run | §6 (Figure 2) |
| [sim/make_cosim_artifacts.sh](sim/make_cosim_artifacts.sh) | the recipe that produced `final_run.log` + `final_waveform.png` end-to-end | §6 (reproducibility) |
| **synth/** | final synthesis results — three tracks committed: **Genus SAED32 front-end (headline)**, **Innovus SAED32 PnR (incomplete — CTS failed)**, **OpenLane Sky130 PnR (scoped-down portability run)** | item 3 (Synthesis results) |
| [synth/config.json](synth/config.json) | OpenLane 2.3.10 Sky130 config (scoped-down `top_small`, TILE_DIM=2, N_LANES=1). The headline 64×64 numbers come from the Genus SAED32 run, not this config. | item 3 (OpenLane config) |
| [synth/openlane_run.log](synth/openlane_run.log) | OpenLane stdout/stderr (head+tail) — Sky130 scoped-down `top_small` build, included for tool-portability demonstration | item 3 (OpenLane log) |
| [synth/timing_report.txt](synth/timing_report.txt) | **Headline timing** — Genus SAED32, closes at 2 ns / 500 MHz, 0 violators (full 64×64 / 16-lane design) | §7, item 3 (timing) |
| [synth/area_report.txt](synth/area_report.txt) | **Headline area** — Genus SAED32 hierarchical, 9.07 mm² total, systolic 8.51 mm² (93.8 %) | §7, item 3 (area) |
| [synth/power_report.txt](synth/power_report.txt) | **Headline power** — Genus vectorless, 2.347 W, register-dominated (69.4 %) | §7, item 3 (power) |
| [synth/qor_report.txt](synth/qor_report.txt) | Genus QoR summary — leaf 2.37 M cells, seq 596 k, comb 1.78 M, WNS +0.1 ps, TNS 0 | §7 |
| [synth/run_phobos_hier.sh](synth/run_phobos_hier.sh) | phobos wrapper — runs Genus hier synth + Innovus PnR + multi-corner STA. Invokes the three `.do` scripts below. | §7, §9 |
| [synth/run_genus_hier.do](synth/run_genus_hier.do) | Cadence Genus 21.12 hierarchical synthesis recipe — **this script produced the headline 2 ns close, 9.07 mm² area, and 2.347 W power numbers**. SAED32 RVT, `tt0p85v25c`, balanced-tree wireload. | §7 (Genus headline) |
| [synth/run_innovus_hier.do](synth/run_innovus_hier.do) | Cadence Innovus 21.14 PnR recipe — CTS step did not close (see §9). Post-place reports under `synth/innovus/` were produced by this script before the CTS failure. | §9 |
| [synth/run_sta_mc.do](synth/run_sta_mc.do) | Cadence Innovus multi-corner STA recipe — invoked as Phase 5 of `run_phobos_hier.sh`. | §7 |
| [synth/run_openlane_clean.sh](synth/run_openlane_clean.sh) | OpenLane Sky130 launch script — invokes the Nix-installed openlane CLI with `config.json` + the `v_hand/` source set | §7 (Sky130 reproducibility) |
| **synth/genus/** | full Genus 21.12 SAED32 RVT reports — the **source of the headline numbers** at `synth/{timing,area,power}_report.txt` | §7 |
| `synth/genus/{area,area_hier,gates,hierarchy,messages,power,qor,timing,timing_reg2reg}.rpt`, `synth/genus/genus_run.log` | per-report Genus output + full run log (`run_genus_hier.do`) | §7 |
| **synth/innovus/** | full Cadence Innovus 21.14 PnR reports — **CTS step did not close**; post-place + post-route reports kept as evidence (post-CTS / post-route timing reports are empty because CTS dropped the constraint, see §9) | §9 |
| `synth/innovus/{area_floorplan,area_post_place,area_post_route,clock_tree,connectivity,power_post_route,timing_post_cts,timing_post_place,timing_post_route}.rpt`, `synth/innovus/innovus_run.log` | per-stage Innovus output + full run log (`run_innovus_hier.do`) | §9 |
| **synth/openlane/** | full Sky130 OpenLane 2.3.10 PnR output for the scoped-down `top_small` (2×2 systolic, 1 lane) — closes clean: DRC/LVS/XOR 0 errors, nom_tt +0.98 ns slack at 10 ns | §7 (Sky130 portability) |
| [synth/openlane/summary.md](synth/openlane/summary.md) | one-page Sky130 summary — comparison to prior Attempt 7 / 8b to confirm the M4 verified RTL fixes don't regress PnR | §7 |
| `synth/openlane/{metrics.csv,metrics.json}` | OpenLane final-summary metrics across all 9 PVT corners | §7 |
| `synth/openlane/sta_nom_tt_025C_1v80/` (+ `sta_nom_ss_*`, `sta_nom_ff_*`) | post-PnR STA reports per corner — `wns`, `tns`, `clock`, `power`, `skew`, `violator_list`, etc. nom_tt closes; nom_ss has 53 setup violators (typical for unconstrained OpenLane slow-corner) | §7 |
| `synth/openlane/{irdrop_nom_tt.rpt,yosys_stat.rpt}` | IR drop (0.61 % max) + Yosys front-end synthesis stats | §7 |
| **bench/** | hardware-vs-SW benchmark | item 4 (Benchmark) |
| [bench/benchmark.md](bench/benchmark.md) | measured throughput, energy, speedup vs M1 baseline | item 4 (throughput, speedup, energy) |
| [bench/benchmark_data.csv](bench/benchmark_data.csv) | raw values backing every number in benchmark.md | item 4 (raw data) |
| [bench/roofline_final.png](bench/roofline_final.png) | roofline plot — CPU + M4-ext + M4-SRAM ceilings, M1 + M4 measured points | item 4 (roofline), §2 / §8 in report (Figure 1) |
| [bench/roofline_final.py](bench/roofline_final.py) | reproduces the roofline plot | item 4 (reproducibility) |
| **report/** | design justification | item 5 (Report) |
| [report/design_justification.pdf](report/design_justification.pdf) | 9-section, ~3,700-word PDF (3,319 words text + figures) | item 5 (PDF) |
| [report/design_justification.md](report/design_justification.md) | markdown source of the report | item 5 (source) |
| [report/build_pdf.py](report/build_pdf.py) | regenerates `design_justification.pdf` from the markdown + figures | item 5 (reproducibility) |
| [report/figures/fig1_roofline.png](report/figures/fig1_roofline.png) | copy of `bench/roofline_final.png` for in-PDF embedding | §2, §8 |
| [report/figures/fig2_waveform.png](report/figures/fig2_waveform.png) | copy of `sim/final_waveform.png` for in-PDF embedding | §6 |
| [report/figures/fig3_blockdiagram.png](report/figures/fig3_blockdiagram.png) | M4 chiplet block diagram (host → interface → compute_core → systolic) | §4 |
| [report/figures/fig4_dataflow.png](report/figures/fig4_dataflow.png) | output-stationary systolic dataflow (A west, B north, output south) | §4 |
| [report/figures/make_blockdiagram.py](report/figures/make_blockdiagram.py) | regenerates fig3 + fig4 | reproducibility |

## Diff vs M3

| Area | What changed M3 → M4 |
|---|---|
| RTL | The full verified source tree (50 `.sv` + 8 `.mem` files) is staged in [`rtl/`](rtl/) — every file byte-identical to its source under `project/RTL/`, `project/m2/rtl/`, or `project/m3/rtl/`. The top-of-stack wrappers (`top.sv`, `compute_core.sv`, `interface.sv`) are unchanged since M3 / M2. The sub-modules at `project/RTL/` received four M4 verification fixes — `199c40d` (accel_controller width), `b2354fe` (mac_pe_piped4 forwarding bypass), `f7e8605` (fused_postproc GRAD_DELAY), `dbdab93` (softmax + stream_pipeline backpressure handshake). Wrapper interfaces did not change so the M4 stack is plug-compatible. |
| TB | M3 had one testbench (`tb_top`). M4 has the full 8-TB suite (`run_verification.sh`), 4 of which are new for M4 (`tb_fused_postproc_unit`, `tb_gelu_grad_unit_lut`, `tb_stream_pipeline_tile`, `tb_ff_backward_e2e`). |
| Sim | M3 produced `cosim_run.log` for one TB. M4 produces `final_run.log` with the 8/8 PASS summary and the same waveform extended to cover the integrated FFN_BWD path. |
| Synth | M3 closed timing only on the leaf `mac_pe` (Sky130). M4 closes the **full 64×64 / 16-lane chip** on SAED32 via Genus at 2 ns (0 violators), drives the same RTL through Innovus PnR (post-place + post-route reports committed; CTS step did not close — see §9), and drives the hand-flattened Verilog through Sky130 OpenLane (scoped-down 2×2, clean GDS at nom_tt). All three tracks are committed under `synth/{genus,innovus,openlane}/`. |
| Bench | M3 had no benchmark. M4 has `benchmark.md` + `benchmark_data.csv` + `roofline_final.png` with measured cycle counts and a speedup table. |
| Report | New for M4. |

## Source-tree mapping (where each RTL file came from)

Every `.sv` and `.mem` in [`rtl/`](rtl/) was copied byte-identical from one of three locations, all in this repo. A diff of every file against its source is part of M4 staging; nothing in `rtl/` is divergent from the verified tree.

| File group in `rtl/` | Source | What it is |
|---|---|---|
| 47 `.sv` files: `accel_*`, `mac_pe*`, `systolic_array_64x64`, `adder_tree`, `gelu_*`, `softmax_*`, `causal_mask_unit`, `divider_or_reciprocal_*`, `fused_postproc_unit`, `tile_buffer`, `pipeline_stage`, `skid_buffer`, `stream_mux`, `tile_loader/writer/scheduler/dispatcher`, `sram_bank`, `scratchpad_ctrl`, `address_gen`, `dma_engine`, `double_buffer_ctrl`, `stream_pipeline`, `mode_decoder`, `perf_counter_block`, `csr_block`, `*_if.sv` interfaces | [`project/RTL/`](../RTL/) | Canonical verified RTL tree with the four M4 fixes (`199c40d`, `b2354fe`, `f7e8605`, `dbdab93`) and all M5/M6 pipelining changes. This is the tree Genus 21.12 synthesized for the SAED32 close. |
| `rtl/compute_core.sv`, `rtl/interface.sv` | [`project/m2/rtl/`](../m2/rtl/) | M2 wrappers — unchanged since M2 because their port interfaces still match the latest sub-module versions in `project/RTL/`. |
| `rtl/top.sv` | [`project/m3/rtl/`](../m3/rtl/) | M3 integration wrapper — instantiates `interface` + `compute_core` with no glue. |
| 8 `.mem` files | [`project/RTL/`](../RTL/) | LUT ROM contents (`exp`, `gelu`, `gelu_grad`, `tanh`) loaded by `$readmemh` at simulation and synthesis. |

The canonical reproduction is [`sim/run_verification.sh`](sim/run_verification.sh), which compiles this exact file set and runs the eight-testbench suite to produce [`sim/final_run.log`](sim/final_run.log) (8/8 PASS).

## Reproduce

### Functional verification (Phobos, QuestaSim 2021.3_1)

```sh
cd project/m3/sim
./run_verification.sh
# expect: "Total: 8   Pass: 8   Fail: 0"
# expect: "=== VERIFICATION: PASS (all 8 testbenches passed) ==="
```

### Roofline plot

```sh
cd project/m4/bench
python roofline_final.py
# writes roofline_final.png
```

### Design justification PDF

```sh
cd project/m4/report
python build_pdf.py
# writes design_justification.pdf
```

### Synthesis (Phobos, Genus 21.12 on SAED32)

The full closing run is at [`project/RTL/run_genus_hier.do`](../RTL/run_genus_hier.do). Reports land under `project/RTL/out_sweep/stream_pipeline_64x64_hier/reports/`. The four reports under `synth/` (timing / area / power / qor) are copies from there.

### Synthesis (Sky130 OpenLane)

```sh
cd project/m3/synth
./run_openlane_clean.sh
# uses config_top_small_v_hand.json and the v_hand/*.v file set
# Sky130 PDK + sky130_fd_sc_hd
```

The Sky130 run is included for technology portability per the M4 checklist; the closed-timing headline numbers are from the SAED32 Genus run.

## Caveats and known limitations

These are also called out in §9 of `report/design_justification.pdf`.

1. **Closed timing is at the synthesis stage, not post-PnR.** The phobos Innovus PnR did not close (CTS step produced empty constrained-paths reports — see `What did not work` in §9). The 500 MHz / 2 ns close is the Genus front-end result on the full-scale design.
2. **Power is vectorless.** Genus uses a uniform 0.2 activity factor. Activity-aware power (with a SAIF generated from `tb_ff_backward_e2e`) would be lower; the 2.347 W headline is a conservative bound.
3. **Sky130 OpenLane GDS is for the scoped-down `top_small.v`** (TILE_DIM=2 → 2×2 systolic, N_LANES=1), not the full 64×64 / 16-lane design. The Sky130 run exists to demonstrate open-source flow portability; the headline 9.07 mm² / 2.35 W numbers are from the **Genus SAED32** synthesis on the full 64×64 / 4,096-PE design.
4. **The roofline M4 measured point (8.07 GFLOP/s)** is a single-tile FFN_BWD measurement; it is fill/drain-bound, not compute-bound. The architectural peak of 4.096 TFLOP/s is reachable on multi-tile macros (which the architecture supports but the verified end-to-end testbenches do not exercise).
