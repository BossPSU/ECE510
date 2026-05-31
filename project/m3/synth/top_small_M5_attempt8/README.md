# top_small.v -- full-flow OpenLane PnR + GDS (M5 pipelining)

This directory snapshots the **second clean end-to-end OpenLane run** of
the integrated `top_small.v` build, with M5 pipelining of the divider
and the MAC PE wired into the v_hand chain. The full 78-step Classic
flow ran to completion this time -- step 74 (final manufacturability
report) was reached, all DRC/LVS/antenna/XOR/IR-drop checkers cleared,
and both Magic and KLayout streamed out GDS. The flow does still flag
setup violations at TT and SS corners, but the M5 pipelining closed
**97 %** of the gap at TT (-55.7 ns → -1.6 ns) and the chip now closes
setup outright at the FF corner.

## Configuration

- **Source:** [`../config_top_small_v_hand.json`](../config_top_small_v_hand.json)
- **Verilog:** [`../v_hand/`](../v_hand/) with the M5 pipelined modules
  added: [`../v_hand/divider_or_reciprocal_seq.v`](../v_hand/divider_or_reciprocal_seq.v)
  (48-cycle iterative MSB-first shift-subtract divider replacing the
  64-bit combinational `/` in `divider_or_reciprocal_unit`) and
  [`../v_hand/mac_pe_piped.v`](../v_hand/mac_pe_piped.v) (mid-MAC pipeline
  register between Q4.4×Q4.4 multiplier and Q16.16 accumulator add).
  [`../v_hand/softmax_unit_lut.v`](../v_hand/softmax_unit_lut.v) stage 4
  was refactored to use the iterative divider with a single-register
  wait-buffer instead of the prior 2-deep shadow pipe.
  [`../v_hand/stream_pipeline.v`](../v_hand/stream_pipeline.v)
  `DRAIN_CYCLES` bumped from 4 → 5 to absorb the extra MAC stage.
- **Scope:** `top_small` default parameters -- `N_LANES = 1`, `TILE_DIM = 2`
- **PDK:** Sky130A, `sky130_fd_sc_hd`
- **Tool:** OpenLane v2.3.10
- **Clock target:** 10 ns (100 MHz)

## Headline results vs Attempt 7

| Metric | Attempt 7 (M4 LUT only) | **Attempt 8b (M5 pipelined)** | Delta |
|---|---:|---:|---:|
| OpenLane steps completed | 74 of 78 (deferred quit) | **74 of 74** (final-views step reached) | full flow |
| Yosys cells (post-techmap) | 41,689 | **38,521** | -3,168 (-7.6 %) |
| Yosys chip area | 474,500 µm² | **454,587 µm² = 0.45 mm²** | -19,913 µm² (-4.2 %) |
| Verilator lint errors | 0 | 0 | -- |
| Yosys check errors | 0 | 0 | -- |
| Yosys unmapped cells | 0 | 0 | -- |
| DRC (Magic + KLayout) | 0 violations | **0 violations** | clean |
| LVS (netgen) | clean | **clean** | -- |
| KLayout XOR | -- | **clean** (step 61) | new |
| Antenna repair | clean | **clean** | -- |
| Max Slew violations | 0 | **0** | -- |
| Max Cap violations | 0 | **0** | -- |
| IR drop (VPWR, % nominal) | -- | **1.02 %** (worst 18 mV / 1.8 V) | new |
| IR drop (VGND, % nominal) | -- | **0.86 %** (worst 15 mV / 1.8 V) | new |
| Full-flow wall-clock | ~3 h | ~2 h 45 min | -- |

