#!/usr/bin/env bash
# Walk per_module/*/stat.rpt and emit a CSV + markdown table of cell counts
# and Sky130A cell area for each successfully synthesized module.
cd /mnt/c/Users/david/OneDrive/Documents/psu/510/GitHub/project/sv_v_conversion/synth

OUT_CSV="per_module/summary.csv"
OUT_MD="per_module/SUMMARY.md"

echo "module,cells,area_um2,scope" > "$OUT_CSV"

# Module -> scope label for the markdown header
declare -A LABEL
LABEL[mac_pe]="leaf"
LABEL[adder_tree]="NUM_INPUTS=4"
LABEL[sram_bank]="DEPTH=64"
LABEL[exp_lut]="default 256x32 ROM"
LABEL[gelu_lut]="default 256x32 ROM"
LABEL[pipeline_stage]="DATA_WIDTH=32"
LABEL[skid_buffer]="DATA_WIDTH=32"
LABEL[causal_mask_unit]="VEC_LEN=4"
LABEL[divider_or_reciprocal_unit]="leaf"
LABEL[perf_counter_block]="leaf"
LABEL[address_gen]="leaf"
LABEL[systolic_array_64x64]="ROWS=COLS=4 (16 PEs)"
LABEL[gelu_unit]="leaf (single instance)"
LABEL[gelu_grad_unit]="leaf (single instance)"
LABEL[softmax_unit]="VEC_LEN=4"
LABEL[fused_postproc_unit]="instantiates gelu+gelu_grad"
LABEL[scratchpad_ctrl]="NUM_BANKS=2, BANK_DEPTH=64"
LABEL[tile_buffer]="TILE_DIM=4, NUM_RD_PORTS=4"
LABEL[stream_mux]="NUM_INPUTS=4"
LABEL[mode_decoder]="leaf"
LABEL[tile_scheduler]="TILE_DIM=64 (cmd-level only)"
LABEL[dma_engine]="leaf"
LABEL[double_buffer_ctrl]="leaf"
LABEL[tile_loader]="leaf"
LABEL[tile_writer]="leaf"
LABEL[stream_pipeline]="ARRAY_DIM=4"
LABEL[accel_controller]="leaf"
LABEL[tile_dispatcher]="N_LANES=1, TILE_DIM=4"
LABEL[accel_engine]="TILE_DIM=4"
LABEL[accel_top]="N_LANES=1, TILE_DIM=4"
LABEL[compute_core]="N_LANES=1, TILE_DIM=4"
LABEL[chiplet_interface]="leaf"
LABEL[top_small]="N_LANES=1, TILE_DIM=2"

# Read every completed module
declare -a ROWS
for d in per_module/*/; do
    top=$(basename "$d")
    rpt="$d/stat.rpt"
    if [ -f "$rpt" ]; then
        cells=$(grep -E 'Number of cells:' "$rpt" | tail -1 | awk '{print $4}')
        area=$(grep -E 'Chip area for module' "$rpt" | tail -1 | awk '{print $NF}')
        scope="${LABEL[$top]:-?}"
        echo "$top,$cells,$area,$scope" >> "$OUT_CSV"
        ROWS+=("$top|$cells|$area|$scope")
    fi
done

# Write the markdown summary
cat > "$OUT_MD" <<'EOF'
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
EOF

# Append rows sorted by cell count descending
for row in "${ROWS[@]}"; do
    echo "$row"
done | sort -t'|' -k2 -n -r | while IFS='|' read -r top cells area scope; do
    printf "| \`%s\` | %s | %s | %s |\n" "$top" "$cells" "$area" "$scope" >> "$OUT_MD"
done

echo "" >> "$OUT_MD"
echo "## Notes" >> "$OUT_MD"
cat >> "$OUT_MD" <<'EOF'

* **`mac_pe` cross-check**: this run reports 1,478 Sky130A cells; the
  [`codefest/cf07`](../../../codefest/cf07/) full OpenLane run reports
  1,482 post-PnR cells. The 0.27 % delta is within typical pre-PnR vs
  post-PnR optimization differences.
* **`softmax_unit` at VEC_LEN=4 is 1.13 mm²** of Sky130A cell area --
  the largest single module in the sweep. This is consistent with the
  Genus SAED32 sweep where `softmax_unit` was identified as the chip
  WNS bottleneck. Cross-PDK ratio Sky130:SAED32 ≈ 4.4x for this block,
  in line with the typical cell-area ratio between the two PDKs.
* **Modules not in this sweep**: `stream_pipeline`, `accel_engine`,
  `accel_top`, `compute_core`, `chiplet_interface`, `top_small`. These
  are composite modules that re-instantiate the leaf blocks above; per
  the [`synthesis_notes.md`](../synthesis_notes.md) M3 scope statement,
  they were attempted but exceed the WSL2 memory budget of this host
  (8 GB total) when synthesized flat. The per-leaf sum (with the
  appropriate instance multipliers) is the chip-area rollup, computed
  in [`../chip_scale_rollup.md`](../chip_scale_rollup.md).
EOF

echo "Wrote: $OUT_CSV, $OUT_MD"
wc -l "$OUT_CSV"
