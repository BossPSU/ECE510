# =============================================================================
# run_genus_hier.do -- Hierarchical Genus synthesis for stream_pipeline at
# ARRAY_DIM=64 with M5 RTL (USE_PIPED_MAC=1, USE_LUT_SOFTMAX=1).
#
# Phase 3 of the phobos hierarchical synth plan (see Planned_Phobos_Hier.md).
#
# Why this script exists (vs. the flat run_genus_sweep.do path):
#   The M3 sweep flattens through every boundary by default; at ARRAY_DIM=64
#   (4,096 mac_pe_piped instances + softmax_unit_lut + fused_postproc) that
#   blows past phobos's 64 GB during PBS partitioning. The fix is two
#   compounded settings:
#     1. set_db auto_ungroup none -- don't speculatively inline hierarchy.
#     2. preserve = true on the highly-replicated leaves (mac_pe_piped,
#        exp_lut, gelu_direct_lut, gelu_grad_direct_lut, divider_seq) so
#        Genus synthesizes each one ONCE, caches the gate-level result,
#        and reuses it across every parent instance.
#   Empirically this drops peak RSS by ~3-4x on similarly-replicated arrays.
#
# Inputs (env vars, all optional):
#   ARRAY_N      Default 64. Sets stream_pipeline ARRAY_DIM.
#   USE_LUT_SM   Default 1. Sets stream_pipeline USE_LUT_SOFTMAX.
#   USE_PIPED    Default 1. Sets stream_pipeline USE_PIPED_MAC.
#   CLK_PER      Default 1.0 ns (1 GHz). The chip target is ~600 MHz at
#                SAED32; 1 GHz forces Genus to work hard on the critical
#                path and surfaces violations early.
#   LIB_PATH     Default SAED32 RVT TT @ 0.85V/25C on phobos.
#   LIB_FILE     Optional specific lib filename.
#
# Output:
#   out_sweep/stream_pipeline_${N}x${N}_hier/
#     stream_pipeline.v       hierarchical netlist (preserved boundaries)
#     stream_pipeline.sdc     constraints (for Innovus / sign-off STA)
#     reports/{area,area_hier,timing,power,gates,qor,messages}.rpt
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Tool setup
# -----------------------------------------------------------------------------
set_db init_lib_search_path { . $env(LIB_PATH) }
set_db init_hdl_search_path { . }

# Conservative worker count -- matches run_genus_sweep.do post-OOM tuning.
# Higher counts COW-balloon peak RSS during PBS partitioning.
set_db max_cpus_per_server 4
set_db super_thread_servers "localhost"

set_db hdl_error_on_blackbox  true
set_db hdl_track_filename_row_col true
set_db information_level 7

# *** The OOM workaround, half 1 of 2 ***
# Disable Genus's default behavior of speculatively ungrouping hierarchy
# during syn_generic. We re-enable it selectively below via preserve flags.
set_db auto_ungroup none

# -----------------------------------------------------------------------------
# 2. Resolve inputs
# -----------------------------------------------------------------------------
set N 64
if { [info exists env(ARRAY_N)] } { set N $env(ARRAY_N) }

set USE_LUT_SM 1
if { [info exists env(USE_LUT_SM)] } { set USE_LUT_SM $env(USE_LUT_SM) }

set USE_PIPED 1
if { [info exists env(USE_PIPED)] } { set USE_PIPED $env(USE_PIPED) }

set CLK_PER 1.0
if { [info exists env(CLK_PER)] } { set CLK_PER $env(CLK_PER) }

set tag "stream_pipeline_${N}x${N}_hier"
puts "INFO: hierarchical synth -- tag=$tag  ARRAY_DIM=$N  USE_LUT_SOFTMAX=$USE_LUT_SM  USE_PIPED_MAC=$USE_PIPED  CLK_PER=$CLK_PER"

# -----------------------------------------------------------------------------
# 3. Technology library (SAED32 RVT TT @ 0.85V / 25C)
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
puts ">>> Loaded [llength $lib_files] standard-cell library file(s)."

# -----------------------------------------------------------------------------
# 4. Read RTL (full superset; Genus only elaborates what is reachable)
# -----------------------------------------------------------------------------
puts ">>> Reading RTL..."

# Package + interfaces
read_hdl -sv accel_pkg.sv
read_hdl -sv stream_if.sv
read_hdl -sv sram_if.sv
read_hdl -sv cmd_if.sv
read_hdl -sv tile_if.sv
read_hdl -sv ctrl_if.sv
read_hdl -sv status_if.sv

# Datapath leaves (both M4 baseline + M4+M5 LUT/piped variants)
read_hdl -sv mac_pe.sv
read_hdl -sv mac_pe_piped.sv
read_hdl -sv systolic_array_64x64.sv
read_hdl -sv exp_lut.sv
read_hdl -sv gelu_lut.sv
read_hdl -sv gelu_direct_lut.sv
read_hdl -sv gelu_grad_direct_lut.sv
read_hdl -sv adder_tree.sv
read_hdl -sv gelu_unit.sv
read_hdl -sv gelu_unit_lut.sv
read_hdl -sv gelu_grad_unit.sv
read_hdl -sv gelu_grad_unit_lut.sv
read_hdl -sv softmax_unit.sv
read_hdl -sv softmax_unit_lut.sv
read_hdl -sv causal_mask_unit.sv
read_hdl -sv divider_or_reciprocal_unit.sv
read_hdl -sv divider_or_reciprocal_seq.sv
read_hdl -sv fused_postproc_unit.sv

# Pipeline / flow control
read_hdl -sv pipeline_stage.sv
read_hdl -sv skid_buffer.sv
read_hdl -sv stream_mux.sv
read_hdl -sv tile_buffer.sv
read_hdl -sv stream_pipeline.sv

