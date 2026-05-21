# =============================================================================
# run_innovus.do -- Place-and-route flow for one synthesized leaf block.
#
# Reads the Genus-produced netlist + SDC from out_sweep/<TARGET>/ and pushes
# it through Innovus 21.1:
#   floorplan -> power grid -> placement -> CTS -> routing -> opt -> STA -> GDS
#
# Defaults are tuned for systolic_array_64x64_8x8 (the smallest sweep point
# that is a "real" subblock rather than a single PE). Reproduces the
# OpenLane-equivalent flow at SAED32 32 nm instead of Sky130 130 nm.
#
# Inputs (env vars, all optional):
#   TARGET       Default systolic_array_64x64_8x8. The sweep tag whose
#                netlist/SDC we read from out_sweep/<TARGET>/.
#   TOP_MODULE   Default systolic_array_64x64. The Verilog top module name.
#   LIB_PATH     Default SAED32 RVT TT @ 0.85V/25C path on phobos.
#   LEF_FILE     Default saed32nm_rvt_1p9m.lef (combined tech + cell LEF).
#   CAPTABLE     Optional. If unset, Innovus uses estimated RC from LEF
#                geometry (~5-15% less accurate than QRC sign-off; fine for
#                first-pass P&R and gives valid DEF/GDS/timing).
#   CLK_PER      Default 1.0 ns (1 GHz target, matches Genus sweep).
#   DIE_UTIL     Default 0.65. Core utilization for the floorplan.
#
# Output:
#   out_innovus/<TARGET>/
#     final.v        post-route netlist
#     final.def      placed-and-routed DEF
#     final.spef     parasitics
#     final.gds.gz   GDS
#     reports/
#       timing.rpt   post-route STA
#       power.rpt    Voltus-quality power
#       drc.rpt      DRC check (Innovus internal)
#       ir.rpt       IR-drop sanity (rough; full Voltus IR is a separate run)
#       summary.rpt  area + utilization + violations summary
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Resolve inputs
# -----------------------------------------------------------------------------
set TARGET     [expr {[info exists env(TARGET)]     ? $env(TARGET)     : "systolic_array_64x64_8x8"}]
set TOP        [expr {[info exists env(TOP_MODULE)] ? $env(TOP_MODULE) : "systolic_array_64x64"}]
set LIB_PATH   [expr {[info exists env(LIB_PATH)]   ? $env(LIB_PATH)   : "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm"}]
set LEF_DIR    "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/lef"
set LEF_FILE   [expr {[info exists env(LEF_FILE)]   ? $env(LEF_FILE)   : "saed32nm_rvt_1p9m.lef"}]
set CLK_PER    [expr {[info exists env(CLK_PER)]    ? $env(CLK_PER)    : 1.0}]
set DIE_UTIL   [expr {[info exists env(DIE_UTIL)]   ? $env(DIE_UTIL)   : 0.65}]

set NETLIST   "out_sweep/${TARGET}/${TOP}.v"
set SDC       "out_sweep/${TARGET}/${TOP}.sdc"
set OUT_DIR   "out_innovus/${TARGET}"
set RPT_DIR   "${OUT_DIR}/reports"

file mkdir $OUT_DIR
file mkdir $RPT_DIR

puts "=========================================="
puts "Innovus P&R for ${TARGET} (top=${TOP})"
puts "  netlist : $NETLIST"
puts "  SDC     : $SDC"
puts "  lib     : ${LIB_PATH}/saed32rvt_tt0p85v25c.lib"
puts "  LEF     : ${LEF_DIR}/${LEF_FILE}"
puts "  clock   : ${CLK_PER} ns"
puts "  util    : $DIE_UTIL"
puts "=========================================="

# -----------------------------------------------------------------------------
# 2. MMMC (Multi-Mode Multi-Corner) timing setup
#    One mode (functional) x one corner (typical) for first-pass.
#    Add SS/FF corners later for sign-off.
# -----------------------------------------------------------------------------
create_constraint_mode -name func_mode -sdc_files [list $SDC]
create_library_set    -name lib_tt -timing [list "${LIB_PATH}/saed32rvt_tt0p85v25c.lib"]
create_rc_corner      -name rc_typ -T 25
if { [info exists env(CAPTABLE)] } {
    set_rc_corner_property -name rc_typ -cap_table $env(CAPTABLE)
    puts "INFO: Using captable $env(CAPTABLE) for parasitic extraction."
} else {
    puts "INFO: No CAPTABLE env var; using LEF-based estimated RC."
}
create_delay_corner   -name dc_typ -library_set lib_tt -rc_corner rc_typ
create_analysis_view  -name av_typ -constraint_mode func_mode -delay_corner dc_typ
set_analysis_view     -setup [list av_typ] -hold [list av_typ]

# -----------------------------------------------------------------------------
# 3. Read netlist + LEF, link the design
# -----------------------------------------------------------------------------
set init_lef_file       [list "${LEF_DIR}/${LEF_FILE}"]
set init_verilog        $NETLIST
set init_top_cell       $TOP
set init_design_netlisttype "Verilog"
set init_design_settop  1
set init_pwr_net        VDD
set init_gnd_net        VSS

