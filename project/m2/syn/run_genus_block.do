# =============================================================================
# run_genus_block.do -- Synthesize ONE leaf block for area/timing/power.
#
# Why: full compute_core (32M gates flat) and one accel_engine (33M flat)
# both OOM on phobos's 64 GB. The per-lane flat synth peaked at 61 GB
# during PBS partition netlist creation. So we drop to leaf-block
# synthesis and build the chip area estimate analytically:
#
#   chip = N_LANES * (N_MACS_PER_LANE * mac_pe
#                   + 4 * tile_buffer
#                   + 1 * fused_postproc_unit
#                   + 1 * accel_controller
#                   + 1 * perf_counter_block
#                   + 1 * stream_pipeline glue)
#        + tile_dispatcher + DMA engine + scratchpad banks
#
#   = 16 * (4096 * mac_pe + ...) + ...
#
# Usage (from project/m2/syn/):
#   genus -files run_genus_block.do -log mac_pe.log
#       => synthesizes mac_pe (the default)
#
#   SYNTH_TOP=gelu_unit genus -files run_genus_block.do -log gelu_unit.log
#   SYNTH_TOP=accel_controller genus -files run_genus_block.do -log ctrl.log
#   SYNTH_TOP=fused_postproc_unit genus -files run_genus_block.do -log fp.log
#   SYNTH_TOP=softmax_unit genus -files run_genus_block.do -log sm.log
#   SYNTH_TOP=perf_counter_block genus -files run_genus_block.do -log perf.log
#
# Outputs to out_block/<TOP>/{*.v, *.sdc, reports/}
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

# Pick the synthesis top. Override via SYNTH_TOP env var.
if { [info exists env(SYNTH_TOP)] } {
    set TOP $env(SYNTH_TOP)
} else {
    set TOP mac_pe
}
puts "INFO: SYNTH_TOP = $TOP"

# -----------------------------------------------------------------------------
# 2. Library — same SAED32 RVT TT as engine script
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

# -----------------------------------------------------------------------------
# 3. Read RTL — package + every leaf block. Genus only elaborates what's
#    reachable from $TOP, so reading extras is cheap (just parse cost).
# -----------------------------------------------------------------------------
puts ">>> Reading RTL..."
set rtl ../rtl

# Package + interfaces (always)
read_hdl -sv $rtl/accel_pkg.sv
read_hdl -sv $rtl/stream_if.sv
read_hdl -sv $rtl/sram_if.sv
read_hdl -sv $rtl/cmd_if.sv
read_hdl -sv $rtl/tile_if.sv
read_hdl -sv $rtl/ctrl_if.sv
read_hdl -sv $rtl/status_if.sv

# All leaf blocks. List exactly the small ones we'd want to synthesize.
read_hdl -sv $rtl/mac_pe.sv
read_hdl -sv $rtl/gelu_lut.sv
read_hdl -sv $rtl/exp_lut.sv
read_hdl -sv $rtl/adder_tree.sv
read_hdl -sv $rtl/gelu_unit.sv
read_hdl -sv $rtl/gelu_grad_unit.sv
read_hdl -sv $rtl/softmax_unit.sv
read_hdl -sv $rtl/causal_mask_unit.sv
read_hdl -sv $rtl/divider_or_reciprocal_unit.sv
read_hdl -sv $rtl/fused_postproc_unit.sv
read_hdl -sv $rtl/pipeline_stage.sv
read_hdl -sv $rtl/skid_buffer.sv
read_hdl -sv $rtl/stream_mux.sv
read_hdl -sv $rtl/accel_controller.sv
read_hdl -sv $rtl/perf_counter_block.sv

# -----------------------------------------------------------------------------
# 4. Elaborate the chosen top
# -----------------------------------------------------------------------------
puts ">>> Elaborating $TOP..."
elaborate $TOP

# -----------------------------------------------------------------------------
# 5. Constraints — minimal: 1 GHz clock, async reset, modest I/O delays.
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

write_hdl    > $outdir/$TOP.v
write_sdc    > $outdir/$TOP.sdc

puts ""
puts "=============================================="
puts " Genus block run complete."
puts " Top:        $TOP"
puts " Clock:      ${CLK_PER} ns (1 GHz)"
puts " Netlist:    $outdir/$TOP.v"
puts " Reports:    $outdir/reports/"
puts "=============================================="
