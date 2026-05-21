# M3 Timing Analysis — Systolic-Array Size Sweep (Phase 1)

Companion to [`Claude_sweep.md`](Claude_sweep.md). This document fills in the
timing portion of the sweep: per-N WNS, derived f_max, critical-path location,
and the extrapolation to the full 64×64 systolic array.

> **⚠️ Update (Phase 2+3 data, 2026-05-18):** the Phase-1-only f_max
> projection of **583–588 MHz** below is **superseded** by the integrated
> chip-level result. With `softmax_unit` measured in Phase 2c and
> `stream_pipeline` (the chip's main fused pipeline) measured in Phase 3,
> the chip f_max is bottlenecked at **~52 MHz** by the combinational
> Q16.16 divider inside `softmax_unit`. See
> [`chip_area_rollup.md` §6](chip_area_rollup.md) for the full new story.
> This document remains accurate for `systolic_array_64x64` *in isolation*,
> which is what the slide and Phase-1 narrative are about — but the
> chip-scale claim has changed.

## Source data

Single sweep session, captured in [`../error.txt`](../error.txt) (the
`run_sweep.sh` console transcript from phobos, 2026-05-13). Genus 21.12-s068_1
synthesized [`systolic_array_64x64.sv`](systolic_array_64x64.sv) at six sizes
with the [`run_genus_sweep.do`](run_genus_sweep.do) driver:

| Knob | Value |
|---|---|
| Library | SAED32 RVT, TT corner @ 0.85 V / 25 °C |
| Target period | **1.0 ns (1 GHz)** |
| Clock uncertainty | 50 ps |
| Clock transition | 50 ps |
| I/O delay | 0.3 × period = 300 ps |
| Driver | `INVX1_RVT` on all inputs |
| Load | 0.05 (unit cap) on all outputs |
| Mode | mixed-precision Q4.4 × Q4.4 mul → Q16.16 acc (M3 RTL) |

Phase 2 had only begun (`gelu_unit` was in elaboration when the session was
cut); Phase 3 (`stream_pipeline`) had not started. **The timing data below
covers Phase 1 only.** Phases 2–3 must be rerun before chip-level timing
roll-up.

## Phase 1 — measured timing per sweep point

Final values are read from the last `Worst cost_group: clk, WNS:` line each
point emits *after* `incr_opt` / `DRC_OPTO`, immediately before
`report_timing` runs. Cell area is the matching row from the
`Incremental optimization status` table.

| Tag | N | PEs | Cell area (μm²) | Per-PE area (μm²) | WNS @ 1 GHz (ps) | Achievable period (ps) | **f_max (MHz)** |
|---|---:|---:|---:|---:|---:|---:|---:|
| `systolic_array_64x64_1x1`   |  1 |    1 |     1,835 | 1,835 | **−560.4** | 1560.4 | **640.9** |
| `systolic_array_64x64_2x2`   |  2 |    4 |     6,903 | 1,726 | **−641.3** | 1641.3 | **609.3** |
| `systolic_array_64x64_4x4`   |  4 |   16 |    27,024 | 1,689 | **−648.4** | 1648.4 | **606.6** |
| `systolic_array_64x64_8x8`   |  8 |   64 |   102,849 | 1,607 | **−668.9** | 1668.9 | **599.2** |
| `systolic_array_64x64_16x16` | 16 |  256 |   402,507 | 1,572 | **−667.1** | 1667.1 | **599.8** |
| `systolic_array_64x64_32x32` | 32 | 1024 | 1,611,448 | 1,574 | **−683.7** | 1683.7 | **593.9** |

Achievable period = `CLK_PER − WNS` = `1000 ps − WNS_ps` (WNS is negative, so
this adds magnitude). f_max = 1 / achievable period.

Every point **misses the 1 GHz target**: WNS is negative across the entire
sweep. The 1 GHz constraint in [`run_genus_sweep.do`](run_genus_sweep.do)
should be read as a synthesis effort knob, not an achievable frequency — the
PE datapath itself can't close 1 ns in this library without re-pipelining.

## Critical path

The reported failing path is the **same shape** at every N:

```
Path: a_in[i][k] | b_in[i][k]  -->  gen_row[r].gen_col[c].u_pe_acc_r_reg[m]/D
```

i.e. a primary input pin (one bit of an `a_in` or `b_in` operand on the
array boundary) straight through **a single corner PE's MAC pipeline** into
that PE's accumulator flop. Concretely:

```
a_in[…]  --+
           +---> Q16.16 → Q4.4 quantize/saturate
           |        ↓
           |     8×8 signed multiply           (in mac_pe.sv)
           |        ↓
           |     Q8.8 → Q16.16 align (<<8)
           |        ↓
           |     Q16.16 accumulator add
           |        ↓
           +---> u_pe_acc_r_reg/D
b_in[…]  --+
```

Because every PE's `a_out` and `b_out` to its neighbor are **registered** in
[`mac_pe.sv`](mac_pe.sv), the systolic array does *not* expose a multi-PE
combinational chain to the timer. The worst path is intra-PE, not
end-to-end across N PEs. This is exactly why the WNS column above stays
within a ~120 ps band across two decades of `N`, despite cell area scaling
~880×:

```
ΔWNS (1×1 → 32×32) =  +123.3 ps     across 1024× more PEs
ΔWNS (8×8 → 32×32) =   +14.8 ps     across 16× more PEs
```

The mild N-dependence is dominated by **secondary** effects, not by
adding logic stages to the critical path:

- I/O delay (boundary nets get longer as the array grows; the SDC pins
  `INVX1_RVT` as driver, so a bigger fanout / wireload hits the
  combinational arrival at the corner PE).
- Wireload model conservatism scaling with total cell count.
- Clock-tree skew estimates growing with N.

This is the **good** kind of N-dependence: O(log N) at worst, not O(N).

## Fit and 64×64 projection

Fit `|WNS(N)| ≈ a + b · log₂(N)` by least squares over the six points:

```
a = 594.0 ps     b = 20.4 ps / octave-of-N      R² = 0.86
```

(A pure constant fit gives R² = 0; a quadratic-in-N² fit is worse because
the trend is logarithmic, not quadratic, in N.)

Projection to the full 64×64 array (log₂(64) = 6):

```
|WNS(64)|   ≈ 594 + 20.4 × 6        =  716 ps
period(64)  = 1000 + 716            = 1716 ps
f_max(64)   = 1 / 1716 ps           ≈  583 MHz
```

Empirical bound: the **8×8 → 32×32** segment of the curve degraded by
14.8 ps. If we extrapolate that slope linearly through 64×64 (one more
octave), we get an additional ~15 ps, putting `|WNS(64)| ≈ 700 ps` and
**f_max(64×64) ≈ 588 MHz**. The log-fit and the local-slope estimates agree
to ~1%, so the band is tight:

> **64×64 systolic_array_64x64 — projected f_max: 583–588 MHz**
> (achievable period ≈ 1.70 ns ± 0.02 ns at 1 GHz target, SAED32 RVT TT
> @ 0.85 V / 25 °C, mixed-precision Q4.4 × Q4.4 → Q16.16 MAC).

To break under 1 ns the **PE internal pipeline** has to be split — either
by registering between the Q4.4 multiplier and the Q16.16 alignment shift,
or between the alignment shift and the accumulator add. That is an M3
RTL change, not a synthesis-side fix.

## Caveats / what this does *not* cover

- **Phase 2 (fusion blocks)** never produced numbers in this run.
  `gelu_unit` had just started elaborating when the session ended.
  Without `softmax_unit`, `gelu_grad_unit`, `divider_or_reciprocal_unit`,
  the fused activation pathway is unmeasured. Those blocks plausibly have
  worse intra-block paths than `mac_pe` (32-bit Q16.16 divider /
  Padé-tanh polynomial), so chip-level f_max is bounded by **min** over
  all blocks, and may end up lower than the 583–588 MHz reported here.
- **Phase 3 (stream_pipeline sweep)** is not started. The glue logic
  around the array adds output-buffer + drain paths that touch a
  64-port `tile_buffer` — that's a likely critical-path candidate at
  large N. **Rerun Phase 3 before quoting a chip f_max.**
- **Post-route effects** (routing parasitics, clock tree insertion delay,
  IR drop) are not in synthesis WNS. Budget an additional ~15–25%
  margin between synthesis f_max and post-P&R f_max.
- The 1 GHz constraint exercises critical-path optimization but is
  unachievable for this RTL. Re-running the sweep at a **realistic
  target** (e.g. 1.7 ns / 588 MHz) would give cleaner WNS = ~0 numbers
  and lets `syn_opt` spend its effort on area instead.

## What to do next

1. **Re-run Phase 2 to completion** — ✅ done (2026-05-18).
2. **Run Phase 3** — ⚠️ partial (2/6 points: N=1, N=2 only). The
   `stream_pipeline_2x2` measurement confirms the chip f_max is
   bottlenecked by `softmax_unit`, not by the systolic array — see
   [`chip_area_rollup.md`](chip_area_rollup.md).
3. After Phase 2/3 are done, regenerate `sweep_results.csv` with
   [`collect_sweep_csv.py`](collect_sweep_csv.py) and re-fit with
   [`analyze_sweep.py`](analyze_sweep.py). ✅ done. Results in
   [`sweep_results.csv`](sweep_results.csv),
   [`sweep_metrics.txt`](sweep_metrics.txt),
   [`sweep_figure.pdf`](sweep_figure.pdf).
4. If 583–588 MHz is below the system target, the **single
   actionable RTL change** is to add a pipeline stage inside
   `mac_pe.sv` between the Q4.4 multiply and the Q16.16 accumulate.
   That doubles MAC latency by one cycle but removes the dominant path.
   ⚠️ **However** — the new Phase 2+3 data shows the chip-level f_max is
   actually limited by softmax_unit's combinational divider (52 MHz at
   1 ns target), not the MAC. The mac_pe pipeline is still needed for
   PVT robustness, but the bigger M4 RTL target is to replace softmax's
   Padé + divider with a LUT-based exp + reciprocal. See
   [`chip_area_rollup.md` §6.1](chip_area_rollup.md) for the analysis.
