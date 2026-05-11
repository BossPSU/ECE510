# =============================================================================
# run.do -- compile + simulate the 4x4 binary-weight crossbar MAC testbench
# in QuestaSim. Run from codefest/cf06/:
#     vsim -do run.do
# Produces run.log in this directory and prints "*** TEST PASSED ***"
# (or "*** TEST FAILED: N mismatch(es) ***") to the transcript.
# =============================================================================

transcript file run.log
echo "=============================================="
echo " 4x4 Binary-Weight Crossbar MAC Simulation"
echo "=============================================="

# Robust work-library reset (handles stale work/ dirs that vdel can't open)
catch {vdel -all -lib work}
catch {file delete -force work}
vlib work
vmap work work

set hdl hdl

echo ">>> Compiling RTL..."
vlog -sv $hdl/crossbar_mac.sv

echo ">>> Compiling testbench..."
vlog -sv $hdl/crossbar_tb.sv

echo ">>> Running crossbar_tb..."
# -voptargs="+acc" keeps signals visible after vopt for waveform browsing.
vsim -t 1ps -L work work.crossbar_tb \
     -voptargs="+acc" \
     -onfinish stop

# Add a basic wave window BEFORE run -all so traces are captured during sim.
catch {
    add wave -divider "DUT I/O"
    add wave /crossbar_tb/clk /crossbar_tb/rst_n /crossbar_tb/load_w
    add wave /crossbar_tb/in_data /crossbar_tb/out_data
    add wave -divider "Weights"
    add wave /crossbar_tb/w_in
    add wave -divider "Expected"
    add wave /crossbar_tb/expected
}

run -all

# Zoom to the full sim window once traces exist.
catch {wave zoom full}

echo ""
echo "Look for the line '*** TEST PASSED ***' or '*** TEST FAILED ***' above."
echo "Wave window populated; export via File -> Export -> Image."
transcript file ""
# (Sim stays loaded for interactive inspection. Uncomment for batch.)
# quit -f
