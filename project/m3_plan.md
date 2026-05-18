# M3 — Project Plan (full version)

Working document for the M3 milestone. Unrestricted companion to
[`../codefest/cf07/synth/m3_plan.md`](../codefest/cf07/synth/m3_plan.md)
(100–150-word CF07 deliverable) and
[`synth_interpretation.md`](synth_interpretation.md) (full OpenLane
analysis).

## 1. M3 deliverable scope

The M3 milestone is the **mixed-precision (Q4.4 × Q4.4 → Q16.16)
transformer accelerator** with a chip-scale area/timing
characterization derived from a synthesis sweep. Concretely:

| Item | Source | Status |
|---|---|---|
| Mixed-precision MAC RTL | [`RTL/mac_pe.sv`](RTL/mac_pe.sv) | done |
| RTL passes all testbenches | [`RTL/tb_results.log`](RTL/tb_results.log) | done — 0 FAIL / 0 ERROR across 7 TBs |
| OpenLane synthesis cross-check | [`../codefest/cf07/synth/`](../codefest/cf07/synth/) | done — `mac_pe` at 1,482 cells, 117 MHz typ |
| Cadence Genus sweep on phobos | [`RTL/run_sweep.sh`](RTL/run_sweep.sh) | Phase 1 done, Phase 2 partial, Phase 2b/2c/3 pending |
| Chip-area extrapolation | [`RTL/analyze_sweep.py`](RTL/analyze_sweep.py) | pending — needs sweep complete |
| Timing analysis writeup | [`RTL/timing_analysis.md`](RTL/timing_analysis.md) | done for Phase 1 |
| RTL pipeline change | not yet | **gated on this plan** |

## 2. Why M3 matters — what we're proving

A transformer's compute is dominated by dense matmul (attention QK^T,
attention scores × V, FFN weight matrices). The chip-scale
acceleration story is:

| Layer | Throughput multiplier | Mechanism |
|---|---:|---|
| 1× `mac_pe` | 1 MAC/cycle | Q4.4 × Q4.4 → Q16.16, 8×8 multiplier, ~16× smaller than 32×32 Q16.16 |
| 64×64 `systolic_array_64x64` | **4,096 MACs/cycle** | output-stationary dataflow; A/B operands stream W→E and N→S; no intermediate SRAM writes |
| 1× `stream_pipeline` | (same 4,096) | wraps the array; fuses matmul + activation; intermediates never materialize |
| 16-lane `compute_core` | **65,536 MACs/cycle** | 16 streams in parallel, one tile_dispatcher per chip |

At 100 MHz that's ~6.5 TMACs/s. At our typical-corner OpenLane f_max
of ~117 MHz, ~7.7 TMACs/s. That's the M3 acceleration claim.

## 3. RTL change required

**Pipeline `mac_pe` between the 8×8 multiply and the Q8.8→Q16.16
align/accumulator.**

```sv
// In mac_pe.sv: add a register between product_q88 and product_q
logic signed [2*MULT_W-1:0] product_q88_reg;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      product_q88_reg <= '0;
    else if (en)     product_q88_reg <= product_q88;
end
// Then product_q is derived from product_q88_reg, not product_q88
```

| Aspect | Before | After |
|---|---|---|
| Combinational depth (typ corner) | 26 cells, 8.525 ns | ~13 cells, ~4.3 ns |
| WNS @ slow corner | −4.499 ns (VIOLATED) | projected ~+5 ns (MET) |
| WNS @ typical corner | +1.475 ns | projected ~+5.7 ns |
| Per-PE cell area | 10,327 µm² | +16 DFFs ≈ +420 µm² (4 %) |
| MAC pipeline latency | 1 cycle | 2 cycles |
| Steady-state throughput | 1 MAC/cycle/PE | 1 MAC/cycle/PE (unchanged) |

The latency cost is amortized in any dot product of meaningful length
— a typical attention tile_k is 64, so the +1 cycle is <2 % overhead.
Steady-state throughput is unaffected.

