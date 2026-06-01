# Remaining tasks before M4

Three concrete (non-generic) RTL / verification / synth tasks gating the
M4 milestone. Ordered by leverage — task 1 unlocks the headline accelerator
throughput measurement (currently PROJECTED), task 2 closes the Sky130
critical path identified from Attempt 9 post-PnR STA, task 3 closes the
phobos SAED32 frequency story.

## 1. End-to-end ff_backward cosimulation against the M5 RTL

**What:** Run the QuestaSim regression at
[`project/RTL/run.do`](RTL/run.do) extended with a new
`tb_ff_backward_tile.sv` that drives an h × W = 64 × 256 backward GEMM tile
through `chiplet_interface` → `accel_top` → `compute_core` →
`stream_pipeline` and captures the wall-clock cycle count. This converts
the **PROJECTED** 221 GOPS sustained number in
[`codefest/cf09/benchmarks/benchmark_results.md`](../codefest/cf09/benchmarks/benchmark_results.md)
to a measurement.

**Why specific:** The current top-level TB ([`project/m3/tb/tb_top.sv`](m3/tb/tb_top.sv))
drives a 64 × 64 FFN *forward* tile only. The backward path uses
`gelu_grad_unit_lut` + `data_delay` alignment which has the +2-cycle
latency change from M6 Tier 2 — that change is unverified end-to-end.

**Acceptance:** `tb_ff_backward_tile.sv` produces `=== PASS ===` in
`run.do` transcript with measured cycle count within ±10 % of the
projected 221 GOPS at TILE_DIM=64.

**Estimated effort:** 4-6 hours RTL plumbing + 1 hour QuestaSim run.

## 2. Pipeline the `divider_or_reciprocal_seq` 33-bit compare-subtract loop

**What:** Split the iterative divider's inner combinational chain
`R_shifted = {R[31:0], U[47]}; if (R_shifted >= {1'b0, V}) ...` (at
[`project/RTL/divider_or_reciprocal_seq.sv:120-127`](RTL/divider_or_reciprocal_seq.sv))
into two pipeline cycles: compute and register the 33-bit compare result
in cycle K, do the conditional subtract + shift in cycle K+1. Pushes the
divider's per-iteration latency from 1 cycle to 2 cycles (N_ITER becomes
96 effective), but per-cycle critical path drops from ~3.5 ns at Sky130
SS to ~1.7 ns.

**Why specific:** Attempt 9 post-PnR critical-path analysis ranked
`softmax_unit_lut.u_recip.V[1]` as the divider-internal critical-path
contributor with 17 paths > 5 ns at SS. The M5 iterative divider's
inner compare-and-subtract has 5 + 5 gate-levels of CLA depth in series.
Splitting them at the compare boundary cuts the per-cycle critical path
roughly in half.

**Acceptance:** `tb_divider_or_reciprocal_seq` in
[`project/RTL/run.do`](RTL/run.do) still produces bit-exact match across
the 16-vector regression; post-PnR STA at Sky130 SS shows
`softmax_unit_lut.u_recip` cluster drops from 17 paths > 5 ns to 0.

**Estimated effort:** 2-3 hours RTL edit + hand-flatten + 30 min cosim.

## 3. Complete phobos SAED32 Innovus PnR + multi-corner STA from current Genus netlist

**What:** Once the in-progress phobos Genus run on `stream_pipeline_64x64_hier`
finishes (currently in `syn_opt` at −482 ps WNS), launch phases 4 + 5 of
[`project/RTL/run_phobos_hier.sh`](RTL/run_phobos_hier.sh):

```sh
./run_phobos_hier.sh phase4   # ~3-4 hr Innovus PnR
./run_phobos_hier.sh phase5   # ~20 min multi-corner STA
```

This produces the SAED32 GDS + DEF + SPEF + per-corner sign-off STA
that lets us replace the **PROJECTED** 4,096 GOPS peak number with a
real number at the M1 Heilmeier 500 MHz target.

**Why specific:** The current accelerator headline in
[`codefest/cf09/benchmarks/benchmark_results.md`](../codefest/cf09/benchmarks/benchmark_results.md)
shows Sky130 SS (45 MHz, 369 GOPS) as the only post-PnR-validated point.
The 500 MHz SAED32 number is a Heilmeier projection. Phase 4 + 5 convert
that projection into a measurement and unlocks the headline
"closes M1 500 MHz target at sign-off" claim if SAED32 SS lands above
500 MHz post-PnR (mid-flow Genus WNS is consistent with that).

**Acceptance:** [`out_innovus/stream_pipeline_64x64_hier/sta/mc_summary.rpt`](RTL/out_innovus/stream_pipeline_64x64_hier/sta/mc_summary.rpt)
shows SS-corner setup WNS ≥ 0 ns at 2 ns clock target (500 MHz) and
per-corner power within 25 W TDP.

**Estimated effort:** Phobos compute time only (~4 hr); no engineering
work beyond `git pull` once the M6 changes land on phobos.

## Out of scope for M4

The following are *not* gating M4 and stay deferred:
- Mac_pe Stage 1 (multiplier) internal pipeline split — only matters past 600 MHz at SAED32 SS; current SAED32 trajectory closes 500 MHz without it.
- Accel_engine controller pipeline registers — Sky130 dominant path but
  process-bound; SAED32 expected to crush these via Genus's parallel-prefix
  adder picking + better wire scaling.
- Direct end-to-end on-FPGA validation — requires UCIe PHY which isn't
  part of the M1-M5 scope (the chip is a chiplet front-end only).
