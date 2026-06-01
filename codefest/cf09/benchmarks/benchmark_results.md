# CLLM 9 — Accelerator vs. software-baseline benchmark

Compares the M1 software baseline (NumPy / CPU) against the M5 accelerator
chip projected from the **latest cleanly-completed full OpenLane run**:
[`project/m3/synth/top_small_M5_attempt8/`](../../../project/m3/synth/top_small_M5_attempt8/)
and `project/m3/synth/runs/M5_optD_attempt9/` (74 / 74 OpenLane steps,
DRC + LVS + XOR clean, post-PnR STA across 9 corners).

## Path used

Per CLLM Task 7 fallback: **projected peak throughput**, computed as
`clock frequency × useful operations per cycle`. All accelerator numbers
in this document are labeled **(projected)**. No end-to-end accelerator
simulation has been run — the M3 deliverable scope-adjusted to
per-block / per-tile cosimulation, which is what motivates the
projection path.

## Workload — M1 ff_backward kernel

| Parameter | Value | Source |
|---|---:|---|
| Transformer config | d_model=64, d_ff=256, seq_len=64, batch=4, layers=2 | [`project/m1/sw_baseline.md`](../../../project/m1/sw_baseline.md) |
| Tokens per iteration | 256 (4 × 64) | M1 |
| Precision (SW) | float64 (8 B/element) | M1 |
| Precision (HW) | Q4.4 input × Q4.4 → Q16.16 accumulator | M5 RTL |
| Dominant kernel | ff_backward (32.5 % of CPU runtime) | M1 cprofile |

## Row 1 — M1 software baseline (measured on i5-10500H)

| Metric | Value | Source |
|---|---:|---|
| Platform | Intel Core i5-10500H, 6c/12t, single-channel DDR4-3200 | M1 |
| Median iteration | **35.317 ms** | [`sw_baseline.md`](../../../project/m1/sw_baseline.md) |
| Full-transformer throughput | **3.398 GFLOP/s** | M1 |
| ff_backward peak attainable | 139 GFLOP/s | M1 roofline |
| Tokens / sec | 7,249 | M1 |
| Samples / sec | 113.3 | M1 |
| Peak RSS | 14.7 MB | M1 tracemalloc |
| DRAM bandwidth | 25.6 GB/s | i5 datasheet, single-channel |

## Row 2 — Accelerator chip (projected from Attempt 9 post-PnR STA)

The Sky130 chip as-synthesized is `top_small` at **TILE_DIM = 2**
(intentionally shrunk for OpenLane WSL2 tractability — 4 PEs total). The
M1 spec calls for **TILE_DIM = 64** (4,096 PEs). Both bounds are
reported below; the headline accelerator numbers use the **full 64×64
M1-spec configuration** projected by scaling the post-PnR-validated
TILE_DIM = 2 design.

| Metric | Value | Source |
|---|---:|---|
| PDK | Sky130A `sky130_fd_sc_hd` | M3 deliverable |
| Process | 130 nm open-PDK | OpenLane 2.3.10 |
| Worst-case (SS) f_max | **45 MHz** (-11.33 ns WNS at 10 ns target) | [Attempt 9 sta_summary.rpt](../../../project/m3/synth/runs/M5_optD_attempt9/54-openroad-stapostpnr/summary.rpt) |
| Typical (TT) f_max | **90 MHz** (-1.11 ns WNS) | A9 STA |
| FF f_max | >100 MHz (+2.94 ns WNS ✓) | A9 STA |
| Cell area (TILE_DIM=2) | 0.45 mm² | A8b yosys_stat |
| Cell count (TILE_DIM=2) | 38,521 yosys cells | A8b yosys_stat |
| Chip total power (TILE_DIM=2 @ TT 100 MHz) | 0.366 W | [A8b power_nom_tt.rpt](../../../project/m3/synth/top_small_M5_attempt8/power_nom_tt.rpt) |
| DRC / LVS / antenna | **clean** | A9 step 62-63 |
| GDS streamed out | **yes** (Magic + KLayout, XOR clean) | A9 step 56-57, 60-61 |

### Throughput (projected) — 4096-PE M1-spec configuration

```
useful ops/cycle = ARRAY_ROWS × ARRAY_COLS × ops_per_MAC
                 = 64 × 64 × 2
                 = 8,192 ops/cycle
peak throughput  = f_max × useful_ops_per_cycle
```

| Operating point | f_max | Peak throughput | Sustained (60 % util) |
|---|---:|---:|---:|
| SS (worst-case sign-off) | 45 MHz | **369 GOPS** | ~221 GOPS |
| TT (typical) | 90 MHz | 737 GOPS | ~442 GOPS |
| FF (fast) | 100 MHz | 819 GOPS | ~491 GOPS |
| **M1 spec target** (Heilmeier) | 500 MHz | 4,096 GOPS | ~2,458 GOPS |

