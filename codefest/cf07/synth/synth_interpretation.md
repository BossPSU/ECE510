# CF07 — OpenLane 2 Synthesis Interpretation

**Design:** `mac_pe` (mixed-precision Q4.4/Q16.16 MAC PE, the leaf of the M3
project's 64×64 systolic array). Self-contained `synth_top.sv` is in
[`../hdl/synth_top.sv`](../hdl/synth_top.sv).

**Tool:** OpenLane v2.3.10, Yosys + OpenROAD, Sky130A PDK, std-cell library
`sky130_fd_sc_hd`. Flow ran end-to-end through DRC/LVS/GDS streamout
(73 steps, 0 errors).

## (a) Clock period and worst-case slack

Ran at **CLOCK_PERIOD = 10.0 ns** (100 MHz target) on the typical corner.
Post-PnR setup worst slack at `nom_tt_025C_1v80`:
**WNS = +1.475 ns (MET)** — achievable period ≈ 8.525 ns → **f_max ≈ 117 MHz**.
Hold WNS = +0.335 ns (also MET, no hold violations at any corner).

At the slow corner `nom_ss_100C_1v60` (100 °C, 1.60 V), the same path
fails: **WNS = −4.499 ns**, requiring ~14.5 ns to close. This is
expected for the unpipelined combinational depth — see (b).

## (b) Critical path

Startpoint: `a_in[22]` (Q16.16 input bit on the array boundary).
Endpoint: flop `_1299_` (one bit of the 32-bit Q16.16 accumulator).

Cell sequence along the path (from `sta_nom_tt_max.rpt`):
`OR4 → NOR4 → O31A → buf6 → buf8 → OR4 → XOR2 → A31O → XOR2 → XNOR2 → XNOR2 →
O32A → XNOR2 → NAND2 → AND3 → OR2 → NOR3 → buf6 → O2111AI → A31O → ...`

The dominant cell types are **XOR/XNOR (113 instances total)** from the
8×8 signed multiplier and the Q16.16 adder, plus **AOI/OAI compound
gates** the optimizer chose for sum-propagate logic. The path is the
exact intra-PE chain the project's Cadence Genus characterization
already identified on SAED32: input → Q4.4 quantize/saturate →
8×8 multiply → Q8.8→Q16.16 align shift → accumulator add → flop.

## (c) Total cell area and top contributors

Synthesis-only (Yosys, pre-PnR): **8,398 µm²** across 702 cells.
Post-PnR (after buffering, CTS, optimization): **10,327 µm²** across
**1,482 instances**. Sequential elements (88 DFFs) account for
2,312 µm² (≈28 %); the remaining ~72 % is combinational. Top three by
instance count:

| Cell | Count | Role |
|---|---:|---|
| `sky130_fd_sc_hd__dfrtp_2` (rising-edge DFF) | 88 | Q16.16 acc + a_out/b_out forwarding |
| `sky130_fd_sc_hd__nor2_2` / `xnor2_2` (tied) | 68 each | adder + multiplier sum logic |
| `sky130_fd_sc_hd__mux2_1` | 65 | saturation MUX + `clear_acc` select |

## (d) Failed constraints, hold violations, warnings worth investigating

- **No setup or hold violations at the typical corner**; 0 lint errors,
  0 lint warnings, 0 inferred latches.
- **Setup violations at all three SS corners** (max/min/nom @ 100 °C,
  1.60 V), worst −4.499 ns. Not a design bug — derating to ~70 MHz at
  the slow corner closes timing without changes.
- **6 max-fanout violations at every corner** (one fanout pin exceeds
  the Sky130 default cap-load limit). Likely the `en` or `clear_acc`
  control nets fanning out to ~88 flops without enough buffering;
  inserting one buffer would clear it. Not blocking for CF07.
- **2 warnings worth noting**: `RSZ-0062 unable to repair all setup
  violations` (PnR couldn't fully fix the SS-corner gap on its own —
  consistent with the path being too long combinationally), and
  `Odb antenna properties missing on 8 output pins` (Sky130 doesn't
  ship antenna diff info for primary outputs — cosmetic for a macro).