This change is gated on M3 sign-off. Done now, it invalidates the
in-flight phobos Genus sweep (which is on the pre-pipeline RTL); we'd
need to re-run Phase 1. Decision: **complete the current sweep first**
to get the pre-pipeline baseline curve, then apply the pipeline change
and re-sweep Phase 1 to quantify the improvement.

## 4. Synthesis methodology

Two independent tool flows, used for different purposes:

### 4.1 OpenLane 2 (Sky130A) — cross-PDK validation

- **Purpose:** confirm the design synthesizes cleanly through a fully
  open flow and produces a real GDS. Provides a cross-check that the
  Genus results aren't PDK artifacts.
- **Scope:** one or two leaf blocks per pass. See §5 for proof points.
- **Tool ceiling:** ~50 K cells before runtime exceeds 1 h; multi-MB
  cell counts push into days and risk OOMing the WSL2 VM.

### 4.2 Cadence Genus (SAED32 RVT TT @ 0.85 V, 25 °C) — sweep

- **Purpose:** generate area/timing/power per N for every block, fit
  `area(N) = a + b·N² + c·N`, extrapolate to N=64 chip rollup.
- **Scope:** 17+ leaf-block sweep points (Phase 1 systolic, Phase 2
  fusion leaves, Phase 2b/2c size sweeps, Phase 3 stream_pipeline).
- **Tool ceiling:** Genus handles individual leaves up to ~10 M gates
  on phobos's 64 GB. The flat top-level netlist (`accel_top`) hits
  ~33 M gates and OOMs — the project README explicitly documents
  this. Leaf-block synthesis is the only path that fits.
- **In-flight status:** Phase 1 complete (`sys_1x1` through
  `sys_32x32`). Latest session at ~30 h wall-clock, currently
  somewhere in Phase 2.

## 5. Proof points — what to synthesize, where

| Block | Size | Tool | Cells (est.) | Wall-clock | Purpose |
|---|---|---|---:|---|---|
| `mac_pe` | 1 PE | OpenLane ✅ done | 1,482 | ~15 min | per-PE baseline + violations |
| `systolic_array_64x64` | N=4 (16 PEs) | OpenLane | ~25 K | ~45 min | within tool limits; cross-check against Genus `sys_4x4` |
| `systolic_array_64x64` | N=1..32 | Genus ✅/⏳ | 1.5 K – 1.6 M | minutes – 2 h each | per-N area curve for the rollup |
| `softmax_unit` | VEC_LEN=1..32 | Genus ⏳ | up to ~1 M | minutes – hours each | per-N area curve (phase2c) |
| `tile_buffer` | TILE_DIM=1..32 × ports | Genus ⏳ | up to ~700 K | minutes – 1 h | per-N area curve (phase2b) |
| `stream_pipeline` | ARRAY_DIM=1..32 | Genus ⏳ | up to ~3 M | minutes – 3 h each | integrated cross-check (phase3) |
| `accel_engine` | 1 lane, default | — | ~5 M | weeks if anything works | not feasible in either tool flat |
| `accel_top` / `compute_core` | full chip | — | ~80 M | impossible | both tools OOM; extrapolate, don't synthesize |

**OpenLane next step:** synthesize `systolic_array_64x64` at **N=4**
to get a single 16-PE point that's directly comparable to the Genus
`sys_4x4` measurement. Cross-tool ratio at the same N validates the
sweep extrapolation.

**Phobos next steps:** finish phase2 (fusion leaves + `tile_buffer`
defaults), then phase2b (TILE_DIM sweep), phase2c (softmax/adder
sweep), then phase3 (stream_pipeline sweep). Existing transcript in
[`error.txt`](error.txt) shows progress.

## 6. Chip rollup math

Given measured per-block area curves `area_block(N)`, the chip-level
area at a chosen N is:

