# M2 — Reproduce the Simulations

> **Filename deviations from the spec (acknowledged):** the
> representative waveform image is split across `sim/waveform1.png`
> and `sim/waveform2.png` instead of a single `sim/waveform.png` — see
> the [Generating the waveform image](#generating-the-waveform-image-committed-as-waveform1png--waveform2png)
> section for the rationale. Also, the top module inside
> `interface.sv` is named `chiplet_interface` (since `interface` is a
> SystemVerilog reserved word). Both deviations are documented in
> [Filename deviations](#filename-deviations) further down.

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

### Generating the waveform image — committed as `waveform1.png` + `waveform2.png`

> **Filename deviation from the M2 spec (acknowledged):** the checklist
> calls for a single `waveform.png`. This design exposes 5 signal groups
> (Top, DMA, Lane0 pipe, Lane0 FSM, Perf) totalling ~30 traces, and at
> a legible row height they will not all fit in one screenshot on a
> standard display. The waveform is therefore split into **two
> annotated images** that together cover the full set:
>
> - **`sim/waveform1.png`** — Top-level host handshake + DMA traffic +
>   Lane 0 streaming pipeline internals (the "what's the chiplet
>   doing" view).
> - **`sim/waveform2.png`** — Lane 0 controller FSM state + perf
>   counters (the "LOAD → STREAM → WRITE phases + cycle accounting"
>   view).
>
> Both PNGs come from the same simulation run; together they show
> input application, internal pipeline activity, and output capture
> for the test vectors. The grader confirmed small filename
> deviations are fine if documented — this note is that documentation.

`run_compute_core.do` already sources [`wave.do`](sim/wave.do) **before**
`run -all`, so signal traces are recorded during the run and the wave
window is fully populated when the sim finishes. After
`=== TB_COMPUTE_CORE: PASS ===` appears in the transcript:

1. The wave window already shows top-level handshake, DMA traffic,
   lane-0 pipeline internals (`pipeline_start/done/running_o`, feed/out
   activity, output write bus), the controller FSM state, and perf
   counters, zoomed to the Test 1 window (0–150 ns).
2. Collapse / expand groups to taste, then **File → Export → Image…**
   for each captured view. Save as
   `project/m2/sim/waveform1.png` and `project/m2/sim/waveform2.png`.

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

### Filename deviations

- **`waveform.png` → `waveform1.png` + `waveform2.png`.** The single
  representative image required by the checklist could not legibly fit
  ~30 traces across 5 signal groups on one display, so the waveform is
  split into two annotated screenshots from the **same** simulation
  run. See the *Generating the waveform image* section above for what
  each one shows. Per grader confirmation, small documented deviations
  are acceptable.
- **`module interface` → `module chiplet_interface`** inside
  `interface.sv`. SystemVerilog reserves `interface` as a keyword, so
  the file's top module is named `chiplet_interface`. The filename
  itself still matches the checklist exactly. Documented in the
  `interface.sv` header.

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
│   ├── waveform1.png           <- Top + DMA + Lane0 pipe (see deviation note)
│   └── waveform2.png           <- Lane0 FSM + Perf (companion view)
├── precision.md                <- numeric format choice + error analysis
└── README.md                   <- this file
```

## Supporting RTL files

Beyond the two top-level deliverables (`compute_core.sv`, `interface.sv`),
[`rtl/`](rtl/) contains 39 supporting SystemVerilog files plus 2 ROM
init files. Grouped by role:

### Package and shared types

| File | Description |
|---|---|
| [`accel_pkg.sv`](rtl/accel_pkg.sv) | Global parameter package — Q16.16 constants, array dims (64×64), tile sizes, model dims (D_MODEL, D_FF, SEQ_LEN), enums (`mode_t`, `fused_op_t`), and `cmd_pkt_t` / `macro_cmd_t` typedefs. Imported by every other file. |

### Top-of-hierarchy wrappers

| File | Description |
|---|---|
| [`accel_chiplet_wrapper.sv`](rtl/accel_chiplet_wrapper.sv) | Outer chiplet wrapper. Models the UCIe-style host link (cmd / wr / rd / status channels) on the outside and instantiates `accel_top` on the inside. Used as a reference UCIe binding before `interface.sv` was split out as the M2 deliverable. |
| [`accel_top.sv`](rtl/accel_top.sv) | Multi-tile, data-parallel top. Holds the `tile_dispatcher`, N_LANES `accel_engine` instances, per-lane scratchpad banks, and the lane-id address router. This is what `compute_core.sv` wraps. |
| [`accel_engine.sv`](rtl/accel_engine.sv) | Single compute lane. Pairs `accel_controller` + 4 tile buffers + `stream_pipeline` + per-lane perf counters. Consumes one `cmd_pkt_t` per output tile (LOAD → autonomous compute → WRITE). |

### Control plane

| File | Description |
|---|---|
| [`accel_controller.sv`](rtl/accel_controller.sv) | Per-lane FSM (IDLE → LOAD → STREAM → WRITE → DONE). Handles only boundary I/O between SRAM and tile buffers; the matmul+activation runs autonomously inside `stream_pipeline`. |
| [`tile_dispatcher.sv`](rtl/tile_dispatcher.sv) | Multi-lane orchestrator. Walks the (m_tiles × n_tiles) output grid and statically maps `tile_idx → (lane = idx mod N_LANES, slot = idx div N_LANES)`, baking `slot * SLOT_STRIDE` into per-tile addresses to prevent cross-tile aliasing. |
| [`tile_scheduler.sv`](rtl/tile_scheduler.sv) | Inner traversal helper — iterates (m,n,k) tile coordinates given matrix dimensions and a `tile_done` pulse. |
| [`mode_decoder.sv`](rtl/mode_decoder.sv) | Decodes a host `cmd_pkt_t` into local enables / dims / addresses / `fused_sel`. |
| [`csr_block.sv`](rtl/csr_block.sv) | Configuration / status registers — host-visible window for issuing commands and reading status. |
| [`perf_counter_block.sv`](rtl/perf_counter_block.sv) | Hardware perf counters (active cycles, stall cycles, tiles completed). One block per lane. |

### Datapath leaf cells

| File | Description |
|---|---|
| [`mac_pe.sv`](rtl/mac_pe.sv) | Q16.16 multiply-accumulate processing element with truncating mul, saturating add, west/north pass-through for systolic dataflow. |
| [`systolic_array_64x64.sv`](rtl/systolic_array_64x64.sv) | 64×64 grid of `mac_pe`s, output-stationary, with skewed feeding. The GEMM workhorse. |
| [`adder_tree.sv`](rtl/adder_tree.sv) | Pipelined Q16.16 reduction tree (parameterized `NUM_INPUTS`). Used inside softmax for sum-of-exps. |
| [`gelu_lut.sv`](rtl/gelu_lut.sv) | tanh ROM (256 entries, Q16.16) loaded from `gelu_tanh_lut.mem`; covers input range [-4, 4]. |
| [`gelu_tanh_lut.mem`](rtl/gelu_tanh_lut.mem) | tanh LUT contents in `$readmemh` format. |
| [`exp_lut.sv`](rtl/exp_lut.sv) | exp ROM (256 entries, Q16.16) loaded from `exp_lut.mem`; covers [-8, 0] (post max-subtract for softmax). |
| [`exp_lut.mem`](rtl/exp_lut.mem) | exp LUT contents in `$readmemh` format. |
| [`gelu_unit.sv`](rtl/gelu_unit.sv) | GELU activation in Q16.16 using a clamped Padé-tanh approximation; pipelined 6 stages, input clamped to ±16 to prevent x³ overflow. |
| [`gelu_grad_unit.sv`](rtl/gelu_grad_unit.sv) | GELU gradient `gelu'(x)` for fused FFN-backward. Same clamped-Padé tanh kernel as `gelu_unit`. |
| [`softmax_unit.sv`](rtl/softmax_unit.sv) | Numerically stable softmax — max-reduce → subtract+exp → sum → single-reciprocal × 64-multiply normalization. Supports active-length masking. |
| [`causal_mask_unit.sv`](rtl/causal_mask_unit.sv) | Applies a causal mask: forces upper-triangle elements (col > row) to a large negative value before softmax. |
| [`divider_or_reciprocal_unit.sv`](rtl/divider_or_reciprocal_unit.sv) | Q16.16 signed division (registered in/out). Synthesis tools infer a sequential divider. |
| [`fused_postproc_unit.sv`](rtl/fused_postproc_unit.sv) | The fused-activation MUX — selects bypass / GELU / GELU′ / softmax / mask based on `fused_sel`, used per-element after the systolic array. |

### Streaming pipeline / flow control

| File | Description |
|---|---|
| [`stream_pipeline.sv`](rtl/stream_pipeline.sv) | The intra-tile fusion pipeline. After `start`, runs feeder → systolic → (elemwise OR softmax path) → output buffer fully autonomously; intermediates never touch SRAM. Drives `pipeline_done` at the boundary. |
| [`pipeline_stage.sv`](rtl/pipeline_stage.sv) | Generic valid/ready register slice (data + handshake). Building block for the streaming path. |
| [`skid_buffer.sv`](rtl/skid_buffer.sv) | Two-entry buffer that absorbs one cycle of backpressure without losing throughput. |
| [`stream_mux.sv`](rtl/stream_mux.sv) | Selects between fused-output streams (used at the post-processing boundary). |

### Tile movers

| File | Description |
|---|---|
| [`tile_loader.sv`](rtl/tile_loader.sv) | Reads A/B tiles from SRAM into the per-lane tile buffers, address-generated row-major. |
| [`tile_writer.sv`](rtl/tile_writer.sv) | Drains the output tile buffer back to SRAM. |
| [`tile_buffer.sv`](rtl/tile_buffer.sv) | Register-based 64×64 Q16.16 tile store. Exposes 2D, linear, and `NUM_RD_PORTS` parallel-port reads — the parallel ports are how the streaming pipeline issues scattered reads without exporting all 4096 cells at the module boundary. |

### Memory subsystem

| File | Description |
|---|---|
| [`sram_bank.sv`](rtl/sram_bank.sv) | Single-port behavioral SRAM bank (synthesizable inferred BRAM). |
| [`scratchpad_ctrl.sv`](rtl/scratchpad_ctrl.sv) | Multi-bank scratchpad controller with per-port arbitration over `NUM_BANKS` `sram_bank` instances. |
| [`address_gen.sv`](rtl/address_gen.sv) | Reusable row-stride address generator for tile traversal. |
| [`dma_engine.sv`](rtl/dma_engine.sv) | Host-to-chiplet bulk movement — bridges the UCIe wr/rd channels to the scratchpad ports. |
| [`double_buffer_ctrl.sv`](rtl/double_buffer_ctrl.sv) | Ping-pong base-address controller (load region vs compute region) for future load/compute overlap. |

### SystemVerilog interfaces (modports)

| File | Description |
|---|---|
| [`stream_if.sv`](rtl/stream_if.sv) | Generic `valid/ready/data/last/op_mode` streaming interface with `src` / `dst` modports. |
| [`sram_if.sv`](rtl/sram_if.sv) | Scratchpad SRAM port (`req/we/addr/wdata/rdata/rvalid`), `master` / `slave` modports. |
| [`cmd_if.sv`](rtl/cmd_if.sv) | Host command channel (`cmd_valid/ready` + `cmd_pkt_t`), `host` / `device` modports. |
| [`tile_if.sv`](rtl/tile_if.sv) | Structured tile-transfer interface carrying `tile_meta_t`. |
| [`ctrl_if.sv`](rtl/ctrl_if.sv) | Scheduler-to-subblock control (`start/flush/mode/fused_sel/tile_boundary/done`). |
| [`status_if.sv`](rtl/status_if.sv) | Completion / busy / error / counters interface. |

These interface files are compiled by `run_compute_core.do` for type
visibility; the M2 testbenches drive ports directly rather than via
modports, but the interfaces remain part of the synthesizable block
inventory.
