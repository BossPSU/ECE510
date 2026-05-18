# CF07 — OpenLane 2 Synthesis Interpretation

**Design:** `mac_pe`, the mixed-precision Q4.4×Q4.4→Q16.16 MAC processing
element. It is the leaf of a 64×64 systolic array; the M3 chip
(`compute_core`) instantiates 16 such arrays — **65,536 PEs total**.
Whatever this leaf costs, the chip pays ~64K times: PE metrics
dominate the chip budget.

**Tool:** OpenLane v2.3.10, Sky130A, `sky130_fd_sc_hd`. 73-step flow
ran clean through DRC/LVS/GDS streamout; 0 lint errors, 0 inferred
latches.

## (a) Clock period and worst-case slack
Ran at **10.0 ns (100 MHz)**. Typical corner (`nom_tt_025C_1v80`):
**WNS = +1.475 ns (MET)** → effective f_max ≈ 117 MHz, ~17 % margin.
Hold WNS = +0.335 ns. Slow corner (`nom_ss_100C_1v60`):
WNS = −4.499 ns.

## (b) Critical path
`a_in[22]` → accumulator flop `_1299_`. The MAC core is fully
combinational: Q16.16→Q4.4 quantize/saturate → 8×8 signed multiply →
Q8.8→Q16.16 align → Q16.16 accumulate. XOR/XNOR cells dominate
(113 instances) from the multiplier and adder sum-propagate logic.
Mixed precision is the accelerator's lever: the 8×8 multiplier is
~16× smaller than a 32×32 Q16.16 equivalent, while the accumulator
keeps full headroom across long dot products. The PE shrinks;
arithmetic fidelity stays.

## (c) Cell area and top contributors
Post-PnR: **10,327 µm², 1,482 instances**. Sequential elements
(88 DFFs) = 2,312 µm² (~28 %); combinational logic = ~72 %. Top three
by instance count:

| Cell | Count | Role |
|---|---:|---|
| `dfrtp_2` (DFF) | 88 | Q16.16 accumulator + a/b forwarding |
| `nor2_2` / `xnor2_2` (tied) | 68 each | multiply + add sum logic |
| `mux2_1` | 65 | saturation MUX + `clear_acc` select |

Power: 2.72 mW per PE → ~178 W chip-wide at 65,536 PEs — addressable
through clock-gating idle PEs and per-tile DVFS.

## (d) Violations and handling
Typical corner is clean (0 setup, 0 hold, 0 lint). The
**slow-corner −4.499 ns setup gap is substantial — the path is
45 % over the 10 ns budget at SS PVT.** Two handling paths:
(1) pipeline `mac_pe` between multiply and align, halving
combinational depth at a cost of 1 MAC-latency cycle — cheap in a
systolic feed where pipeline fill amortizes over thousands of steps;
(2) derate to ~69 MHz at slow PVT (a **31 % throughput tax** vs the
typical-corner 117 MHz f_max — not free). Pipelining is the right
fix; the derate is a fallback. The 6 max-fanout violations are on
`en`/`clear_acc` control nets fanning to 88 flops; one buffer
insertion clears them.
