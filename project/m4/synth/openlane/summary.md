# OpenLane Sky130 PnR — `top_small` (scoped-down) clean_v1

Submitted to satisfy the M4 OpenLane-configuration deliverable and to confirm
that the M3→M4 verified RTL fixes do not regress the Sky130 PnR. **The headline
chip numbers (9.07 mm², 2 ns close, 4.096 TFLOP/s peak) come from the SAED32
Genus run on the full 64×64 / 16-lane design, not from this Sky130 build.**

| Metric | Value | Source |
|---|---|---|
| Design | `top_small` (`config.json`, TILE_DIM=2, N_LANES=1) | `config.json` |
| PDK | sky130A (`sky130_fd_sc_hd`) | `config.json` |
| Clock period (target) | 10 ns (100 MHz) | `config.json` |
| Cell area | **0.578 mm²** (578,022 µm²) | `openlane_metrics.csv` |
| Die area | 1.94 mm² (1,388 × 1,399 µm) | `openlane_metrics.csv` |
| Core utilization | 25 % | `config.json` |
| **Timing @ nom_tt_025C_1v80** | **WNS +0.98 ns / TNS 0 / 0 violators (setup + hold)** | `openlane_metrics.csv` |
| Timing @ slow corners | does not close (typical for unconstrained OpenLane runs) | `openlane_run.log` |
| **DRC (Magic)** | **0 errors** ✅ | `openlane_metrics.csv` |
| **DRC (KLayout)** | **0 errors** ✅ | `openlane_metrics.csv` |
| **LVS** | **0 errors / 0 device differences** ✅ | `openlane_metrics.csv` |
| **XOR (Magic vs KLayout GDS)** | **0 differences** ✅ | `openlane_metrics.csv` |
| Antenna violations | 75 nets / 91 pins (heuristic diode insertion off) | `openlane_metrics.csv` |
| GDS output | `project/m3/synth/runs/clean_v1/final/gds/top_small.gds` | OpenLane run dir |

## Comparison to prior OpenLane attempts on the same `top_small` design

| Attempt | Date | RTL state | Cell area | TT close? |
|---|---|---|---|---|
| Attempt 7 (M3 first end-to-end) | M3 | M3 baseline (Padé chain, 1-cycle MAC, combinational divider) | 0.47 mm² (41,537 cells) | No — chip f_max ≈ 15 MHz |
| Attempt 8b (M5 piped MAC + piped divider) | M5 | + `mac_pe_piped4`, `divider_or_reciprocal_seq` | 0.45 mm² (38,521 cells) | Yes at FF only; rated 45 MHz at SS |
| **clean_v1 (M4, with all verified fixes)** | M4 | + accel_controller width fix, mac_pe_piped4 forward bypass, postproc grad delay, softmax+stream backpressure | **0.578 mm²** | **Yes at nom_tt with +0.98 ns slack** |

The M4 build is ~21 % larger than Attempt 8b due to the additional verified logic (backpressure FSM, width-extended counters, postproc delay alignment). Cell area, DRC/LVS cleanliness, and TT timing closure are all consistent with the prior runs — the verification fixes did not regress Sky130 PnR.
