# =============================================================================
# run_genus_engine.do -- Synthesize ONE compute lane (accel_engine) only.
#
# Why per-lane? compute_core at full scale is 16 lanes x (64x64 = 4096) =
# 65,536 MAC PEs plus 16 x 4 tile buffers x 4096 cells -- elaboration
# alone eats 64+ GB on phobos. accel_engine is exactly one of the 16
# identical lanes; synthesizing it gives a real, defensible per-lane
# area/timing/power result. For the full-chip number, multiply by 16
# and add the (small) tile_dispatcher + DMA overhead from a separate
# pass on those blocks.
#
# Usage (from project/m2/syn/):
#     genus -files run_genus_engine.do -log genus_engine.log
#
# Produces under project/m2/syn/out_engine/:
#   - accel_engine.v                gate-level netlist
#   - accel_engine.sdc / .sdf       forward constraints
#   - reports/*.rpt                 area / timing / power / gates / qor
#
# Top: accel_engine. Clock: 1 GHz (clk), async active-low rst_n.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Tool setup
# -----------------------------------------------------------------------------
set_db init_lib_search_path { . $env(LIB_PATH) }
set_db init_hdl_search_path { ../rtl }

set_db max_cpus_per_server 8
set_db super_thread_servers "localhost"

set_db hdl_error_on_blackbox  true
set_db hdl_track_filename_row_col true
set_db information_level 7

# -----------------------------------------------------------------------------
# 2. Technology libraries (same as full-chip flow)
# -----------------------------------------------------------------------------
if { ![info exists env(LIB_PATH)] } {
    set env(LIB_PATH) "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm"
    puts "INFO: LIB_PATH unset; defaulting to SAED32 RVT @ $env(LIB_PATH)"
}

