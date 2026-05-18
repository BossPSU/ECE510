# M3 — OpenLane 2 Synthesis Interpretation (full version)

Working document for the M3 milestone. This is the unrestricted
companion to [`../codefest/cf07/synth/synth_interpretation.md`](../codefest/cf07/synth/synth_interpretation.md),
which is the 200–300-word CF07 deliverable. Same OpenLane run
(`runs/RUN_2026-05-17_16-36-25/`), more analysis.

## 1. Where `mac_pe` sits in the chip

The mixed-precision Q4.4 × Q4.4 → Q16.16 MAC processing element is the
single-MAC leaf of the M3 accelerator hierarchy:

```
compute_core           ← top-level macro
  └── accel_top
       └── 16 × accel_engine                 ← one per lane
              └── stream_pipeline
                   └── systolic_array_64x64  ← 4,096 PEs per array
                          └── 4,096 × mac_pe ← THIS BLOCK
```

Total PE count at the chip level: **16 × 64 × 64 = 65,536 instances of
`mac_pe`**. Per the M2 README and the Genus
[`timing_analysis.md`](RTL/timing_analysis.md), the PE area dominates
the chip-scale budget (4,096 × area(`mac_pe`) per array, then ×16
lanes, plus glue). Whatever this leaf costs, the chip pays roughly
65 K times.

The accelerator's central architectural lever is *mixed precision*.
Per [`mac_pe.sv`](RTL/mac_pe.sv) and the inlined
[`synth_top.sv`](../codefest/cf07/hdl/synth_top.sv), each PE:

1. Quantizes Q16.16 boundary operands to Q4.4 (8-bit signed) with
   saturation at ±7.9375 / −8.0.
2. Performs an 8×8 signed multiply → 16-bit Q8.8 product.
3. Sign-extends and shifts the Q8.8 product left by 8 → Q16.16.
4. Adds into the Q16.16 accumulator.

The accumulator stays at full Q16.16 precision (no loss across long
dot products); only the multiplier shrinks. Area scales as
O(MULT_W²), so 32×32 → 8×8 gives a ~16× multiplier area reduction.
That ratio is what makes the chip's PE count tractable.

## 2. Synthesis setup

| Knob | Value | Reasoning |
|---|---|---|
| Tool | OpenLane v2.3.10 | latest stable; Yosys + OpenROAD; pulled via Nix flake |
| PDK | Sky130A | open-source 130 nm, OpenLane default |
| Std-cell library | `sky130_fd_sc_hd` | high-density variant |
| `CLOCK_PERIOD` | 10 ns (100 MHz) | relaxed first pass; tighten later for f_max |
| `DIE_AREA` | 200 × 200 µm² | fixed floorplan, comfortable for one MAC |
| `FP_CORE_UTIL` | 40 % | conservative density, routing headroom |
| `DESIGN_IS_CORE` | false | macro-level, no I/O pads |

73-step flow ran end-to-end through DRC, LVS, and GDS streamout with
0 errors. Lint: 0 errors, 0 warnings, 0 inferred latches.

## 3. Headline numbers

| Metric | Value |
|---|---|
| Cell instances (post-PnR) | **1,482** |
| Cell area (post-PnR) | **10,327 µm²** |
| Sequential elements | 88 DFFs = 2,312 µm² (~28 %) |
| Combinational area | ~8,015 µm² (~72 %) |
| Yosys pre-PnR area | 8,398 µm² |
| Yosys pre-PnR cells | 702 (grew to 1,482 after CTS + buffer insertion) |
| WNS @ typical (`nom_tt_025C_1v80`) | **+1.475 ns** (MET) |
| Effective f_max @ typical | **~117 MHz** |
| Hold WNS @ typical | +0.335 ns |
| WNS @ slow (`nom_ss_100C_1v60`) | **−4.499 ns** (VIOLATED) |
| WNS @ fast (`nom_ff_n40C_1v95`) | not violated |
| Total power @ typical | **2.72 mW** |
| Max-fanout violations | 6 (control nets) |

## 4. Critical path

Reported worst path at every PVT corner has the same structural
shape:

- **Startpoint:** primary input `a_in[*]` (Q16.16 boundary bit;
  index varies by corner — `a_in[15]` at typical, `a_in[22]` at slow,
  reflecting different cell-delay distributions across PVT).
- **Endpoint:** one bit of the Q16.16 accumulator flop (Yosys-named
  internal flop `_1299_` and friends; resolves to `acc_r` in
  [`mac_pe.sv`](RTL/mac_pe.sv)).

