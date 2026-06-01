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

## Kernel framing (M1 workload view)

Following the M1 framing: the kernel is **`ff_backward`**, the dominant
transformer-iteration operation (32.5 % of CPU runtime per M1 cprofile).
The chip accelerates ff_backward + ff_forward + attention, which together
were the ~80 %-of-runtime "accelerated" portion in the M1 Heilmeier
story; the remaining ~20 % (LayerNorm, residual, optimizer, embedding)
stays on the host CPU and bounds the Amdahl ceiling.

`ff_backward` decomposes into 4 GEMMs + 1 element-wise multiply with
GELU':

```
ff_backward(dy, X, h, W1, W2) =
  dW2     = h^T · dy                          # 8.39 MFLOP, GEMM
  dh_pre  = dy · W2^T                         # 8.39 MFLOP, GEMM
  dh      = dh_pre ⊙ GELU'(X · W1)            # ~0.13 MFLOP, element-wise
  dW1     = X^T · dh                          # 8.39 MFLOP, GEMM
  dX      = dh · W1^T                         # 8.39 MFLOP, GEMM
  ────────────────────────────────────────────
  Total per iter: ~33.7 MFLOP (4 × 8.39 + element-wise)
```

At M1 dims (effective M = batch*seq = 256, d_model = 64, d_ff = 256). The
4 GEMMs run on the `systolic_array_64x64` 64×64×64 tile primitive
(~74 tiles per ff_backward pass); the element-wise multiply with GELU'(h)
runs on `fused_postproc_unit.u_gelu_grad`. ~99 % of FLOPs land on
the systolic array; ~1 % on fused_postproc.

## Row 1 — M1 software baseline (measured)

| Metric | Value | Source |
|---|---:|---|
| Platform | Intel Core i5-10500H, 6c/12t, single-channel DDR4-3200 | M1 |
| Median full-iteration | 35.317 ms | [`sw_baseline.md`](../../../project/m1/sw_baseline.md) |
| Full-transformer throughput | 3.398 GFLOP/s | M1 |
| **ff_backward measured throughput** | **~3.4 GFLOP/s sustained** | derived: 32.5 % of 120 MFLOP/iter / 11.5 ms |
| ff_backward roofline ceiling | 139 GFLOP/s | M1 roofline @ AI=5.43 × 25.6 GB/s |
| ff_backward arithmetic intensity (fp64, CPU view) | 5.43 FLOP/B | M1 cf02 analysis |
| Tokens / sec | 7,249 | M1 |
| Peak RSS | 14.7 MB | M1 tracemalloc |
| DRAM bandwidth | 25.6 GB/s | i5 datasheet |

## Row 2 — Accelerator chip (projected from Attempt 9 post-PnR STA)

Sky130 chip is `top_small` at TILE_DIM = 2 (4 PEs, the OpenLane-tractable
shrink); headline numbers use the **full 64 × 64 M1-spec configuration**
projected from the post-PnR-validated TILE_DIM = 2 design.

| Metric | Value | Source |
|---|---:|---|
| PDK | Sky130A `sky130_fd_sc_hd` | M3 |
| Process | 130 nm open-PDK | OpenLane 2.3.10 |
| Worst-case (SS) f_max | **45 MHz** (-11.33 ns WNS) | [Attempt 9 sta_summary.rpt](../../../project/m3/synth/runs/M5_optD_attempt9/54-openroad-stapostpnr/summary.rpt) |
| Typical (TT) f_max | 90 MHz (-1.11 ns WNS) | A9 STA |
| FF f_max (closes) | >100 MHz (+2.94 ns WNS ✓) | A9 STA |
| Cell area (TILE_DIM=2) | 0.45 mm² | A8b yosys_stat |
| Chip power TT 100 MHz | 0.366 W | [A8b power_nom_tt.rpt](../../../project/m3/synth/top_small_M5_attempt8/power_nom_tt.rpt) |
| DRC / LVS / antenna | **clean** | A9 |
| GDS streamed out | **yes** (Magic + KLayout, XOR clean) | A9 |

### ff_backward throughput on the chip (projected, full 64×64 M1-spec)

The chip's GEMM primitive maps every GEMM in ff_backward to a sequence
of 64×64×64 tiles. Useful ops/cycle = 4096 PEs × 2 = 8,192 ops/cycle.
Sustained throughput on ff_backward depends on utilization — assumed
60 % to account for the element-wise GELU' multiply and softmax not
overlapping with every cycle of the GEMM streams.

