#!/usr/bin/env bash
# synth_per_module.sh -- Per-module yosys synthesis on Sky130A for every
# hand-flattened Verilog module under v_hand/. One yosys invocation per
# top-module, no OpenLane wrapper. Memory peaks per-run instead of
# templating every wide arithmetic operator across the whole design at
# once (which is what blew WSL2's memory in the flat top_small.v synth).
#
# Outputs:
#   per_module/<top>/stat.rpt        -- yosys 'stat' on the synthesized
#                                       netlist, with Sky130A liberty
#                                       (cell counts mapped to real cells)
#   per_module/<top>/synth.log       -- full yosys transcript
#   per_module/<top>/<top>.synth.v   -- gate-level netlist
#
# Run from project/sv_v_conversion/synth/ on WSL2 with the volare Sky130A
# PDK installed at the standard location.
set -e
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"

YOSYS=/nix/store/9r0bh7sp051dpm8km8bqlb028anpd3v3-yosys/bin/yosys
LIB=/home/david/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

cd "$(dirname "$0")"
mkdir -p per_module

# Tops to sweep, in bottom-up order. Each must elaborate standalone (the
# tile_dispatcher / accel_top / etc. are NOT leaf-clean -- they pull in
# every dependency from v_hand/*.v at read time, that's fine).
TOPS=(
    mac_pe
    adder_tree
    sram_bank
    exp_lut
    gelu_lut
    pipeline_stage
    skid_buffer
    causal_mask_unit
    divider_or_reciprocal_unit
    perf_counter_block
    address_gen
    systolic_array_64x64
    gelu_unit
    gelu_grad_unit
    softmax_unit
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

# Synthesis script template -- one pass per top
synth_one() {
    local top="$1"
    local outdir="per_module/$top"
    mkdir -p "$outdir"
    local script=$(cat <<EOF
read_verilog v_hand/*.v
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
    echo "==================== $top ===================="
    /usr/bin/time -v -o "$outdir/time.txt" "$YOSYS" -p "$script" \
        > "$outdir/synth.log" 2>&1 \
        && echo "  OK: $(grep -E 'Number of cells:' "$outdir/stat.rpt" | head -1 | awk '{print $4}') cells" \
        || echo "  FAIL: see $outdir/synth.log"
}

for top in "${TOPS[@]}"; do
    synth_one "$top"
done

echo ""
echo "==================== summary ===================="
printf "%-32s %12s\n" "module" "cells"
for top in "${TOPS[@]}"; do
    if [ -f "per_module/$top/stat.rpt" ]; then
        cells=$(grep -E 'Number of cells:' "per_module/$top/stat.rpt" \
                | tail -1 | awk '{print $4}')
        printf "%-32s %12s\n" "$top" "${cells:-FAIL}"
    else
        printf "%-32s %12s\n" "$top" "NO_REPORT"
    fi
done
