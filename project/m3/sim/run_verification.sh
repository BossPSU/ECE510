#!/bin/bash
# =============================================================================
# run_verification.sh -- master test runner for the M3 verification suite
# =============================================================================
#
# Compiles all RTL once, then runs each testbench in batch mode under
# QuestaSim. Greps each transcript for its PASS/FAIL line and prints a
# single summary table at the end. Exit code is 0 if every testbench
# passed, 1 otherwise -- suitable for CI hooks.
#
# Usage (from project/m3/sim/):
#   ./run_verification.sh             # runs everything
#   ./run_verification.sh tb_top tb_ff_backward_e2e
#                                     # runs only the named testbenches
#
# Phobos prereq (load Cadence env if not already on PATH):
#   addpkg -l cadence-2022-09 OR equivalent for QuestaSim 2024+
#
# Output:
#   logs/<testbench>.log              full transcript per TB
#   verification_summary.log          aggregated summary
# =============================================================================

set -u
cd "$(dirname "$0")"
mkdir -p logs

# -----------------------------------------------------------------------------
# Testbench inventory.
# Order: leaf unit tests first (fastest), then subsystem, then chip-level.
# Each entry: <vsim top-cell> <PASS-line-prefix>
# -----------------------------------------------------------------------------
ALL_TBS=(
    "tb_fused_postproc_unit:TB_FUSED_PP"
    "tb_gelu_unit_lut:TB_GELU_LUT"
    "tb_gelu_grad_unit_lut:TB_GELU_GRAD_LUT"
    "tb_softmax_unit_lut:TB_SOFTMAX_LUT"
    "tb_stream_pipeline_tile:TB_SP_TILE"
    "tb_compute_core:TB_CC"
    "tb_top:TB_TOP"
    "tb_ff_backward_e2e:TB_FFB_E2E"
)

