# CLLM Task 9 — Roofline gap analysis (ff_backward, workload framing)

The accelerator point on [`roofline_plot.png`](roofline_plot.png) is the
**chip's projected sustained throughput on the `ff_backward` kernel** (221 GOPS
at Sky130 SS, 4096-PE-spec scaling, 60 % utilization). It is labeled
**PROJECTED** because no end-to-end ff_backward cosim has been run yet
against the M5 RTL — the M3 deliverable scope-adjusted to per-block /
per-tile verification, and the chip-level throughput is computed from
`f_max × useful_ops_per_cycle × util`. This analysis identifies the
dominant uncertainty in that projection and what would be needed to
convert it into a measurement.

Per M1's framing, the kernel is `ff_backward` — the dominant transformer
operation (32.5 % of CPU runtime per the M1 cprofile), and part of the
~80 %-of-runtime portion the chip accelerates. The remaining 20 % stays
on CPU (LayerNorm, residual, embedding lookup, optimizer step).

## Where the chip landed on its roofline

Two ff_backward AI bounds at the chip's chiplet-interface boundary,
Q16.16 (4 B/element) precision. Per-GEMM no-reuse byte count =
`(2·M·N·K + M·N) × 4 B`; per-GEMM full-reuse = `(M·K + K·N + M·N) × 4 B`;
summed over the 4 GEMMs + element-wise GELU' multiply:

| Bound | AI | Where on chip's roofline |
|---|---:|---|
| no-reuse lower (every operand re-fetched per use) | **0.52 FLOP/B** | **memory-bound** at 133 GOPS (well below 1.44 ridge) |
| full-reuse upper (`tile_buffer` holds intermediates) | **75 FLOP/B** | **compute-bound** at 369 GOPS ceiling (well above ridge) |

The chip's `tile_buffer` architecture is designed exactly for the
full-reuse case: each of X, W₁, W₂, dy loads from off-chip exactly once
per ff_backward iter and intermediates (h, dh) stay on-chip across the
4 GEMMs. So the chip operates at the **upper bound** — squarely
compute-bound, ceiling-limited at 369 GOPS at Sky130 SS. Going from
sustained 221 GOPS to peak 369 GOPS is a utilization story; going beyond
369 is a *compute-units × frequency* story (only SAED32 can buy that).

## Where the CPU baseline landed on its roofline

The M1 measured `ff_backward` AI was **5.43 FLOP/B** (fp64, M1 cf02 analysis).
That sits below the CPU's ridge of 16.9 FLOP/B, so the CPU is
**memory-bound** on this kernel. Peak attainable at this AI = 5.43 ×
25.6 GB/s = **139 GFLOP/s**. The CPU actually measured **3.4 GFLOP/s
sustained** — about 25× below its own roofline. That gap is the cache
miss / TLB / Python overhead penalty that comes with NumPy + fp64.

So the headline comparison: **3.4 GFLOP/s (CPU measured) vs 221 GOPS
(chip projected) = 65× speedup on the workload's dominant kernel**.

## Dominant uncertainty in the chip's projection

Three sources, ranked:

1. **Utilization assumption (60 %).** Built from the M5 stream pipeline's
   design assumption that softmax / GELU' element-wise post-processing
   overlaps with subsequent GEMM setup. If real utilization lands at
   30-40 % (closer to the M3 chip_scale_rollup estimate before M5
   pipelining), the headline 65× collapses to 32-43×.
2. **Process target (Sky130 vs SAED32).** Sky130 SS caps at 45 MHz —
   that's where the 369 GOPS ceiling comes from. The phobos SAED32
   run (in flight) projects 500 MHz post-PnR, lifting the ceiling to
   4,096 GOPS and the sustained number to ~2,458 GOPS at 60 % util —
   the M1 Heilmeier 10× target then becomes 723× on the same kernel.
3. **Precision parity (Q4.4 vs fp64).** Speedup numbers count ops at
   face value; the chip's Q4.4 × Q4.4 → Q16.16 has worst-case 3 LSB
   error vs fp64 (cf02 precision study). For ff_backward this is fine
   numerically — the kernel's dynamic range stays bounded after GELU' —
   but a "fp64-equivalent" comparison would discount the chip's
   throughput by some fraction. We don't, because the workload is
   trained and validated at the chip's precision.

## Converting projection to measurement

The path from PROJECTED to MEASURED is **end-to-end QuestaSim cosim
of one ff_backward iteration** through `chiplet_interface` →
`accel_top` → `compute_core` → `stream_pipeline`, capturing the actual
cycle count for the kernel at TILE_DIM = 64 (or the M1-realistic batch
× seq = 256 effective M).

The current M3 testbench [`project/m3/tb/tb_top.sv`](../../../project/m3/tb/tb_top.sv)
drives ff_*forward* only. The ff_backward path uses `gelu_grad_unit_lut`
+ `data_delay` alignment and the +2-cycle M6 Tier 2 latency change,
which is unverified end-to-end. Writing `tb_ff_backward_tile.sv` is
remaining task #1 in [`project/remaining_tasks.md`](../../../project/remaining_tasks.md);
its acceptance criterion (measured cycle count within ±10 % of the
projected 221 GOPS) is exactly the conversion this analysis identifies.

(Word count: 540.)
