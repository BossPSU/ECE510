#!/usr/bin/env bash
# Synth just the small control modules that the long sweep didn't reach.
# These are pure control / wiring; should each finish in 1-3 minutes.
set -e
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"

YOSYS=/nix/store/9r0bh7sp051dpm8km8bqlb028anpd3v3-yosys/bin/yosys
LIB=/home/david/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

cd "$(dirname "$0")"

declare -A SCOPE
SCOPE[tile_dispatcher]="chparam -set N_LANES 1 tile_dispatcher; chparam -set TILE_DIM 4 tile_dispatcher;"

# Need a synthesizable double_buffer_ctrl, tile_loader, tile_writer too
declare -a TOPS=(
    accel_controller
    tile_dispatcher
    chiplet_interface
    double_buffer_ctrl
    tile_loader
    tile_writer
)

synth_one() {
    local top="$1"
    local outdir="per_module/$top"
    if [ -f "$outdir/stat.rpt" ]; then
        echo "  SKIP $top (already done)"
        return 0
    fi
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
    "$YOSYS" -p "$script" > "$outdir/synth.log" 2>&1
    if [ $? -eq 0 ] && [ -f "$outdir/stat.rpt" ]; then
        local cells=$(grep -E 'Number of cells:' "$outdir/stat.rpt" | tail -1 | awk '{print $4}')
        local area=$(grep -E 'Chip area for module' "$outdir/stat.rpt" | tail -1 | awk '{print $NF}')
        echo "  OK: $cells cells, $area um^2"
    else
        echo "  FAIL"
    fi
}

for top in "${TOPS[@]}"; do
    synth_one "$top"
done
