# Per-module Sky130A synthesis summary

Sky130A standard cells (`sky130_fd_sc_hd`), TT corner (`tt_025C_1v80`),
synthesized via yosys 0.46 directly (no OpenLane wrapper) using
[`synth_per_module_scoped.sh`](synth_per_module_scoped.sh). Each module
is synthesized as its own top with the scope-down parameter overrides
listed in the `Scope` column.

This table is the Sky130A companion to the Cadence Genus SAED32 sweep
in [`../../RTL/sweep_results.csv`](../../RTL/sweep_results.csv); same
methodology (per-block synthesis + sum), different PDK.

| Module | Cells | Cell area (µm²) | Scope |
|---|---:|---:|---|
| `softmax_unit` | 215434 | 1134454.281602 | VEC_LEN=4 |
| `fused_postproc_unit` | 141379 | 731987.033601 | instantiates gelu+gelu_grad |
| `gelu_grad_unit` | 76134 | 394208.076800 | leaf (single instance) |
| `gelu_unit` | 56324 | 291065.404800 | leaf (single instance) |
| `systolic_array_64x64` | 20391 | 116748.220800 | ROWS=COLS=4 (16 PEs) |
| `divider_or_reciprocal_unit` | 16397 | 83914.230400 | leaf |
| `tile_buffer` | 5613 | 43694.406400 | TILE_DIM=4, NUM_RD_PORTS=4 |
| `accel_controller` | 3345 | 18680.416000 | leaf |
| `tile_dispatcher` | 1686 | 10752.812800 | N_LANES=1, TILE_DIM=4 |
| `adder_tree` | 1656 | 12076.582400 | NUM_INPUTS=4 |
| `tile_writer` | 1546 | 8503.155200 | leaf |
| `mac_pe` | 1478 | 8958.592000 | leaf |
| `address_gen` | 1410 | 7387.084800 | leaf |
| `tile_loader` | 1335 | 7263.216000 | leaf |
| `scratchpad_ctrl` | 686 | 4239.065600 | NUM_BANKS=2, BANK_DEPTH=64 |
| `perf_counter_block` | 664 | 5735.500800 | leaf |
| `skid_buffer` | 331 | 2977.856000 | DATA_WIDTH=32 |
| `tile_scheduler` | 243 | 1787.964800 | TILE_DIM=64 (cmd-level only) |
| `causal_mask_unit` | 234 | 1262.460800 | VEC_LEN=4 |
| `dma_engine` | 213 | 1963.132800 | leaf |
| `sram_bank` | 211 | 1406.348800 | DEPTH=64 |
| `stream_mux` | 174 | 873.337600 | NUM_INPUTS=4 |
| `pipeline_stage` | 134 | 1289.987200 | DATA_WIDTH=32 |
| `gelu_lut` | 34 | 640.614400 | default 256x32 ROM |
| `exp_lut` | 34 | 640.614400 | default 256x32 ROM |
| `mode_decoder` | 6 | 27.526400 | leaf |
| `double_buffer_ctrl` | 6 | 48.796800 | leaf |
| `chiplet_interface` | 0 |  | leaf |

## Notes

* **`mac_pe` cross-check**: this run reports 1,478 Sky130A cells; the
  [`codefest/cf07`](../../../codefest/cf07/) full OpenLane run reports
  1,482 post-PnR cells. The 0.27 % delta is within typical pre-PnR vs
  post-PnR optimization differences.
* **`softmax_unit` at VEC_LEN=4 is 1.13 mm²** of Sky130A cell area --
  the largest single module in the sweep. This is consistent with the
  Genus SAED32 sweep where `softmax_unit` was identified as the chip
  WNS bottleneck. Cross-PDK ratio Sky130:SAED32 ≈ 4.4x for this block,
  in line with the typical cell-area ratio between the two PDKs.
* **`chiplet_interface` synthesizes to 0 cells**: the UCIe protocol
  adapter is pure combinational pass-through (only `assign`
  statements). yosys's optimization passes recognize this as wires
  and the techmap step has no gates to map -- the protocol layer
  adds bit-routing but contributes no logic.
* **Modules not in this sweep**: `stream_pipeline`, `accel_engine`,
  `accel_top`, `compute_core`, `top_small`. These are the composite
  integration tops that re-instantiate the entire leaf+activation
  stack flat; their per-instance area exceeds the WSL2 memory budget
  of this host (8 GB total) during yosys's Brent-Kung lowering. The
  per-leaf sum (with the appropriate instance multipliers) gives the
  chip-area rollup, computed in
  [`../../chip_scale_rollup.md`](../../chip_scale_rollup.md).
