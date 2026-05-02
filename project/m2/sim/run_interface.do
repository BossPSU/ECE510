# =============================================================================
# run_interface.do -- compile + run the M2 interface testbench in QuestaSim
# 2021.3. Run from project/m2/sim/:
#     vsim -do run_interface.do
# Produces interface_run.log in this directory.
# =============================================================================

transcript file interface_run.log
echo "=============================================="
echo " M2 Interface Simulation"
echo "=============================================="

if {[file exists work]} { vdel -all -lib work }
vlib work
vmap work work

set m2_rtl ../rtl

# Only compile what interface.sv actually needs: accel_pkg + interface.sv.
# tb_interface drives the core-side ports directly, so no compute RTL needed.
echo ">>> Compiling RTL..."
vlog -sv $m2_rtl/accel_pkg.sv
vlog -sv $m2_rtl/interface.sv

echo ">>> Compiling testbench..."
vlog -sv ../tb/tb_interface.sv

echo ">>> Running tb_interface..."
# +acc keeps signals visible to add wave / examine after vopt.
vsim -t 1ps -L work work.tb_interface \
     -voptargs="+acc" \
     -suppress 3839 +nowarn3839 -onfinish stop

# Add waveform BEFORE run -all so signal traces record during the run.
# After $finish the design hierarchy unloads and add wave can no longer
# resolve paths -- doing it now is what keeps the wave window viewable
# after the sim ends.
echo ">>> Configuring wave window..."
set ::wave_tb /tb_interface
do wave.do

run -all

# Now that traces exist, zoom to the full ~50 ns window of activity.
catch {wave zoom full}

echo ""
echo "Look for the line 'TB_INTERFACE: PASS' or 'FAIL' above."
echo "Wave window populated; save via File -> Export -> Image -> waveform.png"
transcript file ""
# (Sim stays loaded for image capture. For unattended batch use,
#  uncomment the line below.)
# quit -f
