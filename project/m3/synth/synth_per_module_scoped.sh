#!/usr/bin/env bash
# synth_per_module_scoped.sh -- Per-module yosys synthesis on Sky130A with
# scoped parameter overrides for the chip-relevant modules. Modules that
# scale with TILE_DIM / ARRAY_DIM / VEC_LEN / N_LANES are synthesized at
# the Option-A scoped sizes (TILE_DIM=4, N_LANES=1).
#
# Skips modules whose stat.rpt already exists -- so this can resume after
# the previous (default-size) sweep that completed the small leaves.
set -e
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"

YOSYS=/nix/store/9r0bh7sp051dpm8km8bqlb028anpd3v3-yosys/bin/yosys
LIB=/home/david/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

cd "$(dirname "$0")"
mkdir -p per_module

# Module -> param overrides for the scope-down. Empty string -> use defaults.
declare -A SCOPE
SCOPE[systolic_array_64x64]="chparam -set ROWS 4 systolic_array_64x64; chparam -set COLS 4 systolic_array_64x64;"
SCOPE[softmax_unit]="chparam -set VEC_LEN 4 softmax_unit;"
SCOPE[softmax_unit_lut]="chparam -set VEC_LEN 4 softmax_unit_lut; chparam -set N_LUT_BANKS 4 softmax_unit_lut;"
SCOPE[adder_tree]="chparam -set NUM_INPUTS 4 adder_tree;"
SCOPE[causal_mask_unit]="chparam -set VEC_LEN 4 causal_mask_unit;"
SCOPE[tile_buffer]="chparam -set TILE_DIM 4 tile_buffer; chparam -set NUM_RD_PORTS 4 tile_buffer;"
SCOPE[sram_bank]="chparam -set DEPTH 64 sram_bank; chparam -set ADDR_WIDTH 6 sram_bank;"
SCOPE[scratchpad_ctrl]="chparam -set NUM_BANKS 2 scratchpad_ctrl; chparam -set BANK_DEPTH 64 scratchpad_ctrl;"
SCOPE[stream_mux]="chparam -set NUM_INPUTS 4 stream_mux;"
SCOPE[stream_pipeline]="chparam -set ARRAY_DIM 4 stream_pipeline;"
SCOPE[accel_engine]="chparam -set TILE_DIM 4 accel_engine;"
SCOPE[accel_top]="chparam -set N_LANES 1 accel_top; chparam -set TILE_DIM 4 accel_top;"
SCOPE[compute_core]="chparam -set N_LANES 1 compute_core; chparam -set TILE_DIM 4 compute_core;"

TOPS=(
    mac_pe
    mac_pe_piped
    adder_tree
    sram_bank
    exp_lut
    gelu_lut
    pipeline_stage
    skid_buffer
    causal_mask_unit
    divider_or_reciprocal_unit
    divider_or_reciprocal_seq
    perf_counter_block
    address_gen
    systolic_array_64x64
    gelu_unit
    gelu_unit_lut
    gelu_grad_unit
    gelu_grad_unit_lut
    softmax_unit
    softmax_unit_lut
    fused_postproc_unit
    scratchpad_ctrl
    tile_buffer
    stream_mux
    mode_decoder
    tile_scheduler
    dma_engine
    double_buffer_ctrl
    tile_loader
    tile_writer
    stream_pipeline
    accel_controller
    tile_dispatcher
    accel_engine
    accel_top
    compute_core
    chiplet_interface
    top_small
)

synth_one() {
    local top="$1"
    local outdir="per_module/$top"

    # Re-synth this one if we have a scope override (the existing default
    # report doesn't represent the chip-scale config). Skip if already done
    # and no override exists.
    if [ -f "$outdir/stat.rpt" ] && [ -z "${SCOPE[$top]}" ]; then
        echo "  SKIP $top (already done, no scope override)"
        return
    fi

    rm -rf "$outdir"
    mkdir -p "$outdir"

    local override="${SCOPE[$top]:-}"

    local script=$(cat <<EOF
read_verilog v_hand/*.v
$override
hierarchy -check -top $top
proc
flatten
opt -fast
techmap
opt -fast
dfflibmap -liberty $LIB
abc -liberty $LIB -script "+strash; scorr; ifraig; retime,{D}; strash; dch,-f; map,-M,1,{D}"
opt_clean -purge
tee -o $outdir/stat.rpt stat -liberty $LIB
write_verilog -noattr $outdir/$top.synth.v
EOF
)
    echo ""
    echo "==================== $top ${override:+[SCOPED]} ===================="
    /usr/bin/time -v -o "$outdir/time.txt" "$YOSYS" -p "$script" \
        > "$outdir/synth.log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        local cells=$(grep -E 'Number of cells:' "$outdir/stat.rpt" | tail -1 | awk '{print $4}')
        local area=$(grep -E 'Chip area for module' "$outdir/stat.rpt" | tail -1 | awk '{print $NF}')
        echo "  OK: $cells cells, $area um^2"
    else
        echo "  FAIL: see $outdir/synth.log"
    fi
}

for top in "${TOPS[@]}"; do
    synth_one "$top"
done

echo ""
echo "==================== summary ===================="
printf "%-32s %12s %14s\n" "module" "cells" "area_um2"
for top in "${TOPS[@]}"; do
    rpt="per_module/$top/stat.rpt"
    if [ -f "$rpt" ]; then
        cells=$(grep -E 'Number of cells:' "$rpt" | tail -1 | awk '{print $4}')
        area=$(grep -E 'Chip area for module' "$rpt" | tail -1 | awk '{print $NF}')
        printf "%-32s %12s %14s\n" "$top" "${cells:-?}" "${area:-?}"
    else
        printf "%-32s %12s %14s\n" "$top" "FAIL" "-"
    fi
done
