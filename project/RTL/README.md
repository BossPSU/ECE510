# project/RTL — M3 preparation workspace

This directory is the working RTL for **M3 mixed-precision research**.
It is **separate from the M2 deliverable** under [`project/m2/`](../m2/),
which freezes the pure Q16.16 baseline used in the M2 simulation and
synthesis writeups. Changes here are exploratory and may be ported into
the M2 tree only after they are characterized.

The current focus is **NVFP4-style mixed precision in the systolic
MAC** — Q4.4 multiplier inputs feeding a Q16.16 accumulator. The
multiplier shrinks ~16× (area scales as O(MULT_W²)) while the
accumulator keeps full headroom for long dot products.

## Tool versions

| Tool | Version | Notes |
|---|---|---|
| QuestaSim | **2021.3_1** | `vlog`/`vsim`; SystemVerilog 2017 |
| Cadence Genus | **21.12-s068_1** | from `cadence-2022-09` on phobos |
| Std-cell lib | **Synopsys SAED32 EDK** | RVT, TT corner @ 0.85 V / 25°C |

## Mixed-precision MAC

### What changed

The systolic MAC PE ([`mac_pe.sv`](mac_pe.sv)) used to do a full
32×32 → 64-bit signed multiply, then truncate the middle 32 bits to
Q16.16 before accumulating. The new flow:

1. **Quantize** each Q16.16 operand to **Q4.4** (8-bit signed) at the
   multiplier input, with saturation to ±7.9375 / −8.0.
2. **Multiply** Q4.4 × Q4.4 → 16-bit Q8.8 (an 8×8 signed mul, ~16×
   smaller than the original 32×32).
3. **Promote** the Q8.8 product to Q16.16 (sign-extend + shift left 8)
   and add to the Q16.16 accumulator. The accumulator path is
   unchanged — full headroom across long dot products.

All knobs live in [`accel_pkg.sv`](accel_pkg.sv):

| Param | Value | Meaning |
|---|---|---|
| `MULT_W` | 8 | Multiplier-input bit width |
| `MULT_INT` / `MULT_FRAC` | 4 / 4 | Q4.4 split |
| `Q44_ALIGN_SH` | 12 | Right-shift for Q16.16 → Q4.4 |
| `Q88_PROMOTE_SH` | 8 | Left-shift for Q8.8 → Q16.16 |
| `Q44_MAX_Q16` / `Q44_MIN_Q16` | +7.9375 / −8.0 in Q16.16 | Sat bounds |

Forwarded operands (`a_out`, `b_out`) **stay at Q16.16** — the systolic
feed and any inter-PE plumbing are unaffected. Only the multiplier
shrinks.

### What did not change

The activation pathway is still full Q16.16:

- `gelu_unit.sv`, `gelu_grad_unit.sv` — internal multipliers untouched
- `softmax_unit.sv` — exp LUT + reciprocal still 32-bit
- `fused_postproc_unit.sv` — Q16.16 throughout
- `divider_or_reciprocal_unit.sv` — Q16.16

Precision reduction is intentionally limited to the systolic-array MAC
because that's where 4096 multipliers × 16 lanes = **65,536 multipliers**
dominate area. Activations are tiny by comparison (~64 per cycle) and
benefit from full precision for `exp`, `tanh` and `1/x`.

## Reproduce the simulations

```sh
cd project/RTL
vsim -do run.do
```

The script:

1. Wipes and recreates the `work` library (`catch {vdel}` + `file
   delete -force` to handle stale `work/` dirs).
2. Compiles every `.sv` in dependency order — 39 RTL modules + 7
   testbenches.
3. Runs each testbench with `vsim -voptargs="+acc" -onfinish stop` so
   signals stay visible to `add wave` / `examine` after vopt.
4. Transcripts everything to `tb_results.log`.

To grep the result:

```sh
grep -E 'PASS|FAIL|ERROR|RESULT' tb_results.log
```

You should see **0 FAIL / 0 ERROR**, with seven `RESULT: tb_*
COMPLETED` lines.

### Last verified run (2026-05-11, QuestaSim 2021.3_1)

| Testbench | Result | Notes |
|---|---|---|
| `tb_mac_pe` | 5/5 PASS | in-range MAC, ±saturation, Q4.4-exact small product, `clear_acc` |
| `tb_causal_mask` | 3/3 PASS | row 0/2/3 masking |
| `tb_gelu_unit` | 8/8 PASS | GELU(x) for x ∈ {−2, −1, −0.5, 0, 0.5, 1, 2, 3} |
| `tb_softmax_unit` | 2/2 PASS | row sums to 1.0000, monotonic |
| `tb_systolic_array` | **16/16 PASS exactly** | rescaled `A_mat` to Q4.4-exact range, bit-identical to golden |
| `tb_fused_postproc` | 3/3 PASS | bypass, GELU fwd, GELU grad |
| `tb_accel_top` | **4/4 PASS** | Tests 1, 3, 4 are bit-exact to golden; Test 2 within 10% tolerance |

The Q4.4 multiplier is **lossless** when operands fit the Q4.4 grid
(multiples of 0.0625 in [−8, +7.9375]). Tests 1, 3, 4 of
`tb_accel_top` and all 16 elements of `tb_systolic_array` confirm this.
Test 2's small residuals are from the `gelu_grad_unit` Padé tanh
approximation — unrelated to the multiplier change.

## Synthesis (Cadence Genus, SAED32 EDK)

Per-block synthesis script: [`run_genus.do`](run_genus.do). Targets
the new mixed-precision `mac_pe` by default, since that's the block
where the precision change actually does something. Bottom-up area
estimate for the full chip:

