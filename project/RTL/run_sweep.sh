#!/bin/bash
# =============================================================================
# run_sweep.sh -- Drive the full M3 characterization sweep on phobos.
#
# Phases (see Claude_sweep.md for full motivation):
#   1. systolic_array_64x64 at N in {1, 2, 4, 8, 16, 32}
#   2. fusion components (one synth per leaf), plus tile_buffer at p1 and p64
#   3. stream_pipeline at N in {1, 2, 4, 8, 16, 32}
#
# Each Genus run writes to out_sweep/<tag>/{*.v, reports/}. Logs land in
# logs_sweep/<tag>.log.
#
# Usage:
#   cd project/RTL
#   ./run_sweep.sh                # run all phases serially
#   ./run_sweep.sh phase1         # systolic only
#   ./run_sweep.sh phase2         # fusion blocks only
#   ./run_sweep.sh phase3         # stream_pipeline only
#   ./run_sweep.sh point systolic_array_64x64 8     # one specific point
#
# Notes:
#   * Single-threaded driver -- runs are large, parallel Genus instances
#     would blow phobos's 64 GB. CAT-team-safe by construction.
#   * Set ABORT_ON_FAIL=0 in the environment to continue past a failed
#     point (default aborts -- a failed early point is usually fixable
#     and re-running later points without it wastes hours).
# =============================================================================

set -u
ABORT_ON_FAIL="${ABORT_ON_FAIL:-1}"

cd "$(dirname "$0")"
mkdir -p logs_sweep out_sweep

# Confirm Genus is on PATH (phobos: `addpkg -l cadence-2022-09` first).
if ! command -v genus >/dev/null 2>&1; then
    echo "ERROR: 'genus' not on PATH. On phobos run:  addpkg -l cadence-2022-09" >&2
    exit 1
fi

SWEEP_N=(1 2 4 8 16 32)

# Phase 2 leaves -- default params; ARRAY_N is set to 1 (ignored by these tops)
PHASE2_BLOCKS=(
    gelu_unit
    gelu_grad_unit
    softmax_unit
    causal_mask_unit
    divider_or_reciprocal_unit
    adder_tree
    fused_postproc_unit
    accel_controller
    perf_counter_block
)

# tile_buffer is a special case -- two NUM_RD_PORTS variants

# -----------------------------------------------------------------------------
run_point() {
    # Args: tag-suffix-for-log, env-prefix-as-string...
    # Example: run_point "sys_8x8" "SYNTH_TOP=systolic_array_64x64 ARRAY_N=8"
    local tag="$1"; shift
    local envline="$*"
    local logfile="logs_sweep/${tag}.log"

    echo ""
    echo "=================================================================="
    echo " >> START point: $tag"
    echo "    env: $envline"
    echo "    log: $logfile"
    echo "    started: $(date -Iseconds)"
    echo "=================================================================="

    local t0=$(date +%s)
    # shellcheck disable=SC2086
    /usr/bin/env $envline genus -files run_genus_sweep.do -log "$logfile"
    local rc=$?
    local t1=$(date +%s)
    local dt=$((t1 - t0))

    if [ $rc -eq 0 ]; then
        echo " << DONE  $tag  (exit 0, ${dt}s)"
    else
        echo " !! FAIL  $tag  (exit $rc, ${dt}s) -- see $logfile"
        if [ "$ABORT_ON_FAIL" = "1" ]; then
            echo "Aborting sweep. Set ABORT_ON_FAIL=0 to continue past failures."
            exit $rc
        fi
    fi
}

# -----------------------------------------------------------------------------
phase1() {
    echo "### PHASE 1: systolic_array_64x64 sweep ###"
    for N in "${SWEEP_N[@]}"; do
        run_point "sys_${N}x${N}" "SYNTH_TOP=systolic_array_64x64 ARRAY_N=${N}"
    done
}

phase2() {
    echo "### PHASE 2: fusion component characterization ###"
    for top in "${PHASE2_BLOCKS[@]}"; do
        run_point "${top}" "SYNTH_TOP=${top} ARRAY_N=1"
    done
    # tile_buffer: small (1 read port, A/B/aux variant) + big (64 read ports,
    # output buffer variant). Same module, two synthesis points.
    run_point "tile_buffer_p1"  "SYNTH_TOP=tile_buffer BUF_NRD=1"
    run_point "tile_buffer_p64" "SYNTH_TOP=tile_buffer BUF_NRD=64"
}

phase3() {
    echo "### PHASE 3: stream_pipeline sweep ###"
    for N in "${SWEEP_N[@]}"; do
        run_point "stream_${N}x${N}" "SYNTH_TOP=stream_pipeline ARRAY_N=${N}"
    done
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
mode="${1:-all}"
case "$mode" in
    all)
        phase1
        phase2
        phase3
        ;;
    phase1) phase1 ;;
    phase2) phase2 ;;
    phase3) phase3 ;;
    point)
        # ./run_sweep.sh point <SYNTH_TOP> [<ARRAY_N> | <BUF_NRD-as-num for tile_buffer>]
        if [ $# -lt 2 ]; then
            echo "Usage: $0 point <SYNTH_TOP> [<ARRAY_N>|<BUF_NRD>]" >&2
            exit 2
        fi
        top="$2"
        n="${3:-1}"
        case "$top" in
            systolic_array_64x64)
                run_point "sys_${n}x${n}" "SYNTH_TOP=${top} ARRAY_N=${n}" ;;
            stream_pipeline)
                run_point "stream_${n}x${n}" "SYNTH_TOP=${top} ARRAY_N=${n}" ;;
            tile_buffer)
                run_point "tile_buffer_p${n}" "SYNTH_TOP=${top} BUF_NRD=${n}" ;;
            *)
                run_point "${top}" "SYNTH_TOP=${top}" ;;
        esac
        ;;
    *)
        echo "Usage: $0 [all|phase1|phase2|phase3|point <top> [<n>]]" >&2
        exit 2
        ;;
esac

echo ""
echo "Sweep dispatch finished. Run ./collect_sweep_csv.sh to build sweep_results.csv."