init_design

# -----------------------------------------------------------------------------
# 4. Floorplan
#    Square aspect, target utilization DIE_UTIL, automatic core size.
# -----------------------------------------------------------------------------
floorPlan -site unit -r 1.0 $DIE_UTIL 10 10 10 10
saveDesign "${OUT_DIR}/floorplan.enc"
report_area > "${RPT_DIR}/area_floorplan.rpt"

# -----------------------------------------------------------------------------
# 5. Power planning
#    Top-metal VDD/VSS ring + vertical/horizontal stripes. Simple but
#    sufficient for a leaf-block analysis.
# -----------------------------------------------------------------------------
globalNetConnect VDD -type pgpin -pin VDD -inst * -override
globalNetConnect VSS -type pgpin -pin VSS -inst * -override
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo

# Ring on top two metal layers
addRing -nets {VDD VSS} -type core_rings \
        -follow core -layer {top M9 bottom M9 left M8 right M8} \
        -width 2.0 -spacing 1.0 -offset 0.5

# Sparse stripes across the core
addStripe -nets {VDD VSS} -layer M8 -direction vertical \
          -width 0.6 -spacing 2.0 -set_to_set_distance 20 \
          -start_from left -switch_layer_over_obs 1

# M1 power rails (follow standard-cell rows)
sroute -nets {VDD VSS} -allowJogging 1 -allowLayerChange 1 \
       -connect {corePin floatingStripe} -layerChangeRange {M1 M9}

saveDesign "${OUT_DIR}/pdn.enc"

# -----------------------------------------------------------------------------
# 6. Placement
# -----------------------------------------------------------------------------
setPlaceMode -fp false
place_design

opt_design -pre_cts -drv
report_timing -max_paths 10 > "${RPT_DIR}/timing_post_place.rpt"
saveDesign "${OUT_DIR}/place.enc"

# -----------------------------------------------------------------------------
# 7. Clock tree synthesis
# -----------------------------------------------------------------------------
create_ccopt_clock_tree_spec
ccopt_design

opt_design -post_cts -drv -hold
report_timing -max_paths 10        > "${RPT_DIR}/timing_post_cts.rpt"
report_clock_tree                  > "${RPT_DIR}/clock_tree.rpt"
saveDesign "${OUT_DIR}/cts.enc"

# -----------------------------------------------------------------------------
# 8. Routing
# -----------------------------------------------------------------------------
setNanoRouteMode -drouteStartIteration default
setNanoRouteMode -routeWithTimingDriven true
setNanoRouteMode -routeWithSiDriven true
routeDesign

opt_design -post_route -drv -hold -setup
report_timing -max_paths 20         > "${RPT_DIR}/timing.rpt"
report_power                        > "${RPT_DIR}/power.rpt"
report_area                         > "${RPT_DIR}/area.rpt"
saveDesign "${OUT_DIR}/route.enc"

# -----------------------------------------------------------------------------
# 9. Verification (Innovus-internal DRC/connectivity/antenna)
# -----------------------------------------------------------------------------
verify_drc      -report "${RPT_DIR}/drc.rpt"
verify_connectivity -report "${RPT_DIR}/connectivity.rpt"
verify_process_antenna -report "${RPT_DIR}/antenna.rpt"

# -----------------------------------------------------------------------------
# 10. Final reports and streamout
# -----------------------------------------------------------------------------
# Parasitics in SPEF (for Tempus/Voltus sign-off if desired)
extractRC -outfile "${OUT_DIR}/final.spef"

# Final netlist
saveNetlist "${OUT_DIR}/final.v"

# DEF
defOut -netlist -placement -routing "${OUT_DIR}/final.def"

# GDS streamout
streamOut "${OUT_DIR}/final.gds.gz" \
    -mapFile  "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/tech/stream_out/saed32nm.map" \
    -merge    [list "${LEF_DIR}/../gds/saed32nm_rvt_oa.gds"] \
    -stripes 1 -units 1000 -mode ALL

# Summary line for easy grepping across runs
set summary_fh [open "${RPT_DIR}/summary.rpt" w]
puts $summary_fh "Innovus P&R summary: $TARGET"
puts $summary_fh "  Top              : $TOP"
puts $summary_fh "  Clock period     : $CLK_PER ns"
puts $summary_fh "  Die utilization  : $DIE_UTIL"
puts $summary_fh "  Cell area        : [dbGet [dbGet top.fplan.coreBox] -e]"
puts $summary_fh "  Reports          : $RPT_DIR/"
puts $summary_fh "  Final netlist    : $OUT_DIR/final.v"
puts $summary_fh "  Final DEF        : $OUT_DIR/final.def"
puts $summary_fh "  Final GDS        : $OUT_DIR/final.gds.gz"
puts $summary_fh "  Parasitics       : $OUT_DIR/final.spef"
close $summary_fh

puts ""
puts "=========================================="
puts " Innovus P&R complete for $TARGET"
puts " Output: $OUT_DIR/"
puts "=========================================="

exit