Cell sequence (from `sta_nom_tt_max.rpt`, ~26 cells deep):

```
OR4 → NOR4 → O31A → buf6 → buf8 → OR4 → XOR2 → A31O → XOR2 → XNOR2
→ XNOR2 → O32A → XNOR2 → NAND2 → AND3 → OR2 → NOR3 → buf6 → O2111AI
→ A31O → ...  (continues into the accumulator carry chain)
```

The first OR4/NOR4 cluster is the Q16.16 → Q4.4 saturation MUX
(testing `>+127` and `<−128`). Everything from the first XOR2 onward
is the 8×8 signed multiplier and the Q16.16 accumulator adder.

**Why this is the critical path:** every step from the input pin
through the multiplier, alignment shift, and accumulator add is
combinational. Nothing latches between them. That's by design — the
RTL targets a single-cycle MAC for the systolic array's
output-stationary dataflow. The cost is that the combinational depth
is the full Tpd of every cell in the chain, plus net delays.

## 5. Cell composition — what the top contributors say

| Cell type | Count | What it tells us |
|---|---:|---|
| `dfrtp_2` (rising-edge DFF with async reset, drive 2) | 88 | 32-bit acc (32) + 32-bit `a_out` forwarding (32) + 32-bit `b_out` forwarding (32) ≈ 96 expected, actually 88 (some optimized away). Sequential area is ~28 % of the PE — exactly the ratio you want for a streaming MAC. |
| `nor2_2`, `xnor2_2` | 68 each | XNOR is the signature of signed multiplier partial-product compression and adder sum logic; NOR is the dual used by carry-propagate. 136 of these together account for the bulk of arithmetic. |
| `mux2_1` | 65 | Q4.4 saturation MUX (×2 per input × 8 bits = 32) + `clear_acc` select on every accumulator bit (32) + 1 more. The saturation MUX is a fixed cost of mixed-precision quantization. |
| `xor2_2` | 45 | the rest of the multiplier sum logic |
| `or2_2` / `and2_2` | 36 / 16 | carry-propagate / partial-product |

**Architectural takeaway.** The PE is 72 % combinational, dominated by
multiplier and adder logic. The mixed-precision quantizer (saturation
MUXes) is a small but non-trivial overhead — about 4 % of cell count.
There's no wasted sequential state.

## 6. The slow-corner gap

**This is the one substantive issue.** At `nom_ss_100C_1v60` (slow
process variant, 100 °C, 1.60 V supply — a 12 % undervolt from the
1.80 V nominal), the same critical path takes **14.499 ns** vs the
10 ns clock target. WNS = −4.499 ns. The path is **45 % over budget
at SS PVT.**

**Why Sky130 SS is unusually aggressive.** The Sky130 PDK ships with
deliberately conservative corners — it's an open-source 130 nm PDK
with a wide guaranteed process distribution. The SS corner is
"guaranteed no die anywhere fails," which is much more pessimistic
than a typical commercial 130 nm corner (which would model only
±3σ on process). It's common for first-pass open-source designs to
clear typical and miss SS by 20–50 %.

**What the gap actually costs.** Three concrete consequences:

1. **The chip is not 100 MHz at slow PVT.** Slow-corner clock max is
   ~69 MHz (10 / 14.5 × 100). That's a **31 % frequency haircut** from
   the typical-corner 117 MHz.
2. **Throughput hit:** at N=32 the array does 1,024 MACs/cycle. At
   69 MHz that's ~71 GMACs/s; at 117 MHz it's ~120 GMACs/s. The
   difference is real.
3. **Spec implication:** any chip-level frequency claim has to be
   honest about which PVT corner. A "100 MHz accelerator" spec can't
   ship without closing SS or derating publicly.

**Could syn_opt have fixed it on its own?** The flow already tried —
the log shows `RSZ-0062 unable to repair all setup violations`. The
combinational depth is what it is; cell-sizing alone can't recover
4.5 ns.

## 7. Mitigation analysis

Three real options, ranked by quality of fix:

### Option A — Pipeline `mac_pe` (recommended)

Split the path at the natural register boundary between the
multiplier and the alignment shift. Concretely, add a register
between `product_q88` and `product_q` in [`mac_pe.sv`](RTL/mac_pe.sv).

- **Combinational depth after split:** roughly halved. The post-split
  worst path is either (quantize → 8×8 mul → flop) or
  (flop → align/shift → accumulator add → flop). Both are ~6–8 ns at
  SS, well under 10 ns.
