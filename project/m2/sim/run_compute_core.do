# =============================================================================
# run_compute_core.do -- compile + run the M2 compute_core testbench in
# QuestaSim 2021.3. Run from project/m2/sim/:
#     vsim -do run_compute_core.do
# Produces compute_core_run.log in this directory.
# =============================================================================

transcript file compute_core_run.log
echo "=============================================="
echo " M2 Compute Core Simulation"
echo "=============================================="

# Fresh work library
if {[file exists work]} { vdel -all -lib work }
vlib work
vmap work work

# Tell vlog where to find the .mem ROM init files (gelu/exp LUTs)
set m2_rtl ../rtl

# ---- Compile RTL in dependency order ----
echo ">>> Compiling RTL..."
vlog -sv $m2_rtl/accel_pkg.sv

# Interfaces (compiled but not currently instantiated by compute_core)
vlog -sv $m2_rtl/stream_if.sv
vlog -sv $m2_rtl/sram_if.sv
vlog -sv $m2_rtl/cmd_if.sv
vlog -sv $m2_rtl/tile_if.sv
vlog -sv $m2_rtl/ctrl_if.sv
vlog -sv $m2_rtl/status_if.sv

# Datapath leaf cells
vlog -sv $m2_rtl/mac_pe.sv
vlog -sv $m2_rtl/systolic_array_64x64.sv
vlog -sv $m2_rtl/gelu_lut.sv
vlog -sv $m2_rtl/exp_lut.sv
vlog -sv $m2_rtl/adder_tree.sv
vlog -sv $m2_rtl/gelu_unit.sv
vlog -sv $m2_rtl/gelu_grad_unit.sv
vlog -sv $m2_rtl/softmax_unit.sv
vlog -sv $m2_rtl/causal_mask_unit.sv
vlog -sv $m2_rtl/divider_or_reciprocal_unit.sv
vlog -sv $m2_rtl/fused_postproc_unit.sv

# Pipeline / flow control
vlog -sv $m2_rtl/pipeline_stage.sv
vlog -sv $m2_rtl/skid_buffer.sv
vlog -sv $m2_rtl/stream_mux.sv

# Tile movers
vlog -sv $m2_rtl/tile_loader.sv
vlog -sv $m2_rtl/tile_writer.sv

# Memory subsystem
vlog -sv $m2_rtl/sram_bank.sv
vlog -sv $m2_rtl/scratchpad_ctrl.sv
vlog -sv $m2_rtl/address_gen.sv
vlog -sv $m2_rtl/dma_engine.sv
vlog -sv $m2_rtl/double_buffer_ctrl.sv
vlog -sv $m2_rtl/tile_buffer.sv

# Streaming compute pipeline
vlog -sv $m2_rtl/stream_pipeline.sv

# Control plane
vlog -sv $m2_rtl/mode_decoder.sv
vlog -sv $m2_rtl/tile_scheduler.sv
vlog -sv $m2_rtl/tile_dispatcher.sv
vlog -sv $m2_rtl/accel_controller.sv
vlog -sv $m2_rtl/perf_counter_block.sv
vlog -sv $m2_rtl/csr_block.sv

# Per-lane engine and accelerator top
vlog -sv $m2_rtl/accel_engine.sv
vlog -sv $m2_rtl/accel_top.sv
vlog -sv $m2_rtl/accel_chiplet_wrapper.sv

# M2 wrappers
vlog -sv $m2_rtl/compute_core.sv
vlog -sv $m2_rtl/interface.sv

# Testbench
echo ">>> Compiling testbench..."
vlog -sv ../tb/tb_compute_core.sv

# ---- Run ----
echo ">>> Running tb_compute_core..."
vsim -t 1ps -L work work.tb_compute_core \
     -suppress 3839 +nowarn3839 -onfinish stop
run -all

echo ""
echo "Look for the line 'TB_COMPUTE_CORE: PASS' or 'FAIL' above."
transcript file ""
quit -f
