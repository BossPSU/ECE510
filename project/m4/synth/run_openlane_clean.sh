#!/bin/bash
# =============================================================================
# run_openlane_clean.sh -- one-shot clean OpenLane run for the M3 deliverable
# =============================================================================
#
# Uses the project/RTL/ source tree (latest, includes the M5/M6/M7 fixes that
# applied to this design path -- accel_controller width truncation in
# particular) plus the M2 chiplet wrappers (compute_core.sv, interface.sv).
#
# Locks stream_pipeline to legacy variants (USE_LUT_*=0, USE_PIPED*=0) so the
# OpenLane build matches prior attempt sets (no LUT ROMs to stage, no piped4
# MAC sprawl); the M5/M6 high-performance modules still get parsed so future
# config tweaks can flip them on without RTL edits.
#
# USAGE (from project/m3/synth/):
#   ./run_openlane_clean.sh                      # default tag = $(date +%Y%m%d_%H%M%S)
#   ./run_openlane_clean.sh my_tag               # custom run tag
#
# Output goes under: runs/<TAG>/
# Headline log:      openlane_run_<TAG>.log  (tee'd from openlane CLI)
# Status check:      tail -50 openlane_run_<TAG>.log
# =============================================================================

set -u
cd "$(dirname "$0")"

TAG="${1:-$(date +%Y%m%d_%H%M%S)}"
LOG="openlane_run_${TAG}.log"

echo ""
echo "=========================================================="
echo "  OpenLane clean run"
echo "  Design:    $(grep DESIGN_NAME config.json | sed 's/[",]//g')"
echo "  Tag:       $TAG"
echo "  Log:       $LOG"
echo "  RTL src:   v_hand/ (plain Verilog, ACCEL_CONTROLLER PATCHED with M3 fix)"
echo "  PDK:       sky130A"
echo "  Clock:     10 ns target"
echo "  Started:   $(date)"
echo "=========================================================="
echo ""

# Stage any .mem files that LUT modules WOULD read if instantiated. Even
# with USE_LUT_*=0 (so the modules aren't elaborated), Yosys' SV parser
# may still complain about the $readmemh path in dead code. Symlinking
# them in is cheap insurance and matches what we do for QuestaSim.
for memfile in exp_lut.mem gelu_tanh_lut.mem \
               gelu_lut_direct.mem gelu_grad_lut_direct.mem; do
    if [ ! -e "$memfile" ] && [ -e "../../RTL/$memfile" ]; then
        ln -sf "../../RTL/$memfile" "$memfile"
        echo "  staged: $memfile"
    fi
done
echo ""

# Strip /mnt/* PATH entries so WSL doesn't accidentally invoke Windows
# binaries (which broke prior attempts -- see launch_openlane_attempt9.sh).
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"

# Known-good install paths from the prior successful attempt 9 launch:
NIX_OPENLANE=/nix/store/9hhfv2x4r4x6v55799pa58jc2yni6awy-python3.11-openlane-2.3.10/bin/openlane
NIX_PDK_ROOT=/home/david/.volare/volare

# Run OpenLane. Prefer the Nix install (known good), fall back to PATH lookup.

# Use the pure-Verilog file set (v_hand/*.v) instead of the .sv set.
# project/RTL/*.sv with Synlig has been historically flaky (10+ prior
# failed attempts -- see openlane_M*_*.log files). v_hand is hand-
# converted plain Verilog that Yosys parses natively, AND it has been
# patched with the M3-verified accel_controller width fix (the same
# 12->13 bit fix that's in project/RTL/accel_controller.sv).
CONFIG="config_top_small_v_hand.json"

if [ -x "$NIX_OPENLANE" ]; then
    echo "  -> using Nix install: $NIX_OPENLANE"
    echo "  -> pdk-root:          $NIX_PDK_ROOT"
    "$NIX_OPENLANE" --pdk-root "$NIX_PDK_ROOT" --run-tag "$TAG" "$CONFIG" 2>&1 | tee "$LOG"
elif command -v openlane >/dev/null 2>&1; then
    echo "  -> using 'openlane' CLI on PATH"
    openlane --run-tag "$TAG" "$CONFIG" 2>&1 | tee "$LOG"
elif command -v flow.tcl >/dev/null 2>&1; then
    echo "  -> using 'flow.tcl' CLI"
    flow.tcl -design "$(pwd)" -tag "$TAG" -overwrite -config_file "$CONFIG" 2>&1 | tee "$LOG"
else
    echo ""
    echo "ERROR: neither 'openlane' nor 'flow.tcl' found on PATH."
    echo "  Load OpenLane env first, e.g.:"
    echo "    addpkg openlane2          (phobos pkg system)"
    echo "    source /pkgs/openlane/env.sh"
    echo "  Then re-run: ./run_openlane_clean.sh $TAG"
    exit 1
fi

EXIT=$?
echo ""
echo "=========================================================="
echo "  Finished: $(date)"
echo "  Exit:     $EXIT"
echo "=========================================================="

if [ $EXIT -eq 0 ]; then
    echo ""
    echo "Headline numbers (parse from runs/$TAG):"
    echo ""
    # OpenLane summary files: pick whichever exists.
    if [ -f "runs/$TAG/reports/final_summary_report.csv" ]; then
        echo "  Final summary:"
        cat "runs/$TAG/reports/final_summary_report.csv"
    elif [ -f "runs/$TAG/reports/metrics.csv" ]; then
        echo "  Metrics:"
        cat "runs/$TAG/reports/metrics.csv"
    fi
    echo ""
    echo "  Detailed reports:  runs/$TAG/reports/"
    echo "  GDS:               runs/$TAG/results/final/gds/"
fi

exit $EXIT