# If user passed testbench names, filter to those.
if [ $# -gt 0 ]; then
    SELECTED=()
    for arg in "$@"; do
        found=0
        for entry in "${ALL_TBS[@]}"; do
            if [ "${entry%%:*}" = "$arg" ]; then
                SELECTED+=("$entry")
                found=1
                break
            fi
        done
        if [ $found -eq 0 ]; then
            echo "ERROR: unknown testbench '$arg'." >&2
            echo "Known testbenches:" >&2
            for entry in "${ALL_TBS[@]}"; do
                echo "    ${entry%%:*}" >&2
            done
            exit 2
        fi
    done
    TBS=("${SELECTED[@]}")
else
    TBS=("${ALL_TBS[@]}")
fi

# -----------------------------------------------------------------------------
# Pre-flight: vsim must be on PATH
# -----------------------------------------------------------------------------
if ! command -v vsim >/dev/null 2>&1; then
    echo "ERROR: vsim not on PATH. Load QuestaSim (e.g. 'addpkg -l mentor-2024.1')." >&2
    exit 1
fi

echo ""
echo "##################################################################"
echo "## run_verification.sh: $(date -Iseconds)"
echo "## host : $(hostname)"
echo "## cwd  : $(pwd)"
echo "## TBs  : ${#TBS[@]} testbench(es)"
echo "##################################################################"
echo ""

# -----------------------------------------------------------------------------
# Compile RTL once into a shared work library.
# -----------------------------------------------------------------------------
M2_RTL=../../m2/rtl
M3_RTL=../rtl
M3_TB=../tb
RTL=../../RTL          # latest stream_pipeline + M5/M6 modules

COMPILE_LOG="logs/compile.log"
echo ">>> Compiling RTL (log: $COMPILE_LOG)..."
{
    rm -rf work
    vlib work
    vmap work work

    # Latest RTL (M5/M6 with Option B + Option F + Tier 1.6)
    vlog -sv -work work $RTL/accel_pkg.sv

    # Datapath leaves
    vlog -sv -work work $RTL/mac_pe.sv
    vlog -sv -work work $RTL/mac_pe_piped.sv
    vlog -sv -work work $RTL/mac_pe_piped4.sv
    vlog -sv -work work $RTL/systolic_array_64x64.sv
    vlog -sv -work work $RTL/exp_lut.sv
    vlog -sv -work work $RTL/gelu_lut.sv
    vlog -sv -work work $RTL/gelu_direct_lut.sv
    vlog -sv -work work $RTL/gelu_grad_direct_lut.sv
    vlog -sv -work work $RTL/adder_tree.sv
    vlog -sv -work work $RTL/gelu_unit.sv
    vlog -sv -work work $RTL/gelu_unit_lut.sv
    vlog -sv -work work $RTL/gelu_grad_unit.sv
    vlog -sv -work work $RTL/gelu_grad_unit_lut.sv
    vlog -sv -work work $RTL/softmax_unit.sv
    vlog -sv -work work $RTL/softmax_unit_lut.sv
    vlog -sv -work work $RTL/causal_mask_unit.sv
    vlog -sv -work work $RTL/divider_or_reciprocal_unit.sv
    vlog -sv -work work $RTL/divider_or_reciprocal_seq.sv
    vlog -sv -work work $RTL/fused_postproc_unit.sv
    vlog -sv -work work $RTL/tile_buffer.sv

    # Pipeline / flow control
    vlog -sv -work work $RTL/pipeline_stage.sv
    vlog -sv -work work $RTL/skid_buffer.sv
    vlog -sv -work work $RTL/stream_mux.sv

    # Top-of-stream
    vlog -sv -work work $RTL/stream_pipeline.sv

    # M2 modules needed only for tb_top / tb_compute_core / tb_ff_backward_e2e
    # (the M2 RTL is unchanged; the top.sv integration wrapper from M3 wires
    # the M2 chiplet_interface + compute_core path).
    # Interfaces
    vlog -sv -work work $M2_RTL/stream_if.sv
    vlog -sv -work work $M2_RTL/sram_if.sv
    vlog -sv -work work $M2_RTL/cmd_if.sv
    vlog -sv -work work $M2_RTL/tile_if.sv
    vlog -sv -work work $M2_RTL/ctrl_if.sv
    vlog -sv -work work $M2_RTL/status_if.sv

    # Tile movers
    vlog -sv -work work $M2_RTL/tile_loader.sv
    vlog -sv -work work $M2_RTL/tile_writer.sv

    # Memory subsystem
    vlog -sv -work work $M2_RTL/sram_bank.sv
    vlog -sv -work work $M2_RTL/scratchpad_ctrl.sv
    vlog -sv -work work $M2_RTL/address_gen.sv
    vlog -sv -work work $M2_RTL/dma_engine.sv
    vlog -sv -work work $M2_RTL/double_buffer_ctrl.sv

    # Control plane
    vlog -sv -work work $M2_RTL/mode_decoder.sv
    vlog -sv -work work $M2_RTL/tile_scheduler.sv
    vlog -sv -work work $M2_RTL/tile_dispatcher.sv
    vlog -sv -work work $M2_RTL/accel_controller.sv
    vlog -sv -work work $M2_RTL/perf_counter_block.sv
    vlog -sv -work work $M2_RTL/csr_block.sv

    # Per-lane engine and accelerator top
    vlog -sv -work work $M2_RTL/accel_engine.sv
    vlog -sv -work work $M2_RTL/accel_top.sv

    # Compute core + chiplet interface
    vlog -sv -work work $M2_RTL/compute_core.sv
    vlog -sv -work work $M2_RTL/interface.sv

    # M3 integrated top (chiplet_interface + compute_core)
    vlog -sv -work work $M3_RTL/top.sv

    # All testbenches (one work library, vsim picks the top later)
    vlog -sv -work work $M3_TB/tb_top.sv
    vlog -sv -work work $M3_TB/tb_ff_backward_e2e.sv
    vlog -sv -work work $M3_TB/tb_stream_pipeline_tile.sv
    vlog -sv -work work $M3_TB/tb_compute_core.sv
    vlog -sv -work work $M3_TB/tb_fused_postproc_unit.sv
    vlog -sv -work work $M3_TB/tb_gelu_unit_lut.sv
    vlog -sv -work work $M3_TB/tb_gelu_grad_unit_lut.sv
    vlog -sv -work work $M3_TB/tb_softmax_unit_lut.sv
} > "$COMPILE_LOG" 2>&1

if [ $? -ne 0 ]; then
    echo "    COMPILE FAILED -- see $COMPILE_LOG"
    tail -20 "$COMPILE_LOG"
    exit 1
fi
echo "    compile OK"
echo ""

# -----------------------------------------------------------------------------
# Run each testbench
# -----------------------------------------------------------------------------
SUMMARY="verification_summary.log"
: > "$SUMMARY"
TOTAL=0
PASS=0
FAIL=0

run_tb() {
    local tb="$1"
    local pass_prefix="$2"
    local logfile="logs/${tb}.log"
    local t0 dt result

    echo "------------------------------------------------------------------"
    echo " >> ${tb}"
    echo "    log: ${logfile}"
    t0=$(date +%s)

    vsim -c -t 1ps -L work work.${tb} \
         -voptargs="+acc" \
         -suppress 3839 \
         -do "run -all; quit" \
         > "$logfile" 2>&1
    dt=$(( $(date +%s) - t0 ))

    if grep -qE "^=== ${pass_prefix}: PASS ===" "$logfile"; then
        result="PASS"
        PASS=$((PASS + 1))
    elif grep -qE "^=== ${pass_prefix}: FAIL" "$logfile"; then
        result="FAIL"
        FAIL=$((FAIL + 1))
    else
        result="UNKNOWN"
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))

    echo "    elapsed: ${dt}s  result: ${result}"
    printf "%-30s %-8s %4ds\n" "${tb}" "${result}" "${dt}" >> "$SUMMARY"
}

for entry in "${TBS[@]}"; do
    tb="${entry%%:*}"
    pass_prefix="${entry##*:}"
    run_tb "$tb" "$pass_prefix"
done

# -----------------------------------------------------------------------------
# Aggregate summary
# -----------------------------------------------------------------------------
echo ""
echo "##################################################################"
echo "## VERIFICATION SUMMARY"
echo "##################################################################"
printf "%-30s %-8s %6s\n" "Testbench" "Result" "Time"
echo "----------------------------------------------"
cat "$SUMMARY"
echo "----------------------------------------------"
echo "Total: ${TOTAL}   Pass: ${PASS}   Fail: ${FAIL}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "=== VERIFICATION: PASS (all ${TOTAL} testbenches passed) ==="
    exit 0
else
    echo "=== VERIFICATION: FAIL (${FAIL}/${TOTAL} testbenches failed) ==="
    exit 1
fi
