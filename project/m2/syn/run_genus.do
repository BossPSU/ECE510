# =============================================================================
# run_genus.do -- Cadence Genus synthesis script for M2 compute_core
#
# Usage (from project/m2/syn/):
#     genus -files run_genus.do -log genus.log
#   or interactively:
#     genus
#     genus> source run_genus.do
#
# Produces under project/m2/syn/out/:
#   - compute_core.v                gate-level netlist (Verilog)
#   - compute_core.sdc              forward SDC for P&R
#   - compute_core.sdf              back-annotation SDF
#   - reports/area.rpt              hierarchical area
#   - reports/timing.rpt            worst-case path per clock group
#   - reports/power.rpt             static + dynamic power estimate
#   - reports/gates.rpt             cell-type histogram
#   - reports/qor.rpt               summary QoR table
#
# Target: compute_core (the M2 deliverable wrapper around accel_top).
# Clock: single 1 GHz domain (clk), async active-low reset (rst_n).
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Tool setup
# -----------------------------------------------------------------------------
set_db init_lib_search_path { . $env(LIB_PATH) }
set_db init_hdl_search_path { ../rtl }

# Multicore / thread budget. Adjust to host machine.
set_db max_cpus_per_server 8
set_db super_thread_servers "localhost"

# Reasonable defaults for an academic / educational flow. Override via
# the environment if you have a calibrated PDK setup.
set_db hdl_error_on_blackbox  true
set_db hdl_track_filename_row_col true
set_db information_level 7

# -----------------------------------------------------------------------------
# 2. Technology libraries
#
# Default target: Synopsys SAED32 EDK (32/28nm), RVT std cells, TT corner
# at 0.85V / 25C — the standard PSU ECE academic PDK. Override via env:
#   export LIB_PATH=/path/to/lib/dir
#   export LIB_FILE=name_of_corner.lib
# Or set just LIB_PATH and the script will glob *tt0p85v25c*.lib (TT corner).
# -----------------------------------------------------------------------------
if { ![info exists env(LIB_PATH)] } {
    set env(LIB_PATH) "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm"
    puts "INFO: LIB_PATH unset; defaulting to SAED32 RVT @ $env(LIB_PATH)"
}

