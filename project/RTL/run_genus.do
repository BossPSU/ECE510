# =============================================================================
# run_genus.do -- Per-block Cadence Genus synthesis for the M3-prep RTL.
#
# Default top is mac_pe (the mixed-precision MAC PE with Q4.4 multiplier +
# Q16.16 accumulator). Pick a different leaf with the SYNTH_TOP env var.
# Full-engine and full-chip synthesis OOM on phobos's 64 GB during PBS
# partitioning, so we stay at leaf-block granularity and build the chip
# area estimate analytically (see README).
#
# Usage (from project/RTL/):
#   genus -files run_genus.do -log mac_pe.log               # default top
#
#   SYNTH_TOP=accel_controller    genus -files run_genus.do -log ctrl.log
#   SYNTH_TOP=gelu_unit           genus -files run_genus.do -log gelu.log
#   SYNTH_TOP=gelu_grad_unit      genus -files run_genus.do -log glug.log
#   SYNTH_TOP=fused_postproc_unit genus -files run_genus.do -log fpp.log
#   SYNTH_TOP=softmax_unit        genus -files run_genus.do -log sm.log
#   SYNTH_TOP=perf_counter_block  genus -files run_genus.do -log perf.log
#
# Outputs land in out_block/<TOP>/{*.v, *.sdc, reports/}.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Tool setup
# -----------------------------------------------------------------------------
# HDL search path is "." since this script and the RTL share a directory.
set_db init_lib_search_path { . $env(LIB_PATH) }
set_db init_hdl_search_path { . }

set_db max_cpus_per_server 8
set_db super_thread_servers "localhost"

set_db hdl_error_on_blackbox  true
set_db hdl_track_filename_row_col true
set_db information_level 7

# Pick the synthesis top. Override via SYNTH_TOP env var.
if { [info exists env(SYNTH_TOP)] } {
    set TOP $env(SYNTH_TOP)
} else {
    set TOP mac_pe
}
puts "INFO: SYNTH_TOP = $TOP"

# -----------------------------------------------------------------------------
# 2. Library
#
# Default target: Synopsys SAED32 EDK (32/28nm), RVT std cells, TT corner
# at 0.85V / 25C -- the standard PSU ECE academic PDK. Override via env:
#   export LIB_PATH=/path/to/lib/dir
#   export LIB_FILE=name_of_corner.lib
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
# 3. Read RTL -- package + every leaf block. Genus only elaborates what's
#    reachable from $TOP, so reading extras is cheap (just parse cost).
# -----------------------------------------------------------------------------
puts ">>> Reading RTL..."

# Package + interfaces (always)
read_hdl -sv accel_pkg.sv
read_hdl -sv stream_if.sv
read_hdl -sv sram_if.sv
read_hdl -sv cmd_if.sv
read_hdl -sv tile_if.sv
read_hdl -sv ctrl_if.sv
read_hdl -sv status_if.sv

# Leaf blocks worth synthesizing individually
read_hdl -sv mac_pe.sv
read_hdl -sv gelu_lut.sv
read_hdl -sv exp_lut.sv
read_hdl -sv adder_tree.sv
read_hdl -sv gelu_unit.sv
read_hdl -sv gelu_grad_unit.sv
read_hdl -sv softmax_unit.sv
read_hdl -sv causal_mask_unit.sv
read_hdl -sv divider_or_reciprocal_unit.sv
read_hdl -sv fused_postproc_unit.sv
read_hdl -sv pipeline_stage.sv
read_hdl -sv skid_buffer.sv
read_hdl -sv stream_mux.sv
read_hdl -sv accel_controller.sv
read_hdl -sv perf_counter_block.sv

# -----------------------------------------------------------------------------
# 4. Elaborate the chosen top
# -----------------------------------------------------------------------------
puts ">>> Elaborating $TOP..."
elaborate $TOP
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 5. Constraints -- 1 GHz clock, async-low reset, modest I/O delays.
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set CLK_PER  1.0
set IO_DELAY [expr {$CLK_PER * 0.3}]

if { [llength [get_ports clk]] > 0 } {
    create_clock -name clk -period $CLK_PER [get_ports clk]
    set_clock_uncertainty 0.05 [get_clocks clk]
    set_clock_transition  0.05 [get_clocks clk]
}
if { [llength [get_ports rst_n]] > 0 } {
    set_false_path -from [get_ports rst_n]
}

# I/O delays on everything except clk/rst_n (if present)
set io_excludes [list]
foreach p {clk rst_n} {
    if { [llength [get_ports $p]] > 0 } { lappend io_excludes [get_ports $p] }
}
if { [llength $io_excludes] > 0 } {
    set in_ports [remove_from_collection [all_inputs] [join $io_excludes]]
} else {
    set in_ports [all_inputs]
}
set_input_delay  $IO_DELAY -clock clk $in_ports
set_output_delay $IO_DELAY -clock clk [all_outputs]

if { [catch {set_driving_cell -lib_cell INVX1_RVT [all_inputs]} err] } {
    puts "WARNING: set_driving_cell INVX1_RVT failed ($err)"
}
set_load 0.05 [all_outputs]

# -----------------------------------------------------------------------------
# 6. Synthesize
# -----------------------------------------------------------------------------
set outdir out_block/$TOP
file mkdir $outdir
file mkdir $outdir/reports

puts ">>> syn_generic..."
syn_generic
puts ">>> syn_map..."
syn_map
puts ">>> syn_opt..."
syn_opt

# -----------------------------------------------------------------------------
# 7. Reports + netlist
# -----------------------------------------------------------------------------
puts ">>> Writing reports..."
report_area      > $outdir/reports/area.rpt
report_timing    -max_paths 10 > $outdir/reports/timing.rpt
report_power     > $outdir/reports/power.rpt
report_gates     > $outdir/reports/gates.rpt
report_qor       > $outdir/reports/qor.rpt
report_messages  > $outdir/reports/messages.rpt
report_area -depth 2 > $outdir/reports/area_hier.rpt

write_hdl > $outdir/$TOP.v
write_sdc > $outdir/$TOP.sdc

puts ""
puts "=============================================="
puts " Genus block run complete."
puts " Top:        $TOP"
puts " Clock:      ${CLK_PER} ns (1 GHz)"
puts " Netlist:    $outdir/$TOP.v"
puts " Reports:    $outdir/reports/"
puts "=============================================="
