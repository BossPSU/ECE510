# Synthesis Sweep Plan — Systolic Array & Fusion Characterization

## Motivation

The single-MAC synthesis (one `mac_pe` = 2,180 cells in SAED32) is too thin a
basis for chip-level extrapolation. Multiplying by 65,536 ignores three real
effects:

1. **Wiring overhead** — grows with array size, not captured at N=1
2. **Edge effects** — boundary PEs differ from interior PEs
3. **Fusion overhead** — the activation pathway and stream_pipeline glue around
   the systolic array

This sweep collects measured data across multiple array sizes and the surrounding
fusion blocks, fits a scaling curve with confidence bounds, and produces
defensible engine- and chip-area estimates with stated uncertainty rather than
a single multiplication.

---

## Phases

### Phase 1 — Systolic-array size sweep

Use `elaborate -parameters {ROWS N COLS N}` to override the array dimensions on
`systolic_array_64x64.sv`. Five data points:

| Size  | PEs   | Expected cells | Expected RAM | Expected time | Phobos fit |
|-------|-------|----------------|--------------|---------------|------------|
| 1×1   | 1     | ~2,180         | <1 GB        | 1 min         | done       |
| 2×2   | 4     | ~9 K           | <1 GB        | 1 min         | yes        |
| 4×4   | 16    | ~36 K          | ~1 GB        | 2 min         | yes        |
| 8×8   | 64    | ~140 K         | ~3 GB        | 5–10 min      | yes        |
| 16×16 | 256   | ~580 K         | ~10 GB       | 20–40 min     | yes        |
| 32×32 | 1,024 | ~2.3 M         | ~30 GB       | 1–2 hr        | borderline |
| 64×64 | 4,096 | ~9 M           | 60+ GB       | many hr       | no (matches partition 13 in error.txt) |

Top out at 32×32 reliably. Six data points across two decades of N² is enough
to fit a curve with real confidence intervals.

**Per-point output:** `area.rpt`, `timing.rpt`, `power.rpt`, gate-level netlist.

**Derived metrics:**
```
per_PE_area(N)        = total_area(N) / N²
scaling_exponent      = log(area(N₂)/area(N₁)) / log(N₂² / N₁²)
overhead_fraction(N)  = (total(N) − N² × per_PE(1)) / total(N)
```

### Phase 2 — Fusion-component characterization

Block-level synthesis of every leaf module reachable from `accel_engine`. Each
runs in <5 min, total Phase-2 wall time ~30 min.

| Block | Per-engine count | Why it matters |
|---|---|---|
| `gelu_unit` | 1 | Forward FFN activation |
| `gelu_grad_unit` | 1 | Backward FFN |
| `softmax_unit` (VEC_LEN=64) | 1 | Attention path |
| `causal_mask_unit` | 1 | Attention mask |
| `divider_or_reciprocal_unit` | inside softmax | Per-block size breakdown |
| `adder_tree` (64-input) | inside softmax | Per-block size breakdown |
| `fused_postproc_unit` | 1 | Integrated activation MUX (wraps the above) |
| `accel_controller` | 1 | FSM |
| `perf_counter_block` | 1 | Near zero, sanity check |
| `tile_buffer` `NUM_RD_PORTS=1` | 3 | A, B, aux buffers |
| `tile_buffer` `NUM_RD_PORTS=64` | 1 | Output buffer (the costly one) |

### Phase 3 — Stream-pipeline scaling sweep

Same size sweep as Phase 1, but on `stream_pipeline.sv` (which instantiates the
systolic array + fused_postproc + feed/drain glue). The **difference** between
stream_pipeline area and (systolic + fusion-blocks) area at each N tells you
the glue cost:

```
glue_area(N) = stream_pipeline_area(N)
             − N² × per_PE_area
             − fused_postproc_area
             − activation_block_areas
```

Glue should be **roughly constant** as N grows (boundary feeders / drains, not
per-PE replicated logic). If it grows with N, the glue architecture has poor
scaling and is a real refactoring target.

### Phase 4 — Extrapolation with confidence bounds

Fit:
```
area(N) = a + b·N² + c·N
         (constant + per-PE quadratic + boundary linear)
```

Use Phases 1 and 3 points to fit (a, b, c) by least-squares. Then **predict**
the 64×64 area. Compare against naive single-MAC × 4096:

- Within 10% → naive napkin math is fine
- 10–30% off → use curve-fit for the writeup
- 30%+ off → the single-MAC number is misleading; document why

Chain to engine and chip level:
```
engine_area ≈ stream_pipeline(64×64)
            + accel_controller
            + 4 × tile_buffer_small
            + 1 × tile_buffer_big
            + perf_counter_block
            + 15–30% interconnect overhead

chip_area  ≈ 16 × engine_area
           + tile_dispatcher
           + DMA engine
           + scratchpad SRAM macros
```

Report final number with explicit ±X mm² uncertainty band, not a single midpoint.

---

## Mechanics

### `run_genus_sweep.do` (new script, takes env vars)

