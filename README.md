# ECE 410/510 — Mixed-Precision Transformer FFN Accelerator Chiplet

Coursework for Portland State University's ECE 410/510 (HW4AI / Hardware for Artificial Intelligence and Machine Learning), Spring 2026 — David Boss.

The project is a 64×64 output-stationary systolic accelerator for the transformer FFN forward and backward kernels, using a mixed-precision Q4.4 × Q4.4 → Q16.16 MAC pipeline, with on-chip LUT activations (GELU / GELU′ / softmax) and a UCIe-style host interface. The full project package is delivered through the milestone folders under [`project/`](project/).

## M4 submission

The M4 deliverable is the complete final-exam package: synthesizable RTL, verified end-to-end, synthesized, benchmarked, and documented. Start here:

- **[project/m4/README.md](project/m4/README.md)** — file catalog and reproduction instructions for the M4 folder.
- **[project/m4/report/design_justification.pdf](project/m4/report/design_justification.pdf)** — the 9-section, ~3,700-word design justification report. Read this for the design rationale, roofline analysis, precision choice, dataflow, verification, synthesis numbers, benchmark, and what didn't work.

Headline numbers (more detail in `project/m4/README.md`):

- **Verification: 8/8 testbench PASS** (QuestaSim 2021.3_1 on phobos, see [`project/m4/sim/final_run.log`](project/m4/sim/final_run.log)) — including 4 RTL bugs found and fixed during the campaign.
- **Synthesis: Genus 21.12 on SAED32 RVT closes at 2 ns / 500 MHz with 0 violators** (WNS +0.1 ps). Total cell area **9.07 mm²**, 2.37 M leaf cells, power 2.347 W (typ, vectorless). See [`project/m4/synth/`](project/m4/synth/).
- **Compute throughput: 4.096 TFLOP/s peak**; measured single-tile FFN_BWD 8.07 GFLOP/s. **Speedup vs M1 software baseline: 2.4× sustained-on-tile, 29.5× peak-vs-CPU-attainable.** See [`project/m4/bench/`](project/m4/bench/).

## Earlier milestones

| Milestone | Folder | What it adds |
|---|---|---|
| M1 | [`project/m1/`](project/m1/) | Software baseline + profiling — 35.3 ms / iter, 3.4 GFLOP/s on i5-10500H; identifies FFN_BWD as the dominant kernel (32.5 % of runtime). |
| M2 | [`project/m2/`](project/m2/) | First RTL stack — `compute_core` + `interface` + per-kernel testbenches. Precision study committing to Q4.4 × Q4.4 → Q16.16 (see [`project/m2/precision.md`](project/m2/precision.md)). |
| M3 | [`project/m3/`](project/m3/) | Integration top `top.sv` (UCIe + compute_core), end-to-end cosim, first OpenLane synthesis attempts (Sky130). |
| M4 | [`project/m4/`](project/m4/) | Final package — full-suite verification (8/8 PASS), SAED32 close, Sky130 OpenLane PnR, benchmark, design justification PDF. |

## Source tree

```
ECE510/
├── README.md                 ← this file
├── project/
│   ├── heilmeier.md           ← Heilmeier catechism
│   ├── m1/                    ← software baseline & profiling
│   ├── m2/                    ← initial RTL + precision study
│   ├── m3/                    ← integrated top + cosim + early synth
│   ├── m4/                    ← FINAL deliverable
│   │   ├── README.md
│   │   ├── rtl/
│   │   ├── tb/
│   │   ├── sim/
│   │   ├── synth/
│   │   ├── bench/
│   │   └── report/
│   └── RTL/                   ← canonical SystemVerilog source (60 .sv files); the verified-and-synthesized tree
├── codefest/                  ← weekly codefest deliverables
├── presentation/              ← project presentation materials
└── tools/                     ← helper scripts
```

## Tool versions

| Tool | Version | Used for |
|---|---|---|
| QuestaSim | 2021.3_1 (phobos) | functional verification (SV 2017) |
| Cadence Genus | 21.12-s068_1 | front-end synthesis (SAED32 RVT) |
| Cadence Innovus | 21.14-s109_1 | PnR (post-place — CTS did not close, see §9 of the design justification report) |
| OpenLane 2 | 2.3.10 (WSL2) | Sky130 PnR (in detailed routing at M4 submission) |
| Sky130A PDK | volare commit `0fe599b2afb6708d281543108caf8310912f54af` | OpenLane target PDK |
| SAED32 PDK | 32_28nm 1.0 | Genus + Innovus target PDK |
| Python | 3.13.12 | M1 baseline benchmark, M4 roofline + PDF build |