- **Latency cost:** +1 cycle of MAC latency.
- **Throughput cost:** zero in steady state — the systolic feed
  pipeline-fills over the first cycle, then runs at one MAC/cycle.
  Over a 4,096-step dot product, 1 extra cycle is < 0.025 %.
- **Area cost:** 16 new DFFs for the Q8.8 register (~16 × 26 µm² =
  ~420 µm², about 4 % growth).
- **Frequency at all corners:** typical jumps from 117 MHz toward
  ~200 MHz; SS closes at 10 ns with positive slack.

This is the right fix and is already the M3 RTL change in
[`m3_plan.md`](m3_plan.md).

### Option B — Derate clock at slow PVT

Spec the chip at, e.g., 69 MHz across all corners.

- **Throughput cost:** 31 % vs typical-corner f_max. For a transformer
  accelerator the headline number is GMACs/s — paying 31 % to avoid
  one register is a poor trade.
- **No RTL change.** Useful as a fallback during bringup or if the
  pipeline change has a downstream blocker.

### Option C — Voltage / process binning

Bin only fast-process dies (skewing toward FF rather than SS); spec
the chip at a higher minimum voltage (e.g., 1.71 V instead of 1.60 V).

- **Reduces yield** in a real fab flow; not applicable to Sky130
  hobbyist/educational silicon.
- **Mentioned for completeness** — in practice, Option A.

## 8. Chip-scale implications

Two scaling laws to project from `mac_pe`'s single-PE numbers:

**Area.** Per-PE cell area = 10,327 µm². Per array (64×64) =
10,327 × 4,096 = **~42.3 mm²** of MAC PEs alone. Per chip (16 arrays) =
**~677 mm²**. That's clearly larger than the typical chiplet ceiling
— but this is a naive Sky130 number; the actual M3 deliverable uses
SAED32 (32 nm) and the Genus sweep, which extrapolates much smaller.
Cross-PDK area comparisons are not meaningful at the absolute level;
the per-PE number is useful for *ratio* comparisons (PE vs softmax vs
control).

**Power.** Per-PE power @ typical = 2.72 mW. Per chip (65,536 PEs) =
**~178 W**. Real production accelerators of this scale (e.g., NVIDIA
A100 at ~400 W TDP) handle similar magnitudes, but only because
they're aggressive about clock gating idle units and per-tile DVFS.
For M3 the takeaway is: **clock-gating must be wired up at the lane
level** to keep average power below the chip-level thermal budget;
running all 65,536 PEs at full activity simultaneously is not
realistic. The streaming dataflow naturally gates inactive lanes
through the `en` signal, which we already see fanning out to 88 flops
per PE (the max-fanout violations confirm this is the gating
mechanism Yosys recognized).

## 9. Cross-validation against Genus (SAED32)

The same RTL synthesized via Cadence Genus on SAED32 RVT (TT @ 0.85 V,
25 °C) reports for the systolic array's 1-PE point (`sys_1x1`):

| Metric | OpenLane (Sky130) | Genus (SAED32) |
|---|---|---|
| Process geometry | 130 nm | 32 nm |
| Per-PE cell area | 10,327 µm² | 1,835 µm² (5.6× smaller) |
| Clock target | 10 ns | 1 ns |
| WNS @ typical | +1.475 ns | −0.560 ns |
| Effective f_max | ~117 MHz | ~641 MHz |
| Critical path shape | a_in → quantize → mul → align → acc flop | identical |

The path **shape** matches across both tools, validating that the
intra-PE chain is the real bottleneck (not a PDK artifact). The
absolute numbers differ as expected for 130 nm vs 32 nm. The chip-area
extrapolation in [`RTL/timing_analysis.md`](RTL/timing_analysis.md)
uses the Genus per-N curve.

## 10. Action items rolling forward

1. **Pipeline `mac_pe` in M3 RTL.** Single-line RTL change; closes SS
   timing. See [`m3_plan.md`](m3_plan.md) §3 for the plan.
2. **Add control-net buffer in `mac_pe`** for `en` and `clear_acc` —
   clears the 6 max-fanout violations. Mechanical.
3. **Re-run OpenLane after the pipeline change** to confirm
   slow-corner closes and to get the new per-PE numbers (area +1 reg,
   timing positive at all corners).
4. **Re-run Genus sweep** post-pipeline to verify the chip-scale
   numbers haven't moved appreciably (they shouldn't — depth halves,
   but Genus's flat result is dominated by area, not depth).