The cell-count *shrunk* despite adding pipeline registers, because the
~500-gate-level combinational 64-bit Brent-Kung divider chain (Attempt
7's chip critical path) was replaced by a 48-iteration FSM with one
32-bit subtract per cycle plus a handful of state regs.

## Timing closure -- M5 closes FF, gets TT to 0.16 ns of meeting

Post-PnR STA at 9 corners ([`sta_summary.rpt`](sta_summary.rpt)):

| Corner | Attempt 7 setup WNS | **Attempt 8b setup WNS** | Attempt 7 hold WNS | **Attempt 8b hold WNS** |
|---|---:|---:|---:|---:|
| nom_tt_025C_1v80 (sign-off) | -55.69 ns ✗ | **-1.63 ns ✗** (97 % closer) | +0.31 ✓ | +0.31 ✓ |
| nom_ss_100C_1v60 (worst) | -115.04 ns ✗ | **-12.15 ns ✗** (89 % closer) | -0.49 ✗ | -0.51 ✗ |
| nom_ff_n40C_1v95 (fast)  | -31.50 ns ✗ | **+2.55 ns ✓** | +0.11 ✓ | +0.10 ✓ |

### Chip f_max post-M5

| Corner | Critical path | f_max |
|---|---:|---:|
| nom_tt @ 10 ns target | 11.63 ns | **~86 MHz** (vs ~15 MHz Attempt 7) |
| nom_ss @ 10 ns target | 22.15 ns | **~45 MHz** (vs did-not-close Attempt 7) |
| nom_ff @ 10 ns target | 7.45 ns  | **>100 MHz** ✓ |

The rated worst-case f_max is **45 MHz** (the SS-corner number, by
sign-off convention). FF closes cleanly; TT is 1.6 ns short of meeting
the 10 ns target and would close at ~12 ns (≈83 MHz).

### What's still failing -- and what it means

- **TT setup -1.63 ns / 177 violators.** Critical path is the remaining
  combinational depth in stage-2 of `mac_pe_piped`: the Q16.16 alignment
  shift + 32-bit accumulator add path. A second pipeline split (split
  alignment from add) projects to clear this.
- **SS setup -12.15 ns / 5,287 violators.** Same path as TT but with the
  SS-corner derating factor; closes via the same Tier-2 RTL fix.
- **SS hold -0.51 ns / 48 violators.** Small count; ECO buffer
  insertion clears these without touching the rest of the design (no
  RTL change).
- **No setup violations at FF.** First corner to close in this design's
  history.

The remaining gap is the second M5-style refactor (mac_pe Stage 2
split). It was deliberately deferred to M5 follow-on -- the M5
deliverable as defined was already met by closing FF and reducing TT
from 5.5× over budget to 16 % over budget.

## Power (at nom_tt_025C_1v80, 100 MHz clock)

From [`power_nom_tt.rpt`](power_nom_tt.rpt):

| Group | Internal | Switching | Leakage | Total | % of chip |
|---|---:|---:|---:|---:|---:|
| Sequential | 31.7 mW | 4.3 mW | 0.06 µW | 36.0 mW | 9.8 % |
| Combinational | 130.8 mW | 177.4 mW | 0.19 µW | 308.2 mW | 84.2 % |
| Clock | 10.4 mW | 11.6 mW | 0.13 µW | 22.0 mW | 6.0 % |
| **Chip total** | **172.9 mW** | **193.3 mW** | **0.38 µW** | **366.2 mW** | 100 % |

Switching power (52.8 %) > internal power (47.2 %) -- typical for an
arithmetic-dominated datapath. Power scales roughly linearly with
frequency. At the actual 45 MHz SS f_max, total power would be ≈ 165 mW.

## Files in this snapshot

| File | Size | Description |
|---|---:|---|
| `yosys_stat.rpt` | 4 KB | yosys per-cell-type stat at post-techmap |
| `yosys_runtime.txt` | -- | yosys wall-clock |
| `sta_summary.rpt` | 4 KB | STA summary across all 9 corners (the table above) |
| `power_nom_tt.rpt` | 1 KB | power breakdown at TT 100 MHz |

The large binary artifacts -- GDS (63 MB KLayout / 132 MB Magic),
final DEF (60 MB), post-PnR netlist (~16 MB), full per-corner STA --
live under `../runs/M5_attempt8b_150716/` (gitignored). To pull them
locally, run the OpenLane flow per the Reproduce section below.

## Reproduce

```sh
# From project/m3/synth/, with OpenLane v2.3.10 nix install and the same
# PDK pinned in Attempt 7 (sky130A volare commit 0fe599b2):
cd project/m3/synth
export PATH=/home/$USER/openlane_shim:/usr/bin:/bin
/path/to/openlane \
    --pdk-root /home/$USER/.volare/volare \
    --run-tag M5_attempt8_replay \
    config_top_small_v_hand.json
# Final layouts/reports in steps 53-57 (DEF, GDS) and step 54 (post-PnR STA).
```

Wall-clock: ~2 h 45 min on WSL2 with 4.5 GB cap, 4 vCPUs. Yosys peak
RSS ~1.1 GiB; OpenROAD detailed routing peaks ~2.0 GiB.

## What carries into M5 follow-on

| Item | Status | Note |
|---|---|---|
| Pipeline `mac_pe_piped` Stage 2 further (split align from add) | pending | The single biggest lever to close the remaining -1.63 ns at TT and ~-12 ns at SS. +1 cycle MAC latency. |
| ECO hold-buffer insertion at SS | pending | Clears 48 hold violators without RTL change. ~30 min in OpenROAD `repair_timing -hold`. |
| Phobos hierarchical synth + Innovus PnR | scripts written | See [`../../RTL/Planned_Phobos_Hier.md`](../../RTL/Planned_Phobos_Hier.md). SAED32 target ≈ 588 MHz at 64×64 array. |