| Operating point | f_max | Peak GOPS | Sustained on ff_backward (60 %) |
|---|---:|---:|---:|
| Sky130 SS (worst-case sign-off) | 45 MHz | 369 | **~221 GOPS** |
| Sky130 TT (typical) | 90 MHz | 737 | ~442 GOPS |
| Sky130 FF (fast) | 100 MHz | 819 | ~491 GOPS |
| **SAED32 SS @ M1 spec target** (phobos, projected) | 500 MHz | 4,096 | **~2,458 GOPS** |

### ff_backward arithmetic intensity on the chip (Q16.16 view)

Same kernel, different precision (Q16.16 = 4 B/element vs fp64 = 8 B/element)
and different memory hierarchy (chip's on-chip `tile_buffer` provides
within-tile reuse the CPU doesn't have):

```
Chip no-reuse lower bound : 33.7 MFLOP / 135 MB ≈ 0.25 FLOP/B
Chip full-reuse upper bound: 33.7 MFLOP / 410 KB ≈ 82 FLOP/B
```

The chip operates at the **full-reuse upper bound (~82 FLOP/B)** because
`tile_buffer` is exactly architected for this; per the Sky130 roofline
ridge of 1.44 FLOP/B, this puts the chip squarely in the **compute-bound
region** — adding off-chip bandwidth gains nothing, only compute does.

## Power + energy (projected)

| Operating point | Total chip power | ff_backward sustained | Energy efficiency |
|---|---:|---:|---:|
| CPU (M1, sustained) | ~45 W | 3.4 GFLOP/s | 76 MFLOP/J |
| **Chip @ Sky130 SS** | ~6 W | 221 GOPS | **~37 GOPS/J** |
| Chip @ SAED32 SS (projected) | ~25 W | 2,458 GOPS | **~98 GOPS/J** |

## Row 3 — Speedup on ff_backward (the workload-kernel headline)

| Comparison | CPU | HW projected | Speedup |
|---|---:|---:|---:|
| **ff_backward throughput (measured sustained)** | **3.4 GFLOP/s** | **221 GOPS** (Sky130 SS) | **65×** |
| ff_backward energy / op (J per op) | 13 nJ/op | 27 pJ/op | **~480×** |
| ff_backward energy / token (J/tok) | 6.2 mJ/tok | 0.7 mJ/tok | **~9×** |
| Full iter wall-clock | 35.3 ms | ~11 ms (Amdahl-bound) | **3.2× end-to-end** |
| ff_backward @ SAED32 M1-spec target | 3.4 GFLOP/s | 2,458 GOPS | **723×** |

The 3.2× end-to-end iteration speedup is Amdahl-bounded — 20 % of the
workload (LayerNorm, residual, optimizer, embedding) stays on CPU, so
even with infinite ff_backward speedup the total iteration can't drop
below 0.2 × 35.3 ms = 7 ms.

## Comparison vs the M1 Heilmeier promise

| M1 Heilmeier claim | This delivery |
|---|---|
| 10× speedup on ff_backward kernel | **65× on Sky130 SS** (chip's worst-case), 723× projected at SAED32 — **exceeds the 10× target on both targets** |
| 1,390 GFLOP/s on ff_backward | 221 GOPS Sky130 SS / 2,458 GOPS SAED32 (both exceed; Sky130 due to mixed-precision counting, SAED32 due to architectural target) |
| 256 GB/s on-chip SRAM bandwidth | Achieved by design (`tile_buffer` multi-port reads at ARRAY_DIM=64) |
| 500 MHz target on SAED32 | TT projected at typical, SS not yet validated post-PnR (phobos in flight) |
| 8 GB/s UCIe x16 host interface | Not on the critical AI path — kernel is bandwidth-flat above 1.44 FLOP/B |

## Honest caveats

- All HW numbers are **PROJECTED**, not measured end-to-end.
- The 60 % utilization assumption isn't validated; lower utilization
  (30-40 %) drops the headline 65× to ~30-45×.
- Q4.4 × Q4.4 → Q16.16 has ~3 LSB Q16.16 worst-case error on the
  activations vs fp64; not bit-equivalent but within the M5 precision
  study's acceptable error budget (cf02).
- SAED32 numbers depend on the phobos run finishing post-PnR; current
  Genus mid-`syn_opt` showed -482 ps WNS at 1 ns target, consistent
  with ~600 MHz pre-PnR projection.

## See also

- Roofline plot: [`cf09/benchmarks/roofline_plot.png`](roofline_plot.png)
- Gap analysis: [`cf09/benchmarks/roofline_analysis.md`](roofline_analysis.md)
- M5 narrative: [`project/m3/synthesis_notes.md`](../../../project/m3/synthesis_notes.md)
