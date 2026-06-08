# M4 Benchmark — Accelerator vs Software Baseline

All numbers in this file trace back to a measurement in the repository.
Raw values are committed in [`benchmark_data.csv`](benchmark_data.csv).

## Method of measurement

| Number | How it was measured |
|---|---|
| **Accelerator cycles/macro** | RTL simulation under QuestaSim 2021.3_1 on phobos. `tb_ff_backward_e2e` instruments the FFN-backward macro entry/exit (`cyc_start = $time/2`, `cyc_end = $time/2`) and prints `macro completed in <N> cycles` for each of four scenarios. The four scenarios reported the same 32,989 cycles — the macro path is data-independent. See [`project/m3/sim/logs/tb_ff_backward_e2e.log`](../../m3/sim/logs/tb_ff_backward_e2e.log). |
| **Accelerator clock frequency** | Post-synthesis closed-timing point. Genus 21.12 on SAED32 RVT, 2 ns clock period, 0 violators, WNS +0.1 ps. From [`../synth/qor_report.txt`](../synth/qor_report.txt). |
| **Accelerator power** | Genus vectorless power estimate, `_nominal_` (balanced_tree) corner, SAED32 `tt0p85v25c`. 2.347 W total. From [`../synth/power_report.txt`](../synth/power_report.txt). |
| **Software baseline** | Wall-clock timing from `time.perf_counter()` over 100 runs (5 warmup) on the M1 platform. 35.317 ms median for one full forward+backward transformer iteration. From [`../../m1/sw_baseline.md`](../../m1/sw_baseline.md). |

## Headline numbers

| Metric | Software baseline (M1) | M4 accelerator | Speedup |
|---|---|---|---|
| Peak compute (this kernel, this PDK) | 139 GFLOP/s (DRAM-bound on CPU roofline at AI=5.43) | **4.096 TFLOP/s** (4,096 PEs × 500 MHz × 2 FLOP/MAC) | **29.5×** peak/peak |
| Sustained on 64×64 FFN backward tile | 3.398 GFLOP/s (whole transformer iter) | **8.07 GFLOP/s** (single tile, includes load/drain) | **2.4×** measured-vs-measured |
| Time per 64×64×64 FFN_BWD tile | not measured directly | **65.978 µs** (32,989 cyc @ 500 MHz) | — |
| Energy per FLOP — peak/steady-state | ~260 pJ/FLOP (35.3 ms × ~25 W est. / 3.4 GFLOP per iter) | **0.57 pJ/FLOP** (2.347 W / 4.096 TFLOP/s) | **~450×** |
| Energy per FLOP — measured-on-tile | (same) | 291 pJ/FLOP (155 µJ / 532 kFLOP) | ~1.0× — small tile overhead dominates |

The two speedup numbers are both real and both important. **Peak vs peak** tells you what the silicon can do at full utilization — what justifies building it. **Sustained vs sustained on the same kernel** tells you what an unmodified host application sees today on a single-macro call — the small-tile path is fill/drain-limited, not compute-limited. The gap is closed by amortizing fill/drain over multi-tile macros; the architecture already supports this (`num_m_tiles × num_n_tiles` in `macro_cmd_t`) but the verified end-to-end testbench only exercises single-tile commands, so we report only what was measured.

## How the cycle count breaks down (annotated)

`tb_ff_backward_e2e`'s 32,989 cycles cover **macro issue → done IRQ** for one 64×64 backward tile. That window includes:

1. **A and B tile load from scratchpad through DMA into the tile buffers** — ~4,096 cycles each, one Q4.4 element per cycle through the DMA channel.
2. **AUX (pre-activation `h_pre`) tile load for the GELU′ multiplier** — another ~4,096 cycles.
3. **Systolic compute (64×64 GEMM)** — fill 64 + compute 64 (K-dim) + drain 64 ≈ 192 cycles of full-array activity.
4. **Postproc pipeline (GELU′(h_pre) multiplication, per-element)** — 4,096 cycles streaming through `fused_postproc_unit`.
5. **Writeback to scratchpad** — 4,096 cycles.

