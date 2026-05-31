#!/bin/bash
# =============================================================================
# run_phobos_hier.sh -- Drive Phase 3 -> 4 -> 5 of the phobos hierarchical
# synthesis plan in sequence:
#
#   Phase 3 : Genus hierarchical synth (run_genus_hier.do)
#   Phase 4 : Innovus PnR              (run_innovus_hier.do)
#   Phase 5 : Multi-corner STA + power (run_sta_mc.do)
#
# Each phase writes its own logs and checkpoints; this script is a thin
# wrapper that fails-fast on errors and prints a banner around each phase.
#
# Usage (from project/RTL/):
#   ./run_phobos_hier.sh                # phases 3, 4, 5 sequentially
#   ./run_phobos_hier.sh phase3         # synth only
#   ./run_phobos_hier.sh phase4         # PnR only (assumes synth is done)
#   ./run_phobos_hier.sh phase5         # STA only (assumes PnR is done)
#   ./run_phobos_hier.sh phase4 phase5  # PnR + STA
#
# Env vars are pass-through. The two most useful:
#   ARRAY_N      Default 64. Sets stream_pipeline ARRAY_DIM.
#   CLK_PER      Default 1.0 ns. Synth + Innovus both honor this.
#
# Phobos prereq:
#   addpkg -l cadence-2022-09   # puts genus + innovus on PATH
# =============================================================================

set -u
cd "$(dirname "$0")"
mkdir -p logs_hier

# Tee everything into a combined transcript while still printing live.
exec > >(tee -a logs_hier/phobos_hier.log) 2>&1
echo ""
echo "##################################################################"
echo "## run_phobos_hier.sh session start: $(date -Iseconds)"
echo "## host: $(hostname)  cwd: $(pwd)"
echo "## args: $*"
echo "## env : ARRAY_N=${ARRAY_N:-64}  CLK_PER=${CLK_PER:-1.0}"
echo "##################################################################"

# -----------------------------------------------------------------------------
# Tool presence checks
# -----------------------------------------------------------------------------
for tool in genus innovus; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' not on PATH. On phobos run:  addpkg -l cadence-2022-09" >&2
        exit 1
    fi
done

ARRAY_N="${ARRAY_N:-64}"
TARGET="stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier"

# -----------------------------------------------------------------------------
# Phase runners
# -----------------------------------------------------------------------------
phase3() {
    local logfile="logs_hier/${TARGET}_synth.log"
    echo ""
    echo "=================================================================="
    echo " >> PHASE 3: hierarchical Genus synth -- $TARGET"
    echo "    log: $logfile"
    echo "    started: $(date -Iseconds)"
    echo "=================================================================="
    local t0=$(date +%s)
    genus -files run_genus_hier.do -log "$logfile"
    local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    if [ $rc -eq 0 ]; then
        echo " << PHASE 3 done ($dt s)"
    else
        echo " !! PHASE 3 FAIL (exit $rc, ${dt}s) -- see $logfile" >&2
        exit $rc
    fi
}

phase4() {
    local logfile="logs_hier/${TARGET}_pnr.log"
    echo ""
    echo "=================================================================="
    echo " >> PHASE 4: Innovus P&R -- $TARGET"
    echo "    log: $logfile"
    echo "    started: $(date -Iseconds)"
    echo "=================================================================="
    if [ ! -f "out_sweep/${TARGET}/stream_pipeline.v" ]; then
        echo " !! PHASE 4 SKIPPED -- no synth netlist at out_sweep/${TARGET}/" >&2
        echo "    Run phase3 first."                                          >&2
        exit 2
    fi
    local t0=$(date +%s)
    innovus -nowin -files run_innovus_hier.do -log "$logfile"
    local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    if [ $rc -eq 0 ]; then
        echo " << PHASE 4 done ($dt s)"
    else
        echo " !! PHASE 4 FAIL (exit $rc, ${dt}s) -- see $logfile" >&2
        exit $rc
    fi
}

phase5() {
    local logfile="logs_hier/${TARGET}_sta.log"
    echo ""
    echo "=================================================================="
    echo " >> PHASE 5: multi-corner STA + power -- $TARGET"
    echo "    log: $logfile"
    echo "    started: $(date -Iseconds)"
    echo "=================================================================="
    if [ ! -e "out_innovus/${TARGET}/route.enc.dat" ] && \
       [ ! -e "out_innovus/${TARGET}/route.enc" ]; then
        echo " !! PHASE 5 SKIPPED -- no route.enc at out_innovus/${TARGET}/" >&2
        echo "    Run phase4 first."                                        >&2
        exit 2
    fi
    local t0=$(date +%s)
    innovus -nowin -files run_sta_mc.do -log "$logfile"
    local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    if [ $rc -eq 0 ]; then
        echo " << PHASE 5 done ($dt s)"
        echo ""
        echo "Summary:"
        cat "out_innovus/${TARGET}/sta/mc_summary.rpt"
    else
        echo " !! PHASE 5 FAIL (exit $rc, ${dt}s) -- see $logfile" >&2
        exit $rc
    fi
}

# -----------------------------------------------------------------------------
# Dispatch -- run requested phases in order
# -----------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    phases="phase3 phase4 phase5"
else
    phases="$*"
fi

for p in $phases; do
    case "$p" in
        phase3) phase3 ;;
        phase4) phase4 ;;
        phase5) phase5 ;;
        all)    phase3; phase4; phase5 ;;
        *)
            echo "Unknown phase: $p" >&2
            echo "Usage: $0 [phase3|phase4|phase5|all]..." >&2
            exit 2
            ;;
    esac
done

echo ""
echo "All requested phases complete."
