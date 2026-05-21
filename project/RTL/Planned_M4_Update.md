# Planned M4 Update — softmax_unit LUT replacement

## Problem: softmax_unit Padé + combinational divider — timing and area issues

The current `softmax_unit.sv` implements per-lane exp as a Padé[2,2]
approximation followed by a **64-bit combinational signed divide** inside
`q_exp_approx`, then squares the result twice ([softmax_unit.sv:77-118](softmax_unit.sv#L77-L118)).
At VEC_LEN = 64 the block has 64 of these Padé+divider chains running in
parallel, plus one more combinational divide in stage 4 (1/sum).

**Measured Phase 2 + 3 results expose this as the chip's worst bottleneck:**

| Block | Cell area | WNS @ 1 ns target | Implied f_max |
|---|---:|---:|---:|
| `mac_pe` (1 PE) | 1,835 µm² | −560 ps | 641 MHz |
| `sys_32x32` (1024 PEs) | 1,611,449 µm² | −684 ps | 594 MHz |
| **`softmax_unit_v64`** | **3,818,675 µm²** | **−19,080 ps** | **52 MHz** ⚠️ |
| `stream_pipeline_2x2` (softmax inside) | 290,152 µm² | −18,343 ps | 55 MHz |

Both consequences are bad:

- **Timing:** chip f_max collapses from the Phase-1 projection of ~588 MHz
  to **~52 MHz**, an 11× degradation. The Padé chain has roughly 500 gate
  levels of combinational depth, dominated by the 64-bit divider.
- **Area:** at VEC_LEN = 64 the softmax block alone costs 3.82 mm² —
  larger than the entire 32×32 systolic array (1.61 mm²) and second only
  to the multi-port `tile_buffer` in the chip-area budget.

At chip scale (16 lanes × 1 softmax per lane) this is **61 mm²** of die area
running at **~52 MHz**.

## Solution: LUT-based exp + sequential reciprocal divider

Replace the per-lane Padé + combinational divide with a lookup table for
exp(x), and replace the stage-4 combinational divide with the existing
multi-cycle `divider_or_reciprocal_unit.sv`.

The repo already ships [`exp_lut.sv`](exp_lut.sv) and [`exp_lut.mem`](exp_lut.mem)
— a 256-entry × 32-bit ROM mapping [−8, 0] to e^x in Q16.16. The values
exist; they just aren't wired into `softmax_unit` yet.

**Why a LUT is so much faster than the Padé+divider:**

A combinational divider implements non-restoring division as ~64 sequential
subtract-shift steps in pure logic — roughly 500 gate levels deep.
A LUT read collapses the same computation into:

```
quantize x → 8-bit address  →  256:1 mux tree  →  32-bit output
   ~0.5 ns                       ~5-8 gate levels (~0.5 ns)
```

≈ **50× shallower** combinational depth. That's where the chip f_max
recovery comes from, independent of how the LUT is physically realized.

## Four integration options (A-D)

Same RTL replacement (LUT for Padé), but four ways to share the LUT
hardware across the 64 lanes, with very different area outcomes:

| Design | Approach | Area estimate (per softmax_unit at VEC_LEN=64) | Latency added |
|---|---|---:|---|
| **A — Duplicate per lane** | `genvar` loop instantiating 64 independent `exp_lut` modules | **~3-6 M µm²** — could be *worse* than current 3.82 M | +1 cycle |
| **B — Multi-port shared LUT** | One LUT storage with 64 parallel read ports (multi-port mux fan-out) | **~1-2 M µm²** | +1 cycle |
| **C — Time-multiplex banked LUTs** | 8 LUT instances, each serving 8 lanes per cycle over 8 cycles | **~0.4-0.8 M µm²** (5-10× smaller) | +8 cycles (one-time pipeline fill) |
| **D — Combinational ROM via `case`** | Rewrite LUT as `always_comb case (addr) ...` so Genus minimizes via ESPRESSO | **~0.5-1 M µm²** (depends on minimization quality) | 0 cycles (combinational) |

**Most likely best M4 design: C (time-multiplex banked LUTs) + sequential
divider for stage 4.** That combination gets you:

- 64 lanes' exp via 8 LUT instances over 8 cycles ≈ 0.5 M µm²
- Sequential divider for 1/sum ≈ 50 K µm² (replaces embedded combinational divide)
- Total softmax: **~0.6-0.9 M µm²** — about **4-6× smaller** than current 3.82 M

## Projected timing savings

Independent of which integration option (A/B/C/D) is picked — the
**combinational depth** drops from ~500 gate levels to ~5-10 gate levels:

| Architecture | Per-lane combinational depth | WNS @ 1 ns | f_max |
|---|---:|---:|---:|
| Current (Padé + comb divider) | ~500 levels (~22 ns) | −19,080 ps | 52 MHz |
| Any LUT-based design (A/B/C/D) | ~5-10 levels (~1 ns) | comfortably MET | 600+ MHz |

**Chip-f_max recovery: ~11× (52 MHz → 600+ MHz).** After this fix, the chip
returns to being limited by the systolic array (~588 MHz projection from
Phase 1), as originally expected.

## Chip-scale area implications

At chip scale (16 lanes × 1 softmax per lane):

| Per-lane softmax | Chip total (16 lanes) | Chip savings |
|---|---:|---:|
| Current (3.82 M µm² each) | **61.1 mm²** | (baseline) |
| Design A (naive duplication) | ~64-96 mm² | **WORSE** ❌ |
| Design B (multi-port shared) | ~16-32 mm² | −29 to −45 mm² |
| **Design C (time-multiplexed) — recommended** | **~10-15 mm²** | **−46 to −51 mm²** |
| Design D (combinational ROM) | ~8-16 mm² | −45 to −53 mm² |

A good LUT design saves **~50 mm²** at chip scale — about **10 % of the
projected ~460-500 mm² chip area**. Combined with the f_max recovery,
it's the highest-ROI single RTL change available for M4.

## Recommended M4 first step

Don't commit to a final integration option yet — **measure first.**
Concrete plan:

1. **Write `softmax_unit_lut.sv`** as a drop-in replacement using
   **design C** (8-way time-multiplexed shared LUT + sequential
   reciprocal). Pattern-match against the existing `exp_lut.sv`
   interface and the current `softmax_unit.sv` stage structure.

2. **Functional verification:** run all 7 testbenches in
   [`run.do`](run.do) against the new module. Confirm Q16.16 outputs
   match the current Padé-based softmax within tolerance on at least
   `tb_softmax_unit` and `tb_accel_top`.

3. **Synthesize across the existing sweep points.** Reuse
   [`run_genus_sweep.do`](run_genus_sweep.do) with `SYNTH_TOP=softmax_unit_lut`
   and `SOFTMAX_VEC ∈ {1, 2, 4, 8, 16, 32}`. Expected wall-clock:
   ~30 min total (each LUT point should synthesize in well under 5 min
   vs the current ~15 min per Padé point, because there's no
   combinational divider for syn_opt to grind on).

4. **Compare side-by-side:**
   - Area at each VEC_LEN (LUT vs current Padé)
   - WNS at each VEC_LEN (LUT should be hugely better)
   - Power at each VEC_LEN

5. **If the LUT design wins on all three axes:** swap it into
   [`stream_pipeline.sv`](stream_pipeline.sv) (which instantiates
   `softmax_unit` with `.VEC_LEN(ARRAY_DIM)`) and re-synthesize
   `stream_pipeline_4x4` + `stream_pipeline_8x8` to confirm chip-level
   f_max actually recovers as predicted.

**Effort estimate (half a day):**

| Step | Wall-clock |
|---|---|
| RTL writing | 1-2 hours |
| Testbench verification | 30 min |
| Synthesis sweep (6 points) | ~30 min |
| `stream_pipeline` re-synth (2 points) | ~1-2 hours |
| Comparison + writeup | 1 hour |
| **Total** | **~4-5 hours** |

**Outcome:** defensible chip f_max recovery (52 MHz → 600+ MHz),
~50 mm² chip area savings, and the only remaining timing bottleneck
becomes the systolic array — which the existing
[`m3_plan.md`](../m3_plan.md) already plans to pipeline.
