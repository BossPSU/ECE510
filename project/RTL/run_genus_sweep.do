# =============================================================================
# run_genus_sweep.do -- Parameterized Genus synthesis driver for the M3
# characterization sweep (see Claude_sweep.md).
#
# One script handles every sweep point:
#   * systolic_array_64x64 at N in {1, 2, 4, 8, 16, 32}
#   * stream_pipeline      at N in {1, 2, 4, 8, 16, 32}
#   * any leaf fusion block (gelu_unit, softmax_unit, ...) with default params
#   * tile_buffer at NUM_RD_PORTS in {1, 64} (TILE_DIM=64 default)
#   * tile_buffer at TILE_DIM in {1, 2, 4, 8, 16, 32} (BUF_DIM sweep)
#   * softmax_unit at VEC_LEN in {1, 2, 4, 8, 16, 32, 64} (SOFTMAX_VEC sweep)
#   * softmax_unit_lut at VEC_LEN in {1, 2, 4, 8, 16, 32, 64} (SOFTMAX_VEC sweep)
#   * adder_tree  at NUM_INPUTS in {2, 4, 8, 16, 32} (ADDER_N sweep)
#
# Inputs (env vars):
#   SYNTH_TOP    Required. Module to elaborate as the synth top.
#   ARRAY_N      Optional, default 1. Sets ROWS/COLS (systolic_array_64x64)
#                or ARRAY_DIM (stream_pipeline). Ignored for leaf tops.
#   BUF_NRD      Optional, default 1. Sets NUM_RD_PORTS for tile_buffer.
#   BUF_DIM      Optional, default 64. Sets TILE_DIM for tile_buffer. When
#                set, output tag becomes tile_buffer_d<DIM>_p<NRD>.
#   SOFTMAX_VEC  Optional, default 64. Sets VEC_LEN for softmax_unit. When
#                set, output tag becomes softmax_unit_v<VEC>.
#   ADDER_N      Optional, default 64. Sets NUM_INPUTS for adder_tree. When
#                set, output tag becomes adder_tree_n<N>.
#   LIB_PATH     Optional. Defaults to SAED32 RVT on phobos.
#   LIB_FILE     Optional. Specific .lib filename in LIB_PATH.
#
# Output:
#   out_sweep/<tag>/{*.v, reports/{area,timing,power,gates,qor}.rpt}
#   where <tag> = "<TOP>_<N>x<N>" for arrays, "tile_buffer_p<NRD>" or
#   "tile_buffer_d<DIM>_p<NRD>" for buffer variants, "softmax_unit_v<V>",
#   "adder_tree_n<N>" for sized vector leaves, or just "<TOP>" for
#   everything else.
#
# Usage:
#   SYNTH_TOP=systolic_array_64x64 ARRAY_N=8 \
#       genus -files run_genus_sweep.do -log sys_8x8.log
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Tool setup
# -----------------------------------------------------------------------------
set_db init_lib_search_path { . $env(LIB_PATH) }
set_db init_hdl_search_path { . }

# Keep worker count conservative (4) -- matches run_genus_engine.do post-OOM
# tuning. Higher worker counts COW-balloon peak memory on the 32x32 points.
set_db max_cpus_per_server 4
set_db super_thread_servers "localhost"

set_db hdl_error_on_blackbox  true
set_db hdl_track_filename_row_col true
set_db information_level 7

# -----------------------------------------------------------------------------
# 2. Resolve sweep parameters from env
# -----------------------------------------------------------------------------
if { ![info exists env(SYNTH_TOP)] } {
    error "SYNTH_TOP env var is required (e.g. systolic_array_64x64, stream_pipeline, gelu_unit, ...)."
}
set TOP $env(SYNTH_TOP)

set N 1
if { [info exists env(ARRAY_N)] } { set N $env(ARRAY_N) }

set NRD 1
if { [info exists env(BUF_NRD)] } { set NRD $env(BUF_NRD) }

set DIM 64
set DIM_explicit 0
if { [info exists env(BUF_DIM)] } {
    set DIM $env(BUF_DIM)
    set DIM_explicit 1
}

set SMV 64
set SMV_explicit 0
if { [info exists env(SOFTMAX_VEC)] } {
    set SMV $env(SOFTMAX_VEC)
    set SMV_explicit 1
}

set ADN 64
set ADN_explicit 0
if { [info exists env(ADDER_N)] } {
    set ADN $env(ADDER_N)
    set ADN_explicit 1
}

# Choose output-dir tag from top + relevant param. Legacy tags
# (tile_buffer_p<NRD>, softmax_unit, adder_tree) are preserved when the
# corresponding env var is not set, so already-completed sweep points
# keep their directory name.
if { $TOP eq "systolic_array_64x64" || $TOP eq "stream_pipeline" } {
    set tag "${TOP}_${N}x${N}"
} elseif { $TOP eq "tile_buffer" } {
    if { $DIM_explicit } {
        set tag "${TOP}_d${DIM}_p${NRD}"
    } else {
        set tag "${TOP}_p${NRD}"
    }
} elseif { $TOP eq "softmax_unit" || $TOP eq "softmax_unit_lut" } {
    if { $SMV_explicit } {
        set tag "${TOP}_v${SMV}"
    } else {
        set tag "${TOP}"
    }
} elseif { $TOP eq "adder_tree" } {
    if { $ADN_explicit } {
        set tag "${TOP}_n${ADN}"
    } else {
        set tag "${TOP}"
    }
} else {
    set tag "${TOP}"
}