if { [info exists env(LIB_FILE)] } {
    # User pinned an exact .lib file
    set lib_files [list $env(LIB_PATH)/$env(LIB_FILE)]
} else {
    # Pull the single TT-corner main std-cell lib. Avoid level-shifter
    # (dlvl/ulvl) and power-gating (pg) variants — they don't add cells
    # we need for basic synthesis and just bloat the build.
    set lib_files [glob -nocomplain $env(LIB_PATH)/saed32rvt_tt0p85v25c.lib]

    # Generic fallbacks for non-SAED32 PDKs
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

# Optional LEF for physically-aware synthesis. Uncomment + set LEF_PATH.
# if { [info exists env(LEF_PATH)] } {
#     set_db lef_library [glob $env(LEF_PATH)/*.lef]
# }

# -----------------------------------------------------------------------------
# 3. Read RTL (dependency order matches run_compute_core.do)
# -----------------------------------------------------------------------------
puts ">>> Reading RTL..."
set rtl ../rtl

# Package first
read_hdl -sv $rtl/accel_pkg.sv

# SystemVerilog interfaces (compiled for type visibility; not all are
# instantiated by compute_core but Genus needs them in elaboration order)
read_hdl -sv $rtl/stream_if.sv
read_hdl -sv $rtl/sram_if.sv
read_hdl -sv $rtl/cmd_if.sv
read_hdl -sv $rtl/tile_if.sv
read_hdl -sv $rtl/ctrl_if.sv
read_hdl -sv $rtl/status_if.sv

# Datapath leaf cells
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

# Tile movers
read_hdl -sv $rtl/tile_loader.sv
read_hdl -sv $rtl/tile_writer.sv

# Memory subsystem
read_hdl -sv $rtl/sram_bank.sv
read_hdl -sv $rtl/scratchpad_ctrl.sv
read_hdl -sv $rtl/address_gen.sv
read_hdl -sv $rtl/dma_engine.sv
read_hdl -sv $rtl/double_buffer_ctrl.sv
read_hdl -sv $rtl/tile_buffer.sv

# Streaming compute pipeline
read_hdl -sv $rtl/stream_pipeline.sv

# Control plane
read_hdl -sv $rtl/mode_decoder.sv
read_hdl -sv $rtl/tile_scheduler.sv
read_hdl -sv $rtl/tile_dispatcher.sv
read_hdl -sv $rtl/accel_controller.sv
read_hdl -sv $rtl/perf_counter_block.sv
read_hdl -sv $rtl/csr_block.sv

# Per-lane engine + accelerator top
read_hdl -sv $rtl/accel_engine.sv
read_hdl -sv $rtl/accel_top.sv
read_hdl -sv $rtl/accel_chiplet_wrapper.sv

# M2 deliverable wrapper (synthesis top)
read_hdl -sv $rtl/compute_core.sv
# interface.sv is a separate UCIe-link top -- not synthesized here. Run a
# second pass with TOP=chiplet_interface if you want a netlist for it.
# read_hdl -sv $rtl/interface.sv

# -----------------------------------------------------------------------------
# 4. Elaborate
# -----------------------------------------------------------------------------
set TOP compute_core
puts ">>> Elaborating $TOP..."
elaborate $TOP
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 5. Constraints
#
# Single 1 GHz clock. Reset is async active-low and held low at startup.
# I/O delays are set conservatively at 30% of the period as a placeholder
# -- replace with real values from the M1 interface budget if available.
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set CLK_PORT  clk
set RST_PORT  rst_n
set CLK_PER   1.0    ;# ns -- 1 GHz target from README ("single clock @ 1 GHz")
set IO_DELAY  [expr {$CLK_PER * 0.3}]

create_clock -name clk -period $CLK_PER [get_ports $CLK_PORT]
set_clock_uncertainty 0.05 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# Reset is async; cut timing through it
set_false_path -from [get_ports $RST_PORT]

# I/O delays — assume host-facing ports are registered on both sides
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

# Optional external SDC override (drop a hand-tuned compute_core.sdc next
# to this script and we'll pick it up on top of the inline constraints).
if { [file exists compute_core.sdc] } {
    puts ">>> Sourcing additional constraints from compute_core.sdc"
    read_sdc compute_core.sdc
}

# -----------------------------------------------------------------------------
# 6. Synthesis
# -----------------------------------------------------------------------------
file mkdir out
file mkdir out/reports

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
report_area      > out/reports/area.rpt
report_timing    -max_paths 20 > out/reports/timing.rpt
report_power     > out/reports/power.rpt
report_gates     > out/reports/gates.rpt
report_qor       > out/reports/qor.rpt
report_messages  > out/reports/messages.rpt

# Per-lane / per-block area breakdown — useful for the M2 writeup
report_area -depth 3 > out/reports/area_hier.rpt

# -----------------------------------------------------------------------------
# 8. Netlist + forward constraints
# -----------------------------------------------------------------------------
puts ">>> Writing netlist + forward SDC/SDF..."
write_hdl    > out/compute_core.v
write_sdc    > out/compute_core.sdc
write_sdf -version 3.0 -timescale ns -edges check_edge \
            > out/compute_core.sdf
write_design -base_name out/compute_core

puts ""
puts "=============================================="
puts " Genus run complete."
puts " Top:        $TOP"
puts " Clock:      ${CLK_PER} ns (1 GHz)"
puts " Netlist:    out/compute_core.v"
puts " Reports:    out/reports/"
puts "=============================================="

# Stay open for interactive querying. Comment out for batch.
# exit