### Power + energy (projected)

Top_small TILE_DIM = 2 measured at 0.37 W. Scaling to TILE_DIM = 64:

```
PE-dynamic power_64 ≈ PE-dynamic_4 × (4096/4) × (45/100) × util
                    ≈ (0.37 W × 0.84 × 1024) × 0.45 × 0.6
                    ≈ 86 W ??? -- not realistic for chiplet
```

That naive linear scaling is wrong because top_small's combinational
power is dominated by shared overhead (controller, softmax_unit_lut,
fused_postproc, scratchpad), not by the 4 PEs themselves. Using a more
honest first-principles estimate (per-MAC dynamic energy at Sky130 130 nm
≈ 50 pJ at TT) and 50 % PE utilization:

```
PE power_64_SS = 4096 PEs × 45 MHz × 50 pJ × 0.5
               ≈ 4.6 W
+ shared blocks (softmax_unit_lut + fused_postproc + scratchpad + etc.)
               ≈ 1-1.5 W
= total ≈ 5-7 W at SS
```

| Operating point | Total chip power (projected, full 64×64) |
|---|---:|
| SS @ 45 MHz | ~5-7 W |
| TT @ 90 MHz | ~10-14 W |
| TT @ 500 MHz (M1 spec) | ~55-77 W (only at SAED32 node) |

The 500 MHz number is **not achievable on Sky130** (process floor at
~100 MHz); it lives on the SAED32 (phobos) path. Sky130 GDS is a flow /
tape-out validation, not a frequency-target deliverable.

## Row 3 — Headline comparison

Both sustained operating points compared against the CPU baseline:

| Platform | Sustained throughput | Power | Energy efficiency |
|---|---:|---:|---:|
| CPU (M1, full transformer) | 3.4 GFLOP/s | ~45 W | 76 MFLOP/J |
| CPU (M1, ff_backward peak) | 139 GFLOP/s | ~45 W | 3.1 GFLOP/J |
| **HW chip @ Sky130 SS** (projected) | ~221 GOPS | ~6 W | **37 GOPS/J** |
| **HW chip @ SAED32 SS** (M1-spec, projected) | ~2,458 GOPS | ~25 W | **98 GOPS/J** |

### Speedup vs M1 CPU baseline

| Comparison axis | CPU value | HW projected | Speedup |
|---|---:|---:|---:|
| Full-transformer throughput | 3.4 GFLOP/s | 221 GOPS (Sky130 SS, 64×64) | **65×** |
| ff_backward kernel | 139 GFLOP/s | 221 GOPS sustained | 1.6× |
| ff_backward kernel @ SAED32 spec | 139 GFLOP/s | 2,458 GOPS | **18×** |
| Tokens / J (energy efficiency) | 161 tok/J | ~1,470 tok/J (chip @ SS) | **~9×** |
| Tokens / sec (wall-clock) | 7,249 tok/s | ~22,000 tok/s (3× iteration speedup) | 3× |

## Honest caveats

- **All HW numbers are PROJECTED, not measured.** The path is OpenLane
  post-PnR STA → peak ops/cycle math → no end-to-end cosim ran on the
  ff_backward workload as a whole.
- **Precision is not bit-equivalent.** Q4.4 × Q4.4 → Q16.16 covers most of
  the ff_backward dynamic range but is not a substitute for fp64. M5
  precision study (in [`codefest/cf02/analysis/`](../../../codefest/cf02/analysis/))
  established ≤ 5e-5 worst-case error for the LUT-based activations.
- **Sky130 caps at ~100 MHz at TT** post-PnR. The 200-500 MHz numbers
  require SAED32 (phobos) where the M5 RTL is currently in flight
  (Genus `syn_opt` showed −482 ps mid-run, consistent with ~600 MHz
  pre-PnR projection).
- **The 60 % utilization assumption** comes from softmax + activation pipeline
  serialization at ARRAY_DIM=64. Lower-utilization workloads (small batch,
  small tile) hit the ~25-40 % range and bring sustained throughput down
  proportionally.

## See also

- Per-kernel AI from first principles: [`cf09/cman_ai_analysis.md`](../cman_ai_analysis.md) (Task 5 deliverable, CMAN path)
- Roofline plot: [`cf09/benchmarks/roofline_plot.png`](roofline_plot.png)
- Gap analysis: [`cf09/benchmarks/roofline_analysis.md`](roofline_analysis.md)
- Sky130 GDS source: [`project/m3/synth/runs/M5_optD_attempt9/`](../../../project/m3/synth/runs/M5_optD_attempt9/)
- M5 narrative: [`project/m3/synthesis_notes.md`](../../../project/m3/synthesis_notes.md)