if { [info exists env(LIB_FILE)] } {
    set lib_files [list $env(LIB_PATH)/$env(LIB_FILE)]
} else {
    set lib_files [glob -nocomplain $env(LIB_PATH)/saed32rvt_tt0p85v25c.lib]
    if { [llength $lib_files] == 0 } {
        set lib_files [glob -nocomplain $env(LIB_PATH)/*tt0p85v25c.lib]
    }
    if { [llength $lib_files] == 0 } {
        set lib_files [glob -nocomplain $env(LIB_PATH)/*_tt_*.lib]
    }
    if { [llength $lib_files] == 0 } {
        set lib_files [glob -nocomplain $env(LIB_PATH)/*.lib]
    }
}

if { [llength $lib_files] == 0 } {
    error "No .lib files found in $env(LIB_PATH). Cannot proceed."
}

set_db library $lib_files
puts ">>> Loaded [llength $lib_files] standard-cell library file(s):"
foreach f $lib_files { puts "      $f" }

# -----------------------------------------------------------------------------
# 3. Read RTL — only what accel_engine actually depends on.
#
# Excluded vs full-chip flow: tile_loader, tile_writer, sram_bank,
# scratchpad_ctrl, address_gen, dma_engine, double_buffer_ctrl,
# mode_decoder, tile_scheduler, tile_dispatcher, csr_block, accel_top,
# accel_chiplet_wrapper, compute_core, interface. accel_engine exposes
# its SRAM port at the boundary, so the scratchpad lives outside.
# -----------------------------------------------------------------------------
puts ">>> Reading RTL (accel_engine subset)..."
set rtl ../rtl

# Package
read_hdl -sv $rtl/accel_pkg.sv

# Interfaces (compiled for type visibility)
read_hdl -sv $rtl/stream_if.sv
read_hdl -sv $rtl/sram_if.sv
read_hdl -sv $rtl/cmd_if.sv
read_hdl -sv $rtl/tile_if.sv
read_hdl -sv $rtl/ctrl_if.sv
read_hdl -sv $rtl/status_if.sv

# Datapath leaf cells used by stream_pipeline / fused_postproc
read_hdl -sv $rtl/mac_pe.sv
read_hdl -sv $rtl/systolic_array_64x64.sv
read_hdl -sv $rtl/gelu_lut.sv
read_hdl -sv $rtl/exp_lut.sv
read_hdl -sv $rtl/adder_tree.sv
read_hdl -sv $rtl/gelu_unit.sv
read_hdl -sv $rtl/gelu_grad_unit.sv
read_hdl -sv $rtl/softmax_unit.sv
read_hdl -sv $rtl/causal_mask_unit.sv
read_hdl -sv $rtl/divider_or_reciprocal_unit.sv
read_hdl -sv $rtl/fused_postproc_unit.sv

# Pipeline / flow control
read_hdl -sv $rtl/pipeline_stage.sv
read_hdl -sv $rtl/skid_buffer.sv
read_hdl -sv $rtl/stream_mux.sv

# Tile buffer (4 instances per lane)
read_hdl -sv $rtl/tile_buffer.sv

# Streaming compute pipeline
read_hdl -sv $rtl/stream_pipeline.sv

# Per-lane control + perf
read_hdl -sv $rtl/accel_controller.sv
read_hdl -sv $rtl/perf_counter_block.sv

# Lane engine (synth top)
read_hdl -sv $rtl/accel_engine.sv

# -----------------------------------------------------------------------------
# 4. Elaborate
# -----------------------------------------------------------------------------
set TOP accel_engine
puts ">>> Elaborating $TOP..."
elaborate $TOP
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 5. Constraints
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set CLK_PORT  clk
set RST_PORT  rst_n
set CLK_PER   1.0
set IO_DELAY  [expr {$CLK_PER * 0.3}]

create_clock -name clk -period $CLK_PER [get_ports $CLK_PORT]
set_clock_uncertainty 0.05 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

set_false_path -from [get_ports $RST_PORT]

set_input_delay  $IO_DELAY -clock clk [remove_from_collection \
    [all_inputs] [get_ports [list $CLK_PORT $RST_PORT]]]
set_output_delay $IO_DELAY -clock clk [all_outputs]

# Drive / load — try SAED32 RVT 1x inverter as the input driver.
# Wrapped in catch so a missing cell (different PDK) doesn't abort
# the run; inputs would just be treated as ideal sources.
if { [catch {set_driving_cell -lib_cell INVX1_RVT [all_inputs]} err] } {
    puts "WARNING: set_driving_cell INVX1_RVT failed ($err);"
    puts "         inputs will be modeled as ideal sources."
}
set_load 0.05 [all_outputs]

if { [file exists accel_engine.sdc] } {
    puts ">>> Sourcing additional constraints from accel_engine.sdc"
    read_sdc accel_engine.sdc
}

# -----------------------------------------------------------------------------
# 6. Synthesis
# -----------------------------------------------------------------------------
file mkdir out_engine
file mkdir out_engine/reports

puts ">>> Generic synthesis (RTL -> generic gates)..."
syn_generic

puts ">>> Mapping to standard cells..."
syn_map

puts ">>> Incremental optimization..."
syn_opt

# -----------------------------------------------------------------------------
# 7. Reports
# -----------------------------------------------------------------------------
puts ">>> Writing reports..."
report_area      > out_engine/reports/area.rpt
report_timing    -max_paths 20 > out_engine/reports/timing.rpt
report_power     > out_engine/reports/power.rpt
report_gates     > out_engine/reports/gates.rpt
report_qor       > out_engine/reports/qor.rpt
report_messages  > out_engine/reports/messages.rpt

# Hierarchical breakdown (controller / stream_pipeline / systolic / etc.)
report_area -depth 3 > out_engine/reports/area_hier.rpt

# -----------------------------------------------------------------------------
# 8. Netlist + forward constraints
# -----------------------------------------------------------------------------
puts ">>> Writing netlist + forward SDC/SDF..."
write_hdl    > out_engine/accel_engine.v
write_sdc    > out_engine/accel_engine.sdc
write_sdf -version 3.0 -timescale ns -edges check_edge \
            > out_engine/accel_engine.sdf
write_design -base_name out_engine/accel_engine

puts ""
puts "=============================================="
puts " Genus per-lane run complete."
puts " Top:        $TOP  (one of 16 identical lanes)"
puts " Clock:      ${CLK_PER} ns (1 GHz)"
puts " Netlist:    out_engine/accel_engine.v"
puts " Reports:    out_engine/reports/"
puts ""
puts " For full-chip estimate, multiply per-lane area by 16 and"
puts " add tile_dispatcher + DMA overhead (separate synth pass)."
puts "=============================================="

# exit
