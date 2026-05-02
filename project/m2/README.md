# M2 — Reproduce the Simulations

Two top-level deliverables live under [`rtl/`](rtl/): the synthesizable
**`compute_core.sv`** (16-lane fused transformer accelerator) and
**`interface.sv`** (UCIe-style host link). Each has a self-checking
testbench under [`tb/`](tb/) that prints an explicit
`TB_<NAME>: PASS` or `FAIL` line on a final summary.

## Tool versions

| Tool | Version | Notes |
|---|---|---|
| QuestaSim | **2021.3_1** | `vlog`/`vsim`; SystemVerilog 2017 |
| Python | 3.8+ | optional, for `precision_analysis.py` |

A SystemVerilog-2017-aware simulator (Verilator ≥ 5.0, Icarus ≥ 12, VCS ≥
2020.03) should also accept the design — the only QuestaSim-specific bits
are the `transcript file` and `vsim -onfinish stop` directives in the
`.do` scripts; replace those with your simulator's equivalents.

## Reproduce both testbenches

From a fresh clone, in the `project/m2/sim/` directory:

```sh
cd project/m2/sim

# Compute core: full RTL stack + 4-test smoke suite
vsim -do run_compute_core.do
# -> writes compute_core_run.log

# Interface: minimal protocol-layer DUT + 4 protocol checks
vsim -do run_interface.do
# -> writes interface_run.log
```

Each `.do` script:
1. wipes and recreates the `work` library
2. compiles every dependency from `m2/rtl/` in correct order
3. compiles the matching testbench from `m2/tb/`
4. runs `vsim` with `-onfinish stop` and `run -all`
5. transcripts everything to a `.log` file in this directory

To grep the result:

```sh
grep -E '^=== TB_(COMPUTE_CORE|INTERFACE):' compute_core_run.log interface_run.log
```

You should see exactly one `: PASS` line per file.

### Generating the waveform image

`run_compute_core.do` already sources [`wave.do`](sim/wave.do) **before**
`run -all`, so signal traces are recorded during the run and the wave
window is fully populated when the sim finishes. After
`=== TB_COMPUTE_CORE: PASS ===` appears in the transcript:

1. The wave window already shows top-level handshake, DMA traffic,
   lane-0 pipeline internals (`pipeline_start/done/running_o`, feed/out
   activity, output write bus), the controller FSM state, and perf
   counters, zoomed to the Test 1 window (0–150 ns).
2. From the menu: **File → Export → Image…**, save as
   `project/m2/sim/waveform.png`.

If you need to re-add the signals manually, do it BEFORE `run -all` —
after `$finish` the design hierarchy is unloaded and `add wave` will
report "No objects found matching …".

## What each testbench covers

### `tb_compute_core.sv` (driving `compute_core`)

Four sub-tests, each with an inline golden model written in SV `real`:
1. **FFN forward** — 2×2 GEMM + GELU, compares all 4 outputs to the
   reference. Independent: golden uses `$tanh()` and FP arithmetic.
2. **FFN backward** — fused `(A·B)·GELU′(h_pre)` with a separate
   pre-activation buffer; verifies all 4 elements within 10% tolerance.
3. **Attention** — softmax over a 2-element row, verifies row sums to 1.
4. **Multi-tile** — issues a 2-tile macro_cmd; lane 0 and lane 1 run
   concurrently; both tiles' outputs are checked against golden.

### `tb_interface.sv` (driving `chiplet_interface`)

Four protocol checks:
1. **Command channel**: drives a packed `macro_cmd_t`, verifies all 10
   fields unpack correctly on the core side.
2. **Write transaction**: full `ucie_wr_valid → ucie_wr_ready` handshake
   with `{addr, data}` packing; checks address and data forwarding.
3. **Read transaction**: full request/response with mock scratchpad
   data; verifies pass-through.
4. **Status pass-through**: `core_busy / core_irq` → `ucie_busy / ucie_irq`
   in both directions.

## Independent precision study

```sh
python3 project/m2/sim/precision_analysis.py > project/m2/sim/precision_results.txt
```

Drives 100 random samples per kernel (GEMM, GELU, GELU′, softmax) through
an FP32 reference and a bit-accurate Q16.16 model, reports MAE / max
error / mean relative error. Numbers are quoted in
[`precision.md`](precision.md). Seed is `0xECE510` — fully reproducible.

## Deviations from the M1 plan

The M1 selection (`project/m1/interface_selection.md`) called for **UCIe
x16 standard package, 16 GT/s**, with an unspecified internal
microarchitecture. M2 made these architectural decisions on top of that:

- **N_LANES = 16** compute lanes, each a 64×64 systolic array (matches
  the UCIe BW/compute ratio analyzed in the M1 roofline notes).
- **Per-lane tile slots**: each lane bank holds N_SLOTS = 2 disjoint
  tile working sets so multi-tile macros don't alias. Static round-robin
  dispatch (`tile_idx mod N_LANES`).
- **DMA address width** widened from 16 to 19 bits to address all (lane,
  slot, offset) combinations cleanly. M1's interface block diagram
  showed an abstract address bus; this is the concrete pin count.
- **Numerical format** is **Q16.16** (the M1 `precision` placeholder
  said "fixed-point or bf16, TBD"; M2 commits to Q16.16 — see
  `precision.md` for the full justification).
- **Intra-tile fusion**: matmul + activation share one autonomous
  streaming pipeline with no SRAM round-trip for intermediates. M1
  showed these as separate units; M2 fused them at RTL level.

No protocol change. No kernel-scope change.

## Repository layout (M2 only — see project root for M1)

```
project/m2/
├── rtl/
│   ├── compute_core.sv         <- top-level compute core (wraps accel_top)
│   ├── interface.sv            <- top-level UCIe interface (chiplet_interface)
│   └── *.sv, *.mem             <- 39 supporting modules + 2 ROM init files
├── tb/
│   ├── tb_compute_core.sv      <- 4-test smoke suite, prints PASS/FAIL
│   └── tb_interface.sv         <- 4 protocol checks, prints PASS/FAIL
├── sim/
│   ├── run_compute_core.do     <- QuestaSim driver script
│   ├── run_interface.do        <- QuestaSim driver script
│   ├── precision_analysis.py   <- Q16.16 vs FP32 study (100 samples)
│   ├── precision_results.txt   <- last-run output of the script
│   ├── compute_core_run.log    <- vsim transcript with PASS line
│   ├── interface_run.log       <- vsim transcript with PASS line
│   └── waveform.png            <- representative pipeline activity
├── precision.md                <- numeric format choice + error analysis
└── README.md                   <- this file
```
