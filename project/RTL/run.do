# run.do — QuestaSim script to compile and run all testbenches
# Creates a log file (tb_results.log) with PASS/FAIL/ERROR summary
# Usage: vsim -do run.do

# Setup
transcript file tb_results.log
echo "=============================================="
echo " Accelerator TB Suite — QuestaSim"
echo " Date: [clock format [clock seconds]]"
echo "=============================================="

# Create work library
if {[file exists work]} {
    vdel -all -lib work
}
vlib work
vmap work work

# ---- Compile all RTL ----
echo ""
echo ">>> Compiling RTL..."

# Package first (dependencies)
vlog -sv accel_pkg.sv

# Interfaces
vlog -sv stream_if.sv
vlog -sv sram_if.sv
vlog -sv cmd_if.sv
vlog -sv tile_if.sv
vlog -sv ctrl_if.sv
vlog -sv status_if.sv

# Datapath building blocks
vlog -sv mac_pe.sv
vlog -sv systolic_array_64x64.sv
vlog -sv gelu_lut.sv
vlog -sv exp_lut.sv
vlog -sv adder_tree.sv
vlog -sv gelu_unit.sv
vlog -sv gelu_grad_unit.sv
vlog -sv softmax_unit.sv
vlog -sv causal_mask_unit.sv
vlog -sv divider_or_reciprocal_unit.sv
vlog -sv fused_postproc_unit.sv

# Pipeline / flow control
vlog -sv pipeline_stage.sv
vlog -sv skid_buffer.sv
vlog -sv stream_mux.sv

# Tile load/store
vlog -sv tile_loader.sv
vlog -sv tile_writer.sv

# Memory
vlog -sv sram_bank.sv
vlog -sv scratchpad_ctrl.sv
vlog -sv address_gen.sv
vlog -sv dma_engine.sv
vlog -sv double_buffer_ctrl.sv

# Control
vlog -sv mode_decoder.sv
vlog -sv tile_scheduler.sv
vlog -sv accel_controller.sv
vlog -sv perf_counter_block.sv
vlog -sv csr_block.sv

# Top level
vlog -sv accel_top.sv
vlog -sv accel_chiplet_wrapper.sv

echo ">>> RTL compilation complete."

# ---- Compile all TBs ----
echo ""
echo ">>> Compiling testbenches..."

vlog -sv tb_mac_pe.sv
vlog -sv tb_gelu_unit.sv
vlog -sv tb_softmax_unit.sv
vlog -sv tb_causal_mask.sv
vlog -sv tb_systolic_array.sv
vlog -sv tb_fused_postproc.sv
vlog -sv tb_accel_top.sv

echo ">>> TB compilation complete."

# ---- Run each TB ----

# Helper: run a TB, capture result
proc run_tb {tb_name} {
    echo ""
    echo "=============================="
    echo " Running: $tb_name"
    echo "=============================="

    if {[catch {
        vsim -t 1ps -L work work.$tb_name \
             -suppress 3839 \
             +nowarn3839 \
             -onfinish stop
        run -all
        quit -sim
    } err]} {
        echo "!!! ERROR running $tb_name: $err"
        echo "RESULT: $tb_name — ERROR"
        return
    }
    echo "RESULT: $tb_name — COMPLETED"
}

# Run all TBs in bring-up order
echo ""
echo "=============================================="
echo " Running TB Suite"
echo "=============================================="

run_tb tb_mac_pe
run_tb tb_causal_mask
run_tb tb_gelu_unit
run_tb tb_softmax_unit
run_tb tb_systolic_array
run_tb tb_fused_postproc
run_tb tb_accel_top

# ---- Summary ----
echo ""
echo "=============================================="
echo " TB Suite Complete"
echo "=============================================="
echo ""
echo "Grep results from log:"
echo "  grep -E 'PASS|FAIL|ERROR|FAULT|RESULT' tb_results.log"
echo ""
echo "Log saved to: tb_results.log"

transcript file ""
quit -f
