# =============================================================================
# run_genus_engine.do -- Synthesize ONE compute lane (accel_engine) with the
# new mixed-precision MAC PE (Q4.4 multiplier + Q16.16 accumulator).
#
# Why one lane? Even with the Q4.4 multiplier shrink (~16x per-MAC area),
# the full compute_core / accel_top is still huge -- 16 lanes * 4096 MACs.
# accel_engine is exactly one of those 16 identical lanes; synthesizing it
# alone gives a real per-lane area/timing/power result that scales by 16
# for the full chip (plus tile_dispatcher + DMA overhead).
#
# Why this is likely to succeed now (vs the m2/syn version that OOM'd):
#   * The flat netlist was ~33M generic gates on Q16.16 (dominated by 4096
#     32x32 multipliers). Each multiplier dropped from ~5K gates to ~0.3K
#     when MULT_W went 32 -> 8, so total per-engine is now ~6-8M gates.
#   * Peak Genus memory should land near 15-20 GB rather than 65 GB. Phobos
#     should handle it comfortably.
#   * tile_buffer with NUM_RD_PORTS=64 is still a contributor (~2-3M gates
#     of mux network) but no longer overshadowed by the multiplier farm.
#
# Usage (from project/RTL/):
#     genus -files run_genus_engine.do -log accel_engine.log
#
# Produces under project/RTL/out_engine/:
#   - accel_engine.v             gate-level netlist
#   - accel_engine.sdc / .sdf    forward constraints
#   - reports/*.rpt              area / timing / power / gates / qor
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

# -----------------------------------------------------------------------------
# 2. Technology libraries (same SAED32 RVT TT as the block script)
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
# 3. Read RTL -- only the subset reachable from accel_engine.
#
# Excluded vs a full-chip flow: tile_loader, tile_writer, sram_bank,
# scratchpad_ctrl, address_gen, dma_engine, double_buffer_ctrl,
# mode_decoder, tile_scheduler, tile_dispatcher, csr_block, accel_top,
# accel_chiplet_wrapper. accel_engine exposes its SRAM port at the
# boundary so the scratchpad lives outside.
# -----------------------------------------------------------------------------
puts ">>> Reading RTL (accel_engine subset)..."

# Package + interfaces
read_hdl -sv accel_pkg.sv
read_hdl -sv stream_if.sv
read_hdl -sv sram_if.sv
read_hdl -sv cmd_if.sv
read_hdl -sv tile_if.sv
read_hdl -sv ctrl_if.sv
read_hdl -sv status_if.sv

# Datapath leaf cells used by stream_pipeline / fused_postproc
read_hdl -sv mac_pe.sv
read_hdl -sv systolic_array_64x64.sv
read_hdl -sv gelu_lut.sv
read_hdl -sv exp_lut.sv
read_hdl -sv adder_tree.sv
read_hdl -sv gelu_unit.sv
read_hdl -sv gelu_grad_unit.sv
read_hdl -sv softmax_unit.sv
read_hdl -sv causal_mask_unit.sv
read_hdl -sv divider_or_reciprocal_unit.sv
read_hdl -sv fused_postproc_unit.sv

# Pipeline / flow control
read_hdl -sv pipeline_stage.sv
read_hdl -sv skid_buffer.sv
read_hdl -sv stream_mux.sv

# Tile buffer (4 instances per lane)
read_hdl -sv tile_buffer.sv

# Streaming compute pipeline
read_hdl -sv stream_pipeline.sv

# Per-lane control + perf
read_hdl -sv accel_controller.sv
read_hdl -sv perf_counter_block.sv

# Lane engine (synth top)
read_hdl -sv accel_engine.sv

# -----------------------------------------------------------------------------
# 4. Elaborate
# -----------------------------------------------------------------------------
set TOP accel_engine
puts ">>> Elaborating $TOP..."
elaborate $TOP
puts ">>> Elaboration done."

# -----------------------------------------------------------------------------
# 5. Constraints -- 1 GHz clock, async-low reset, modest I/O delays.
# -----------------------------------------------------------------------------
puts ">>> Applying constraints..."
set CLK_PORT  clk
set RST_PORT  rst_n
set CLK_PER   1.0
set IO_DELAY  [expr {$CLK_PER * 0.3}]

create_clock -name clk -period $CLK_PER [get_ports $CLK_PORT]
set_clock_uncertainty 0.05 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# Reset is async; cut timing through it
set_false_path -from [get_ports $RST_PORT]

# I/O delays on everything except clk and rst_n
set_input_delay  $IO_DELAY -clock clk [remove_from_collection \
    [all_inputs] [get_ports [list $CLK_PORT $RST_PORT]]]
set_output_delay $IO_DELAY -clock clk [all_outputs]

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
puts " Genus per-lane run complete (mixed precision)."
puts " Top:        $TOP  (one of 16 identical lanes)"
puts " Clock:      ${CLK_PER} ns (1 GHz)"
puts " Multiplier: Q4.4 (8-bit) -> Q8.8 product"
puts " Accumulator: Q16.16 (32-bit)"
puts " Netlist:    out_engine/accel_engine.v"
puts " Reports:    out_engine/reports/"
puts ""
puts " Full-chip area estimate: 16 x per-lane numbers"
puts " + tile_dispatcher + DMA + scratchpad overhead."
puts "=============================================="

# exit
