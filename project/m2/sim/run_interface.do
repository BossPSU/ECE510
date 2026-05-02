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
vsim -t 1ps -L work work.tb_interface \
     -suppress 3839 +nowarn3839 -onfinish stop
run -all

echo ""
echo "Look for the line 'TB_INTERFACE: PASS' or 'FAIL' above."
transcript file ""
quit -f