```
area_chip(N) = N_LANES × [ area_systolic(N) + area_stream_glue(N)
                         + area_softmax(N) + area_tile_buffer(N, NUM_RD_PORTS=N)
                         + area_fused_postproc + area_controller + area_perf
                         + 3 × area_tile_buffer(N, NUM_RD_PORTS=1) ]   ← A/B/aux
             + area_dispatcher + area_dma + area_csr
             + interconnect_overhead (×1.15 to ×1.30)
```

For the chip target N=64, every `area_block(N)` is evaluated at the
fitted curve. Scalar leaves (gelu, divider, fpp, controller) are
constants. `stream_pipeline` provides an integrated cross-check:

```
area_stream(N) ≈ area_systolic(N) + area_softmax(N) + area_stream_glue(N)
```

If the curve-sum matches the integrated stream measurement, the
rollup math is sound.

Implementation: [`RTL/analyze_sweep.py`](RTL/analyze_sweep.py).

## 7. Tool ceilings — what's really limiting

### 7.1 Phobos (Cadence Genus 21.12 on SAED32)

- 64 GB RAM, 4 worker threads (set in
  [`RTL/run_genus_sweep.do`](RTL/run_genus_sweep.do) — higher counts
  COW-balloon peak memory).
- Leaf blocks up to ~10 M gates fit. `accel_top` flat at ~33 M gates
  OOMs.
- CAT-team policy: per-process memory cap and total session wall-clock
  cap (we've been hit twice now mid-sweep, most recently at
  `fused_postproc_unit`). Workaround: `ABORT_ON_FAIL=0` and chunked
  re-runs.
- **Practical guidance:** never try to synthesize `accel_top` or
  `compute_core` flat. Always go leaf-by-leaf and roll up.

### 7.2 OpenLane 2 / Sky130A (WSL2 on a workstation)

- WSL2 VM defaults to half the host RAM. Single-threaded routing
  through OpenROAD.
- Comfortable: <50 K cells in ~1 h.
- Painful: 50 K – 500 K cells in many hours.
- Unrealistic: >1 M cells (days; intermittent failures).
- Sky130 SS corner is unusually pessimistic (12 % undervolt, 100 °C,
  slow process variant) — first-pass designs commonly miss it.

## 8. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phobos kills sweep mid-run again | high | adds days | `ABORT_ON_FAIL=0`; tmux session; partial restart from last DONE point |
| Pipeline change introduces a functional regression | low | invalidates testbenches | re-run [`RTL/run.do`](RTL/run.do) (7 TBs) after the RTL edit before re-synth |
| OpenLane N=4 systolic doesn't close at 10 ns | medium | need a tighter clock target or pipeline | start at 15 ns; tighten incrementally |
| Genus area curve doesn't fit `a + b·N² + c·N` well | low | rollup error bars grow | report R² and a bootstrap CI; cross-check against stream_pipeline integrated point |
| 178 W chip-scale power exceeds chiplet thermal budget | high (Sky130), medium (SAED32) | spec change | not in M3 scope; flagged for M4 — clock gating + DVFS plan |

## 9. Schedule

| Date | Deliverable |
|---|---|
| 2026-05-17 | OpenLane `mac_pe` done; CF07 submitted |
| 2026-05-18 to 19 | Phobos sweep completes (or selectively re-runs); CSV regenerated |
| 2026-05-20 | OpenLane on `systolic_array_64x64` at N=4 (cross-check) |
| 2026-05-21 | Pipeline `mac_pe.sv`; re-run testbenches; re-run Phase 1 sweep |
| 2026-05-22 | `analyze_sweep.py` final rollup; update `timing_analysis.md` |
| 2026-05-23 | M3 deliverable writeup |
| 2026-05-24 | M3 due |

## 10. Out of scope for M3 (M4 follow-on)

- Clock gating wired into `accel_engine` (needed for the 178 W power
  budget at chip scale — not a synthesis issue, an architecture
  issue).
- Per-tile DVFS controller.
- DRAM/HBM interface (currently we have a stub DMA + scratchpad).
- INT8 weight-only quantization (vs current INT8-symmetric on both
  operands) for further multiplier-area reduction.
- Post-route static IR drop analysis (OpenLane's pass is approximate).