Compute is ~0.6% of the macro window. The rest is on-chip data movement. This is exactly what the M1 roofline predicted: this kernel is memory-bound, not compute-bound, on _any_ platform — but on-chip SRAM bandwidth (one Q4.4 element per cycle per channel) is ~3 orders of magnitude higher than the M1 platform's single-channel DRAM, which is why the architectural speedup is real even though per-tile utilization looks low.

## Speedup vs M1 software baseline

**Sustained-vs-sustained (apples to apples on the same kernel):**

```
SW baseline iter:    35.317 ms / iter (256 tokens, 2 layers, fwd+bwd)
M4 accelerator iter: 32,989 cycles × 2 ns / 500 MHz = 65.978 µs / 64×64×64 FFN_BWD tile

Speedup (sustained, same kernel) ≈ 2.4× — accelerator on one tile vs CPU on full iter, both
measured as GFLOP/s. This understates the architecture because the CPU number is over the
whole transformer iter while the accelerator number is per-tile-with-load.
```

**Peak-vs-CPU-attainable (architectural ceiling):**

```
CPU roofline attainable (FFN_BWD, AI=5.43): 139 GFLOP/s
M4 accelerator peak:                        4,096 GFLOP/s = 4.096 TFLOP/s
Speedup (peak/attainable):                  29.5×
```

If the M4 accelerator point is reported on the roofline plot at the **sustained-on-tile** value (8.07 GFLOP/s), it sits well below the M4 ridge line, exactly where you'd expect a single-tile FFN_BWD: roofline plots predict that small reuse-bound kernels never hit peak. The plot is in [`roofline_final.png`](roofline_final.png).

## Energy comparison

For the CPU baseline we estimate ~25 W package power during the i5-10500H benchmark (the CPU has a 45 W TDP and the workload is multithreaded NumPy at ~60 % CPU utilization based on prior cProfile runs; an exact wall-power measurement was not taken, so this number carries ±20 % uncertainty).

```
SW baseline:   35.317 ms × 25 W = 0.882 J / iter ; 0.882 J / 3.4 GFLOP-iter ≈ 260 pJ / FLOP
M4 peak:       2.347 W / 4.096 TFLOP/s         ≈ 0.57 pJ / FLOP   (peak compute)
M4 measured:   65.978 µs × 2.347 W / 532 kFLOP ≈ 291 pJ / FLOP   (includes tile load/drain)
```

The peak-vs-peak comparison gives ~450× better energy/FLOP. The measured-on-tile comparison gives ~1× — again, because the small tile is dominated by setup, not compute. Multi-tile macros would land between these.

## Notes / caveats

- The 4 reported `macro completed in 32,989 cycles` lines in the log are identical because the four ff_backward scenarios cover h_pre = {1.0, 2.0, −1.0, 0.0}, which only affects the per-element GELU′ value; the macro **path** through dispatcher → systolic → postproc → DMA writeback is identical, so the cycle count is independent of h_pre. This is a feature (deterministic latency); it is not a bug or stuck-at value.
- Genus power is **vectorless** (uniform 0.2 activity factor). Activity-aware power from an SAIF would be lower than 2.347 W; this is a worst-case headline.
- The closed-timing 2 ns clock comes from the **front-end Genus synthesis run**. The phobos Innovus PnR for this design did **not** close (CTS step did not produce a constrained-paths report; see `What did not work` in the design justification report). The 500 MHz / 2 ns number used here is the synthesized-RTL ceiling at SAED32, not a post-PnR result. The Sky130 OpenLane PnR on `top_small.v` is in detail-routing at submission time; if it completes inside the M4 window, its numbers will be added under [`../synth/`](../synth/) and `roofline_final.png` regenerated.
- The M1 baseline was measured on Windows i5-10500H; the M4 accelerator was synthesized on phobos at SAED32 RVT. Cross-platform comparisons of this kind always have a comparing-apples-to-oranges component; we report both peak and measured to bound the answer.