# -----------------------------------------------------------------------------
# 5. Elaborate stream_pipeline with M5 params explicit
#    Parameter order = (DATA_WIDTH, ARRAY_DIM, USE_LUT_SOFTMAX, USE_PIPED_MAC).
# -----------------------------------------------------------------------------
puts ">>> Elaborating stream_pipeline (ARRAY_DIM=$N, USE_LUT_SOFTMAX=$USE_LUT_SM, USE_PIPED_MAC=$USE_PIPED)..."
elaborate stream_pipeline -parameters [list 32 $N $USE_LUT_SM $USE_PIPED]
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 6. *** The OOM workaround, half 2 of 2 ***
#    Preserve module boundaries on every leaf that is (a) replicated many
#    times, (b) self-contained, or (c) big enough that re-flattening it
#    inside every parent context would multiply work.
#
#    With these preserves + auto_ungroup none, syn_generic synthesizes each
#    module's gate-level form once and reuses it; peak RSS scales with the
#    largest single module, not the flattened design.
#
#    Modules picked for preserve:
#      mac_pe_piped              -- 4,096 instances at N=64 (biggest win)
#      systolic_array_64x64      -- top-level shell for the PE grid; preserve
#                                   here lets Innovus partition cleanly later
#      exp_lut                   -- 8 instances (N_LUT_BANKS) inside softmax_unit_lut
#      gelu_direct_lut           -- 256x32 ROM, one instance
#      gelu_grad_direct_lut      -- 256x32 ROM, one instance
#      divider_or_reciprocal_seq -- M5 iterative divider, 1-2 instances
#      softmax_unit_lut          -- big leaf, isolating it bounds the worst case
#      fused_postproc_unit       -- big leaf, same reason
#      tile_buffer               -- 4 instances; treating as a soft macro
# -----------------------------------------------------------------------------
puts ">>> Setting preserve = true on hierarchical boundaries..."
set preserve_mods {
    mac_pe_piped
    systolic_array_64x64
    exp_lut
    gelu_direct_lut
    gelu_grad_direct_lut
    divider_or_reciprocal_seq
    softmax_unit_lut
    fused_postproc_unit
    tile_buffer
}
foreach mod $preserve_mods {
    set m [get_db modules $mod]
    if { [llength $m] > 0 } {
        set_db $m .ungroup_ok false
        set_db $m .preserve  true
        puts "    preserve  $mod"
    } else {
        puts "    skip      $mod (not in elaborated design)"
    }
}

# -----------------------------------------------------------------------------
# 7. Constraints -- 1 GHz clock, async-low reset, modest I/O delays.
#    Single-clock domain (clk), reset active-low (rst_n).
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set IO_DELAY [expr {$CLK_PER * 0.3}]

create_clock -name clk -period $CLK_PER [get_ports clk]
set_clock_uncertainty 0.05 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]
set_false_path -from [get_ports rst_n]

set in_ports [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_input_delay  $IO_DELAY -clock clk $in_ports
set_output_delay $IO_DELAY -clock clk [all_outputs]

if { [catch {set_driving_cell -lib_cell INVX1_RVT [all_inputs]} err] } {
    puts "WARNING: set_driving_cell INVX1_RVT failed ($err); inputs left ideal."
}
set_load 0.05 [all_outputs]

# -----------------------------------------------------------------------------
# 8. Synthesize incrementally
#    syn_generic -> RTL to generic gates (per preserved module, cached)
#    syn_map     -> tech-map to SAED32 RVT cells
#    syn_opt     -> incremental optimization (bounded by preserves)
# -----------------------------------------------------------------------------
set outdir out_sweep/$tag
file mkdir $outdir
file mkdir $outdir/reports

puts ">>> syn_generic..."
syn_generic

puts ">>> syn_map..."
syn_map

puts ">>> syn_opt..."
syn_opt

# -----------------------------------------------------------------------------
# 9. Reports + netlist
#    area_hier with -depth 6 surfaces the per-block breakdown that the
#    chip area rollup consumes.
# -----------------------------------------------------------------------------
puts ">>> Writing reports..."
report_area                      > $outdir/reports/area.rpt
report_area      -depth 6        > $outdir/reports/area_hier.rpt
report_timing    -max_paths 20   > $outdir/reports/timing.rpt
# Reg-to-reg-only report. Genus 21.1 doesn't take `-path_group`; use the
# `-from`/`-to` endpoint filter against the design's edge-triggered regs
# to scope the report. Defensively wrapped in catch -- in environments
# where the registers collection is empty (purely combinational top),
# we fall back to the default report_timing.
if { [catch {
    report_timing -from [all_registers -edge_triggered] \
                  -to   [all_registers -edge_triggered] \
                  -max_paths 20 > $outdir/reports/timing_reg2reg.rpt
} err] } {
    puts "WARNING: reg2reg timing report skipped ($err)"
}
report_power                     > $outdir/reports/power.rpt
report_gates                     > $outdir/reports/gates.rpt
report_qor                       > $outdir/reports/qor.rpt
report_messages                  > $outdir/reports/messages.rpt
report_hierarchy                 > $outdir/reports/hierarchy.rpt

write_hdl > $outdir/stream_pipeline.v
write_sdc > $outdir/stream_pipeline.sdc

puts ""
puts "=================================================================="
puts " Hierarchical synth complete."
puts " Tag:       $tag"
puts " Top:       stream_pipeline"
puts " ARRAY_DIM: $N"
puts " Clock:     ${CLK_PER} ns"
puts " Outdir:    $outdir/"
puts "=================================================================="

# Exit cleanly so a shell driver advances. Without this, `genus -files ...`
# drops to an interactive prompt after the source completes.
exit