puts "INFO: SYNTH_TOP = $TOP, ARRAY_N = $N, BUF_DIM = $DIM, BUF_NRD = $NRD, SOFTMAX_VEC = $SMV, ADDER_N = $ADN, tag = $tag"

# -----------------------------------------------------------------------------
# 3. Technology library (SAED32 RVT TT @ 0.85V / 25C, same as other scripts)
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
# 4. Read RTL (same superset used by run_genus_engine.do -- Genus only
#    elaborates what's reachable from $TOP, so reading extras is cheap)
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

# Datapath leaves
read_hdl -sv mac_pe.sv
read_hdl -sv mac_pe_piped.sv
read_hdl -sv mac_pe_piped4.sv
read_hdl -sv systolic_array_64x64.sv
read_hdl -sv gelu_lut.sv
read_hdl -sv exp_lut.sv
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

# Per-lane control + perf
read_hdl -sv accel_controller.sv
read_hdl -sv perf_counter_block.sv

# -----------------------------------------------------------------------------
# 5. Elaborate with the right -parameters override for this top
# -----------------------------------------------------------------------------
puts ">>> Elaborating $TOP (tag=$tag)..."

# Genus -parameters takes a POSITIONAL list of parameter VALUES (not
# name/value pairs). The list order must match the order parameters are
# declared in the module. Pass through current defaults for params we
# aren't sweeping.
#   systolic_array_64x64: parameter order = (ROWS, COLS, DATA_WIDTH)
#   stream_pipeline     : parameter order = (DATA_WIDTH, ARRAY_DIM)
#   tile_buffer         : parameter order = (DATA_WIDTH, TILE_DIM, NUM_RD_PORTS)
#   softmax_unit        : parameter order = (DATA_WIDTH, VEC_LEN)
#   softmax_unit_lut    : parameter order = (DATA_WIDTH, VEC_LEN, N_LUT_BANKS)
#   adder_tree          : parameter order = (DATA_WIDTH, NUM_INPUTS)
if { $TOP eq "systolic_array_64x64" } {
    elaborate $TOP -parameters [list $N $N 32]
} elseif { $TOP eq "stream_pipeline" } {
    elaborate $TOP -parameters [list 32 $N]
} elseif { $TOP eq "tile_buffer" } {
    elaborate $TOP -parameters [list 32 $DIM $NRD]
} elseif { $TOP eq "softmax_unit" } {
    elaborate $TOP -parameters [list 32 $SMV]
} elseif { $TOP eq "softmax_unit_lut" } {
    # softmax_unit_lut parameter order: (DATA_WIDTH, VEC_LEN, N_LUT_BANKS).
    # N_LUT_BANKS default = min(VEC_LEN, 8); replicate that here.
    set NBANKS [expr {$SMV < 8 ? $SMV : 8}]
    elaborate $TOP -parameters [list 32 $SMV $NBANKS]
} elseif { $TOP eq "adder_tree" } {
    elaborate $TOP -parameters [list 32 $ADN]
} else {
    elaborate $TOP
}
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 6. Constraints -- 1 GHz clock, async-low reset (when present)
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set CLK_PER  1.0
set IO_DELAY [expr {$CLK_PER * 0.3}]

# Some leaves (e.g. causal_mask_unit) are purely combinational. Only apply
# clock-related constraints when those ports actually exist on this top.
set has_clk [expr {[llength [get_ports clk]] > 0}]
set has_rst [expr {[llength [get_ports rst_n]] > 0}]

if { $has_clk } {
    create_clock -name clk -period $CLK_PER [get_ports clk]
    set_clock_uncertainty 0.05 [get_clocks clk]
    set_clock_transition  0.05 [get_clocks clk]
}
if { $has_rst } {
    set_false_path -from [get_ports rst_n]
}

set io_excludes [list]
foreach p {clk rst_n} {
    if { [llength [get_ports $p]] > 0 } { lappend io_excludes [get_ports $p] }
}
if { [llength $io_excludes] > 0 } {
    set in_ports [remove_from_collection [all_inputs] [join $io_excludes]]
} else {
    set in_ports [all_inputs]
}

if { $has_clk } {
    set_input_delay  $IO_DELAY -clock clk $in_ports
    set_output_delay $IO_DELAY -clock clk [all_outputs]
}

if { [catch {set_driving_cell -lib_cell INVX1_RVT [all_inputs]} err] } {
    puts "WARNING: set_driving_cell INVX1_RVT failed ($err); inputs left ideal."
}
set_load 0.05 [all_outputs]

# -----------------------------------------------------------------------------
# 7. Synthesize
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
# 8. Reports + netlist
# -----------------------------------------------------------------------------
puts ">>> Writing reports..."
report_area              > $outdir/reports/area.rpt
report_area      -depth 3 > $outdir/reports/area_hier.rpt
report_timing    -max_paths 10 > $outdir/reports/timing.rpt
report_power     > $outdir/reports/power.rpt
report_gates     > $outdir/reports/gates.rpt
report_qor       > $outdir/reports/qor.rpt
report_messages  > $outdir/reports/messages.rpt

write_hdl > $outdir/$TOP.v
write_sdc > $outdir/$TOP.sdc

puts ""
puts "=============================================="
puts " Sweep point complete: tag=$tag"
puts " Top:       $TOP"
puts " ARRAY_N:   $N    BUF_NRD: $NRD"
puts " Clock:     ${CLK_PER} ns (1 GHz)"
puts " Outdir:    $outdir/"
puts "=============================================="

# Exit Genus cleanly so the shell driver advances to the next sweep
# point. Without this, `genus -files run_genus_sweep.do` drops into an
# interactive prompt after the source completes and the shell loop hangs.
exit