```
chip_area  ≈  N_LANES × ( ARRAY_ROWS × ARRAY_COLS × mac_pe
                        + 1 × accel_controller
                        + 1 × fused_postproc_unit
                        + 4 × tile_buffer
                        + 1 × perf_counter_block )
            + tile_dispatcher + DMA engine + scratchpad SRAM
            ≈  16 × ( 4096 × mac_pe + ... ) + ...
```

Run on phobos (PSU ECE) after enabling `cadence-2022-09`:

```sh
cd project/RTL
genus -files run_genus.do -log mac_pe.log
```

Default `LIB_PATH` is the SAED32 RVT TT corner library at
`/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm`.
Override via `LIB_PATH=…` env var to point at another PDK.

Outputs land in `out_block/<TOP>/`:
- `<TOP>.v` — gate-level netlist
- `<TOP>.sdc` — forward constraints
- `reports/area.rpt` — hierarchical area
- `reports/timing.rpt` — worst-case path at 1 GHz
- `reports/power.rpt` — dynamic + leakage power
- `reports/area_hier.rpt` — per-sub-block breakdown

To synthesize a different leaf block:

```sh
SYNTH_TOP=accel_controller    genus -files run_genus.do -log ctrl.log
SYNTH_TOP=gelu_unit           genus -files run_genus.do -log gelu.log
SYNTH_TOP=fused_postproc_unit genus -files run_genus.do -log fpp.log
SYNTH_TOP=softmax_unit        genus -files run_genus.do -log sm.log
SYNTH_TOP=perf_counter_block  genus -files run_genus.do -log perf.log
```

The full accelerator (`accel_top`) and even a single lane
(`accel_engine`) OOM on phobos's 64 GB during partition-based
synthesis because the flat netlist hits ~33 M generic gates. Leaf
block synthesis is the only path that reliably fits.

### Characterization sweep (M3)

For a higher-confidence chip-area estimate than naive
single-MAC × 65,536, the sweep workflow in
[`Claude_sweep.md`](Claude_sweep.md) synthesizes the systolic array
and `stream_pipeline` at several sizes (N ∈ {1, 2, 4, 8, 16, 32}),
plus every fusion leaf block, then fits `area(N) = a + b·N² + c·N`
and extrapolates to 64×64 with a confidence band.

Files:
- [`run_genus_sweep.do`](run_genus_sweep.do) — parameterized Genus
  driver (takes `SYNTH_TOP`, `ARRAY_N`, `BUF_NRD` env vars; writes
  to `out_sweep/<tag>/`).
- [`run_sweep.sh`](run_sweep.sh) — phobos shell driver:
  `./run_sweep.sh [all|phase1|phase2|phase3|point <top> [n]]`.
- [`collect_sweep_csv.py`](collect_sweep_csv.py) — walks
  `out_sweep/*/reports/` and emits `sweep_results.csv`.
- [`analyze_sweep.py`](analyze_sweep.py) — fits the curve, prints
  `sweep_metrics.txt`, plots `sweep_figure.pdf`.

Run end-to-end on phobos:

```sh
addpkg -l cadence-2022-09       # enable Genus on PATH (per shell)
cd project/RTL
chmod +x run_sweep.sh           # one-time: git on Windows drops the +x bit
./run_sweep.sh                  # ~10-15 hr wall time (serial)
python3 collect_sweep_csv.py    # -> sweep_results.csv
python3 analyze_sweep.py        # -> sweep_metrics.txt, sweep_figure.pdf
```

- `addpkg -l cadence-2022-09` only lasts for the current shell — re-run
  it in any new terminal before `genus` is callable.
- `chmod +x` is sticky once set, but re-apply if `./run_sweep.sh` ever
  reports "Permission denied" after a fresh `git pull`.
- The driver tees a combined transcript to `logs_sweep/sweep_all.log`
  and a per-point log to `logs_sweep/<tag>.log`. From a second shell,
  `tail -f logs_sweep/sweep_all.log` to watch progress live.

Every individual Genus run is under 2 hr wall time and under 40 GB
peak memory — comfortably below CAT-team admin thresholds.

## File map

```
project/RTL/
├── accel_pkg.sv             <- package: parameters + Q16.16 helpers
│                               (now includes Q4.4 multiplier params)
├── mac_pe.sv                <- mixed-precision MAC (Q4.4 mul + Q16.16 acc)
├── *.sv                     <- 38 other RTL modules (unchanged from M2)
├── tb_mac_pe.sv             <- MAC PE TB with saturation + Q4.4 tests
├── tb_systolic_array.sv     <- 4x4 systolic, A_mat scaled to Q4.4 range
├── tb_accel_top.sv          <- top-level FFN/attention TBs, operands rescaled
├── tb_*.sv                  <- 4 other module TBs (unchanged)
├── run.do                   <- QuestaSim driver: compile + run all 7 TBs
├── run_genus.do             <- Cadence Genus driver: per-block synthesis
├── tb_results.log           <- last QuestaSim transcript
└── README.md                <- this file
```

## Why this is staged outside M2

M2's deliverable is a frozen Q16.16 design with documented precision
analysis ([`project/m2/precision.md`](../m2/precision.md)). Moving the
M2 RTL to Q4.4 would invalidate the precision study and the simulation
log committed for the milestone. M3 starts from this RTL workspace,
keeps the architectural changes here, and ports forward into a fresh
M3 deliverable directory once the design is fully characterized
(area, timing, power, accuracy on at least one transformer-sized
benchmark).