```tcl
set TOP $env(SYNTH_TOP)            ;# systolic_array_64x64 | stream_pipeline | <block>
set N   $env(ARRAY_N)              ;# 2, 4, 8, 16, 32  (ignored for blocks)

# ... library setup, read_hdl as in existing run_genus.do ...

if { $TOP eq "systolic_array_64x64" } {
    elaborate $TOP -parameters [list ROWS $N COLS $N]
} elseif { $TOP eq "stream_pipeline" } {
    elaborate $TOP -parameters [list ARRAY_DIM $N]
} else {
    elaborate $TOP                                   ;# leaf blocks, no override
}

# ... constraints, syn_generic, syn_map, syn_opt ...

set outdir out_sweep/${TOP}_${N}x${N}
file mkdir $outdir/reports
report_area  > $outdir/reports/area.rpt
report_timing -max_paths 10 > $outdir/reports/timing.rpt
report_power > $outdir/reports/power.rpt
write_hdl    > $outdir/$TOP.v
```

### `run_sweep.sh` (driver)

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"

# Phase 1: systolic array sweep
for N in 2 4 8 16 32; do
    SYNTH_TOP=systolic_array_64x64 ARRAY_N=$N \
        genus -files run_genus_sweep.do -log systolic_${N}x${N}.log
done

# Phase 2: fusion components (single run each)
for top in gelu_unit gelu_grad_unit softmax_unit causal_mask_unit \
           divider_or_reciprocal_unit adder_tree fused_postproc_unit \
           accel_controller perf_counter_block; do
    SYNTH_TOP=$top ARRAY_N=1 \
        genus -files run_genus_sweep.do -log ${top}.log
done

# Phase 3: stream_pipeline sweep
for N in 2 4 8 16 32; do
    SYNTH_TOP=stream_pipeline ARRAY_N=$N \
        genus -files run_genus_sweep.do -log stream_${N}x${N}.log
done
```

### `sweep_results.csv` (collected output)

```csv
top,N,PEs,total_cells,total_area_um2,WNS_ps,leakage_W,dynamic_W,peak_RAM_GB,wall_time_min
systolic_array_64x64,1,1,2180,4900,-631,0.0001,0.0008,0.8,1
systolic_array_64x64,2,4,...
...
fused_postproc_unit,1,1,...
stream_pipeline,2,4,...
...
```

Extract with `grep`/`awk` over each `area.rpt` and `timing.rpt`.

### `analyze_sweep.py` (~20-line Python)

- Load CSV
- Compute per-PE area, scaling exponent, glue residual
- Fit `area(N) = a + b·N² + c·N` via `numpy.polyfit` or `scipy.optimize.curve_fit`
- Plot area-vs-N² with linear extrapolation line + 95% confidence band
- Output one figure per metric for the M3 writeup

---

## Time and resource budget

| Phase | Genus runs | Wall time (serial) | Peak memory per run |
|---|---|---|---|
| 1. Systolic sweep | 5 | ~3–4 hr | <30 GB (max at 32×32) |
| 2. Fusion components | 9 | ~45 min | <1 GB each |
| 3. Stream-pipeline sweep | 5 | ~6–8 hr | <40 GB (max at 32×32) |
| 4. Analysis + plotting | — | 1 day | trivial |

**Total ≈10–15 hr of Genus time**, spread across two days. Every individual run
is under 2 hours wall time and under 40 GB peak memory — **comfortably below
CAT's runaway thresholds**. No coordination with CAT-team required.

---

## Deliverables

1. **`run_genus_sweep.do`** — parameterized synthesis driver
2. **`run_sweep.sh`** — shell loop runner
3. **`sweep_results.csv`** — collected raw data
4. **`analyze_sweep.py`** — fit + plot
5. **`sweep_figure.pdf`** — area vs N² with extrapolation + uncertainty band
6. **M3 writeup paragraph** with measurement-backed chip-area estimate and
   stated ±X mm² confidence

---

## What this buys the M3 writeup

Replaces

> *"We synthesized one MAC and multiplied by 65,536."*

with

> *"We characterized the systolic array at five sizes spanning 1× to 1024× scale,
> fit a quadratic-plus-linear area model with 95% confidence bands, and
> separately measured the fusion pathway and stream-pipeline glue overhead.
> The full 64×64 systolic array projects to A ± B mm² in SAED32. The fusion
> overhead is C% of engine area, independent of array size. Per-PE area
> asymptotes to D cells at large N (compared to the standalone single-PE
> value of 2,180 cells), reflecting Y% wiring overhead in context."*

That's an engineering claim with measurement-backed uncertainty, not a
multiplication. Same Genus budget as the single-MAC run, ~10× the analytical
value, and tells you whether the napkin math was an overestimate or an
underestimate — which is itself a useful number to publish.

---

## Risks and caveats

- **Parameter override might fail** on some modules if they hard-code dimensions
  internally. Verify `systolic_array_64x64.sv` and `stream_pipeline.sv` accept
  clean `-parameters` overrides before launching the sweep. If not, fall back
  to editing `accel_pkg.sv` between runs (uglier but works).
- **Genus 21.12 PBS** kicks in at >100K instances per partition. Below that
  threshold, runs are single-threaded — fine for our small array sizes.
- **Routing/parasitic effects** that show up at place-and-route are NOT
  captured by synthesis-only data. The fit predicts *standard-cell area*, not
  post-route die area. Add ~15-30% interconnect overhead in the chip-area
  rollup or note it as an unmeasured term.
- The 32×32 stream_pipeline run is the riskiest single point — ~40 GB peak
  memory predicted. If it OOMs, drop to 16×16 as the largest data point. The
  fit still works with 5 points instead of 6.
