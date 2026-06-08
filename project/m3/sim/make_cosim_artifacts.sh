#!/bin/bash
# =============================================================================
# make_cosim_artifacts.sh -- Produce the M3 end-to-end cosim deliverables
# =============================================================================
#
# Two artifacts the M3 rubric asks for in section 3 (End-to-end co-simulation):
#   - project/m3/sim/cosim_run.log       (plain text, includes PASS line)
#   - project/m3/sim/cosim_waveform.png  (host write -> compute -> host read,
#                                         with cursor annotations)
#
# Usage (from project/m3/sim/):
#   ./make_cosim_artifacts.sh
#
# Prerequisites:
#   - QuestaSim on PATH (same env run_verification.sh uses)
#   - ImageMagick `convert` on PATH (for PS -> PNG)
#
# Output goes in the same directory:
#   ./cosim_run.log
#   ./cosim_waveform.ps  (intermediate)
#   ./cosim_waveform.png
# =============================================================================

set -u
cd "$(dirname "$0")"

LOG_OUT="cosim_run.log"
WAVE_PS="cosim_waveform.ps"
WAVE_PNG="cosim_waveform.png"

echo ""
echo "=========================================================="
echo "  Step 1/3: Compile + run tb_top, capture cosim_run.log"
echo "=========================================================="
echo ""

# Re-use the master runner -- restricted to tb_top -- so the PASS line is
# the genuine output of a vsim run (no hand-editing).
bash ./run_verification.sh tb_top 2>&1 | tee "$LOG_OUT"

# Sanity check: did tb_top actually pass?
if ! grep -qE "^=== TB_TOP: PASS ===" logs/tb_top.log; then
    echo ""
    echo "ERROR: tb_top did NOT print PASS. Cosim artifacts NOT produced."
    echo "  Investigate logs/tb_top.log first."
    exit 1
fi
echo ""
echo "  PASS line confirmed in logs/tb_top.log."

echo ""
echo "=========================================================="
echo "  Step 2/3: Generate waveform via vsim -gui + cosim_waveform.do"
echo "=========================================================="
echo ""

# vsim -gui opens the wave window; cosim_waveform.do logs signals, runs
# the sim, places cursors, and dumps the wave canvas to PostScript.
vsim -gui -L work work.tb_top \
     -voptargs="+acc" \
     -suppress 3839 \
     -do cosim_waveform.do 2>&1 | tee waveform_gen.log

if [ ! -f "$WAVE_PS" ]; then
    echo ""
    echo "ERROR: $WAVE_PS was not produced."
    echo "  vsim may not have GUI access (DISPLAY unset?), or the wave"
    echo "  canvas widget path differs in this Questa build."
    echo ""
    echo "  Workaround: open Questa GUI manually, run cosim_waveform.do,"
    echo "  then File -> Export -> Image (PNG) -> save as $WAVE_PNG."
    exit 1
fi

echo ""
echo "=========================================================="
echo "  Step 3/3: Convert PostScript -> PNG"
echo "=========================================================="
echo ""

if ! command -v convert >/dev/null 2>&1; then
    echo "ERROR: ImageMagick 'convert' not on PATH."
    echo "  Install or load ImageMagick, then run:"
    echo "    convert -density 150 $WAVE_PS $WAVE_PNG"
    exit 1
fi

convert -density 150 "$WAVE_PS" "$WAVE_PNG"

if [ -f "$WAVE_PNG" ]; then
    echo "  -> $WAVE_PNG"
    echo ""
    echo "=========================================================="
    echo "  Artifacts ready. Commit with:"
    echo ""
    echo "    git add $LOG_OUT $WAVE_PNG"
    echo "    git commit -m 'M3 section 3: cosim log + waveform'"
    echo "    git push"
    echo "=========================================================="
else
    echo "ERROR: $WAVE_PNG not produced."
    exit 1
fi
