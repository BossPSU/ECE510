# M3 Project Scope Assessment

**Verdict: scope confirmed, no reduction needed.**

The M3 deliverable is the mixed-precision Q4.4 × Q4.4 → Q16.16 systolic
MAC plus a chip-level area/timing characterization swept across
N ∈ {1, 2, 4, 8, 16, 32} (with extrapolation to 64×64). Two independent
synthesis flows now confirm the design synthesizes cleanly and the
critical path is well understood:

- **OpenLane 2 (Sky130A, CF07)** — `mac_pe` closed timing at 10 ns
  with +1.475 ns slack at the typical corner (f_max ≈ 117 MHz).
  Critical path is intra-PE (`a_in` → quantize → multiply → align →
  accumulator flop). 1,482 instances post-PnR, 10,327 µm². Full report:
  [`../codefest/cf07/synth/`](../codefest/cf07/synth/).
- **Cadence Genus (SAED32, M3 sweep)** — Phase 1 complete. Per-N WNS at
  1 ns target stays within a ~120 ps band across 1× → 1024× PE count
  (sys_1x1 = −560 ps, sys_32x32 = −684 ps), confirming the array does
  not expose a multi-PE combinational chain. Projected f_max(64×64) ≈
  583–588 MHz. Full analysis:
  [`./RTL/timing_analysis.md`](./RTL/timing_analysis.md).

**Scope adjustments based on the synthesis data:**

1. **No precision drop, no unrolling cuts.** Both tools agree the
   bottleneck is the unpipelined MAC, not the precision or array size.
   The M3 RTL change is a single pipeline register inside `mac_pe.sv`
   between Q8.8 and Q16.16. Justified in CF07 m3_plan.md.
2. **No chip-area scope reduction.** The Phase-2c softmax sweep (just
   added) addresses the one outlier block (softmax_unit at VEC_LEN=64
   = 3.66–3.82 mm² standalone). The chip rollup math now has a curve
   to interpolate against, instead of being stuck with the single
   blow-up point.
3. **Keep both tool flows.** OpenLane (Sky130) is the
   reproducible-anywhere reference; Genus (SAED32) is the real
   characterization for M3 numbers. The OpenLane → Genus delta is
   process-geometry, not design-quality.

Risks tracked but not changing scope:
- Phobos sweep wall-clock has been long (~30 h in latest session, mostly
  the legacy `softmax_unit` VEC_LEN=64 point). Mitigated by phase2c
  sweep covering smaller VEC_LEN values; the legacy point can be
  dropped from PHASE2_BLOCKS for future re-runs.
- Slow-corner setup violations at 100 °C / 1.60 V are expected for an
  unpipelined block at 100 MHz; the M3 pipeline change addresses both
  the typical-corner headroom and the slow-corner gap.
