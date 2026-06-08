# =============================================================================
# run_top.do -- M3 integrated cosim driver for QuestaSim 2021.3.
#
# Run from project/m3/sim/:
#     vsim -do run_top.do
#
# Produces cosim_run.log in this directory. The testbench drives a 64x64
# FFN_FWD tile through the chiplet's UCIe-side ports only (no direct DMA);
# end-to-end PASS line is "=== TB_TOP: PASS ===".
# =============================================================================

transcript file cosim_run.log
echo "=============================================="
echo " M3 Integrated Co-Simulation (top.sv)"
echo "=============================================="

# Fresh work library (same idiom as run_compute_core.do).
catch {vdel -all -lib work}
catch {file delete -force work}
vlib work
vmap work work

# All M2 RTL is reused unchanged; only top.sv and tb_top.sv are new.
set m2_rtl ../../m2/rtl
set m3_rtl ../rtl
set m3_tb  ../tb

# ---- Compile RTL in dependency order ----
echo ">>> Compiling M2 RTL..."
vlog -sv $m2_rtl/accel_pkg.sv

# Interfaces
vlog -sv $m2_rtl/stream_if.sv
vlog -sv $m2_rtl/sram_if.sv
vlog -sv $m2_rtl/cmd_if.sv
vlog -sv $m2_rtl/tile_if.sv
vlog -sv $m2_rtl/ctrl_if.sv
vlog -sv $m2_rtl/status_if.sv

# Datapath leaves
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

# M2 top-level wrappers (compute_core and chiplet_interface)
vlog -sv $m2_rtl/compute_core.sv
vlog -sv $m2_rtl/interface.sv

# ---- M3 integrated top ----
echo ">>> Compiling M3 top..."
vlog -sv $m3_rtl/top.sv

# ---- Testbench ----
echo ">>> Compiling testbench..."
vlog -sv $m3_tb/tb_top.sv

# ---- Run ----
echo ">>> Running tb_top..."
vsim -t 1ps -L work work.tb_top \
     -voptargs="+acc" \
     -suppress 3839 +nowarn3839 -onfinish stop

# Configure the wave window BEFORE run -all so traces record live.
echo ">>> Configuring wave window..."
do wave.do

run -all

# Zoom to the first informative slice (the macro_cmd handshake region).
catch {wave zoom range 0ns 2000ns}

echo ""
echo "Look for the line 'TB_TOP: PASS' or 'FAIL' above."
echo "Wave window populated; export via File -> Export -> Image -> cosim_waveform.png"
transcript file ""
# (Sim stays loaded for waveform capture. Uncomment for batch use:)
# quit -f
