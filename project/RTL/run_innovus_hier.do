# =============================================================================
# run_innovus_hier.do -- Place-and-route flow for the hierarchical
# stream_pipeline_64x64 netlist produced by run_genus_hier.do.
#
# Phase 4 of the phobos hierarchical synth plan.
#
# Reads from:
#   out_sweep/stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier/
#     stream_pipeline.v    (hier netlist, preserved boundaries)
#     stream_pipeline.sdc  (constraints from Genus)
#
# Differs from the per-leaf run_innovus.do in:
#   - Larger default floorplan (auto-sized to projected post-PnR area,
#     with a 1.5x safety margin) targeting 60% util at ARRAY_DIM=64.
#   - Denser power grid -- 32 nm stream_pipeline draws ~1 W at 1 GHz, so
#     stripes are 2-3x denser than the per-leaf script.
#   - `set_proto_mode -default keep_design` -- propagates the preserve
#     boundaries from Genus into Innovus so placement keeps mac_pe_piped
#     and tile_buffer as soft macros. (Drops to flat at routing time.)
#   - Saves a checkpoint .enc.dat at every major stage so re-runs from
#     post-CTS or post-route are one restoreDesign away.
#
# Inputs (env vars, all optional):
#   ARRAY_N      Default 64.
#   TARGET       Default stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier.
#   TOP_MODULE   Default stream_pipeline.
#   LIB_PATH     Default SAED32 RVT TT on phobos.
#   LEF_FILE     Default saed32nm_rvt_1p9m.lef.
#   CAPTABLE     Optional. If unset, Innovus uses LEF-derived estimated RC
#                (~5-15% looser than QRC sign-off; fine for first-pass P&R
#                and gives a valid DEF/GDS/SPEF for the M5 deliverable).
#   CLK_PER      Default 1.0 ns. Matches Genus synth target.
#   DIE_UTIL     Default 0.60. Core utilization for the floorplan.
#
# Output:
#   out_innovus/${TARGET}/
#     floorplan.enc.dat   post-floorplan snapshot
#     pdn.enc.dat         post-power-grid snapshot
#     place.enc.dat       post-placement snapshot
#     cts.enc.dat         post-CTS snapshot
#     route.enc.dat       post-route snapshot  <-- read by run_sta_mc.do
#     final.v             post-route netlist
#     final.def           placed-and-routed DEF
#     final.spef          post-route parasitics (RC, not QRC unless CAPTABLE set)
#     final.gds.gz        GDS (merged with std-cell GDS)
#     reports/
#       area_*.rpt        area at each stage
#       timing_*.rpt      STA at each stage
#       clock_tree.rpt    CTS report
#       drc.rpt           DRC (Innovus internal)
#       connectivity.rpt  connectivity check
#       antenna.rpt       process antenna check
#       summary.rpt       human-readable single-page summary
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Resolve inputs
# -----------------------------------------------------------------------------
set ARRAY_N    [expr {[info exists env(ARRAY_N)]    ? $env(ARRAY_N)    : 64}]
set TARGET     [expr {[info exists env(TARGET)]     ? $env(TARGET)     : "stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier"}]
# TOP_MODULE = the cell name as it appears *inside* the netlist. Genus
# embeds parameter values into the module name during elaboration, so
# the elaborated top is, e.g.,
#   stream_pipeline_DATA_WIDTH32_ARRAY_DIM64_USE_LUT_SOFTMAX1_..._USE_PIPED_MAC1
# Innovus's init_top_cell needs that mangled name. The netlist FILE
# on disk is still named stream_pipeline.v though, so NETLIST_NAME is
# tracked separately.
set TOP_DEFAULT "stream_pipeline_DATA_WIDTH32_ARRAY_DIM${ARRAY_N}_USE_LUT_SOFTMAX1_USE_LUT_GELU1_USE_PIPED4_MAC1_USE_PIPED_MAC1"
set TOP        [expr {[info exists env(TOP_MODULE)]   ? $env(TOP_MODULE)   : $TOP_DEFAULT}]
set NETLIST_NAME [expr {[info exists env(NETLIST_NAME)] ? $env(NETLIST_NAME) : "stream_pipeline"}]
set LIB_PATH   [expr {[info exists env(LIB_PATH)]   ? $env(LIB_PATH)   : "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm"}]
set LEF_DIR    "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/lef"
# SAED32 ships LEFs in two tiers:
#   1. Technology LEF (TECH_LEF): defines metal layers, vias, sites, routing
#      rules. Innovus MUST load this first or layer 'M1' is unknown.
#   2. Standard-cell LEF (LEF_FILE): macros that reference the tech layers.
#
# On the phobos PDK install, the only tech LEF found is at
#   /pkgs/synopsys/2020/32_28nm/SAED32_EDK/src/oa/saed32_sram_lp_dual_oa/new/newtech.lef
# (a different subtree from the std-cell LEF in lib/stdcell_rvt/lef/),
# so TECH_LEF defaults to that absolute path here.
#
# TECH_LEF / LEF_FILE may be either a bare filename (resolved against
# LEF_DIR) or an absolute path (used as-is).
set TECH_LEF   [expr {[info exists env(TECH_LEF)]   ? $env(TECH_LEF)   : "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/src/oa/saed32_sram_lp_dual_oa/new/newtech.lef"}]
set LEF_FILE   [expr {[info exists env(LEF_FILE)]   ? $env(LEF_FILE)   : "saed32nm_rvt_1p9m.lef"}]
# Timing library: use the regular (non-PG) TT 0.85V/25C variant.
#
# History: defaulted to the _pg_ variant earlier in this flow, thinking
# Innovus's globalNetConnect + sroute would want explicit PG pins. Turns
# out on this PDK install the _pg_ file is a 150 KB stub with no cell
# bodies at all (vs 11 MB for the non-PG variant), so it loaded "fine"
# but CTS later failed with IMPCCOPT-4334 -- the buffer/inverter cells
# specified in cts_*_cells weren't in the loaded lib because no cells
# were in the loaded lib. Switching back to the non-PG variant.
set LIB_TIMING_FILE [expr {[info exists env(LIB_FILE)] ? $env(LIB_FILE) : "saed32rvt_tt0p85v25c.lib"}]

# Resolve to absolute paths -- prepend LEF_DIR (or LIB_PATH) only for
# bare filenames.
set TECH_LEF_PATH      [expr {[string index $TECH_LEF        0] eq "/" ? $TECH_LEF        : "${LEF_DIR}/${TECH_LEF}"}]
set LEF_FILE_PATH      [expr {[string index $LEF_FILE        0] eq "/" ? $LEF_FILE        : "${LEF_DIR}/${LEF_FILE}"}]
set LIB_TIMING_PATH    [expr {[string index $LIB_TIMING_FILE 0] eq "/" ? $LIB_TIMING_FILE : "${LIB_PATH}/${LIB_TIMING_FILE}"}]
set CLK_PER    [expr {[info exists env(CLK_PER)]    ? $env(CLK_PER)    : 1.333}]
set DIE_UTIL   [expr {[info exists env(DIE_UTIL)]   ? $env(DIE_UTIL)   : 0.60}]
# CPU count for the placement / route / CTS multi-threaded engines.
# Without setMultiCpuUsage, Innovus defaults to single-threaded; on this
# design that turns ~2-4h of placement into 8-16h. Phobos's Innovus
# license allows up to 8 jobs.
set NCPU       [expr {[info exists env(NCPU)]       ? $env(NCPU)       : 8}]

# Resume from a checkpoint instead of restarting from init_design.
# Pass RESUME_FROM=pdn to skip init/floorplan/PDN and start at place_design.
# Pass RESUME_FROM=place to skip up through pre-CTS opt.
# Pass RESUME_FROM=cts   to skip up through CTS.
# Pass RESUME_FROM=route to skip up through routing (i.e. just rerun final opt
#                                                  + reports).
# Default = "none" (full flow from init_design).
set RESUME_FROM [expr {[info exists env(RESUME_FROM)] ? $env(RESUME_FROM) : "none"}]

# Flow effort (express / standard / extreme). express cuts placement +
# CTS + route runtime ~3x at a modest QoR cost; good for a first-pass
# closure check. standard is the Innovus default. extreme is for
# sign-off.
#
# Innovus 21.1 implements this via setDesignMode -flowEffort, NOT
# setPlaceMode -placeEffort (which doesn't exist in this version).
set FLOW_EFFORT [expr {[info exists env(FLOW_EFFORT)] ? $env(FLOW_EFFORT) :
                       [expr {[info exists env(PLACE_EFFORT)] ?
                              [string map {low express medium standard high extreme} $env(PLACE_EFFORT)] :
                              "standard"}]}]

set NETLIST    "out_sweep/${TARGET}/${NETLIST_NAME}.v"
set SDC        "out_sweep/${TARGET}/${NETLIST_NAME}.sdc"
set OUT_DIR    "out_innovus/${TARGET}"
set RPT_DIR    "${OUT_DIR}/reports"

file mkdir $OUT_DIR
file mkdir $RPT_DIR

puts "=========================================="
puts "Innovus hierarchical P&R for ${TARGET}"
puts "  netlist : $NETLIST"
puts "  SDC     : $SDC"
puts "  lib     : ${LIB_TIMING_PATH}"
puts "  techLEF : ${TECH_LEF_PATH}"
puts "  cellLEF : ${LEF_FILE_PATH}"
puts "  clock   : ${CLK_PER} ns"
puts "  util    : $DIE_UTIL"
puts "  resume  : $RESUME_FROM"
puts "  flow eff: $FLOW_EFFORT"
puts "=========================================="

# -----------------------------------------------------------------------------
# 2. MMMC (Multi-Mode Multi-Corner) -- TT-only for in-flow optimization.
#    SS + FF corners are added post-route by run_sta_mc.do.
#
# In Innovus 21.1 the create_* / set_analysis_view ordering is brittle:
#   - set_analysis_view BEFORE init_design fires TCLCMD-1230
#     ("requires an initialized design")
#   - set_analysis_view AFTER init_design fires TCLCMD-1239
#     ("initialized in physical-only mode")
#
# The robust workaround is to write the entire MMMC setup (including
# set_analysis_view) into a separate Tcl file and point Innovus at it
# via init_mmmc_file. init_design then reads + binds the MMMC during
# initialization, sidestepping both ordering errors.
# -----------------------------------------------------------------------------
set MMMC_FILE "${OUT_DIR}/mmmc.tcl"
set fh [open $MMMC_FILE w]
puts $fh "# Auto-generated by run_innovus_hier.do -- DO NOT EDIT BY HAND."
puts $fh "create_constraint_mode -name func_mode -sdc_files \[list $SDC\]"
puts $fh "create_library_set    -name lib_tt -timing \[list $LIB_TIMING_PATH\]"
puts $fh "create_rc_corner      -name rc_typ -T 25"
if { [info exists env(CAPTABLE)] } {
    puts $fh "set_rc_corner_property -name rc_typ -cap_table $env(CAPTABLE)"
    puts "INFO: Using captable $env(CAPTABLE) for parasitic extraction."
} else {
    puts "INFO: No CAPTABLE env var; using LEF-based estimated RC."
}
puts $fh "create_delay_corner   -name dc_typ -library_set lib_tt -rc_corner rc_typ"
puts $fh "create_analysis_view  -name av_typ -constraint_mode func_mode -delay_corner dc_typ"
puts $fh "set_analysis_view     -setup \[list av_typ\] -hold \[list av_typ\]"
close $fh
puts ">>> Wrote MMMC setup to $MMMC_FILE"

# -----------------------------------------------------------------------------
# 3. Init / read netlist / load checkpoint
#
# Default: run init_design from scratch (LEF + Verilog + MMMC).
#
# Resume modes (set via RESUME_FROM env var, see top of script):
#   pdn    -> skip init/floorplan/PDN; restoreDesign from pdn.enc.dat,
#             jump straight to placement
#   place  -> restoreDesign from place.enc.dat, jump to CTS
#   cts    -> restoreDesign from cts.enc.dat, jump to routing
#   route  -> restoreDesign from route.enc.dat, jump to final opt/reports
# -----------------------------------------------------------------------------
if { $RESUME_FROM eq "none" } {
    # Full flow from init_design
    # Tech LEF MUST come first so 'M1', 'VIA12', etc. are defined before any
    # cell macro references them. Cell LEF second.
    set init_lef_file       [list \
        "${TECH_LEF_PATH}" \
        "${LEF_FILE_PATH}" \
    ]
    set init_verilog        $NETLIST
    set init_top_cell       $TOP
    set init_design_netlisttype "Verilog"
    set init_design_settop  1
    set init_pwr_net        VDD
    set init_gnd_net        VSS
    set init_mmmc_file      $MMMC_FILE

    init_design
} else {
    # Resume from a saved checkpoint. The checkpoint name maps from
    # RESUME_FROM:
    set ckpt_map(pdn)    "${OUT_DIR}/pdn.enc.dat"
    set ckpt_map(place)  "${OUT_DIR}/place.enc.dat"
    set ckpt_map(cts)    "${OUT_DIR}/cts.enc.dat"
    set ckpt_map(route)  "${OUT_DIR}/route.enc.dat"
    if { ![info exists ckpt_map($RESUME_FROM)] } {
        error "RESUME_FROM='$RESUME_FROM' invalid (use pdn|place|cts|route)"
    }
    set ckpt $ckpt_map($RESUME_FROM)
    if { ![file exists $ckpt] } {
        error "Checkpoint $ckpt not found -- run the prior stage first."
    }
    puts ">>> Restoring checkpoint $ckpt..."
    restoreDesign $ckpt $TOP
    puts ">>> Restore complete."
}

# -----------------------------------------------------------------------------
# Post-init fixes for SAED32 PDK quirks
# -----------------------------------------------------------------------------
# (a) Tell Innovus this is a 32nm design. Without -process, Innovus
# defaults to "Design Mode: 90nm" (seen in the failed placeDesign log),
# which messes up default RC modeling, cell-size heuristics, and routing
# track pitch.
#
# Innovus 21.1's -node flag is enumerated (N22 / N12 / N10 / ... no N32),
# so we drop -node and rely on -process 32 alone. That sets the RC and
# heuristic defaults to 32nm-class without picking a specific tape-out
# node target.
setDesignMode -process 32 -flowEffort $FLOW_EFFORT
puts ">>> design mode: process=32 flowEffort=$FLOW_EFFORT"

# Enable multi-CPU. Default is single-thread, which makes placement
# 4-8x slower than it needs to be. setMultiCpuUsage drives every
# Innovus multi-threaded engine (place, opt, route, CTS).
if { [catch {setMultiCpuUsage -localCpu $NCPU} err] } {
    puts "WARNING: setMultiCpuUsage failed ($err) -- single-threaded fallback."
} else {
    puts ">>> setMultiCpuUsage -localCpu $NCPU"
}

# Bump Innovus progress verbosity so multi-hour silent stretches stop
# being a mystery. Default verbosity 1 prints major stage markers only;
# 3 adds intermediate placement / route progress lines every minute or so.
if { [catch {set_db design_io_verbosity high} err] } {
    puts "WARNING: design_io_verbosity high not supported ($err)."
}

# (b) The SAED32 newtech.lef defines an MRDL (Metal Re-Distribution Layer
# for chip-top bumps) but has no SPACING / SPACINGTABLE rule for it. As a
# init_design warning this is fine; placeDesign promotes it to a fatal
# NRDB-416. Std-cell PnR for stream_pipeline does not need MRDL routing,
# so add a placeholder spacing rule + drop MRDL from the routing layer
# set entirely.
if { [catch {setLayerPreference MRDL -isVisible 0} err] } {
    puts "WARNING: setLayerPreference MRDL failed ($err) -- continuing."
}
if { [catch {set_db design_skip_layer_for_routing MRDL} err] } {
    puts "WARNING: skip_layer_for_routing MRDL not supported ($err)."
}
# Belt-and-suspenders: set a minimal default-rule spacing for MRDL so
# NRDB-416 stops firing even if the layer is referenced incidentally.
if { [catch {addLayerSpacing -layer MRDL -spacing 1.0} err] } {
    puts "WARNING: addLayerSpacing MRDL not supported ($err)."
}

# Propagate Genus preserve boundaries into Innovus's design hierarchy view
# so the placer treats mac_pe_piped, softmax_unit_lut, etc. as soft blocks.
# `set_proto_mode -default keep_design` is the Innovus-equivalent of Genus's
# preserve flag -- the protocell view of each submodule is kept distinct
# during placement and only collapsed at routing time. This is the second
# half of the OOM fix (the first half was the Genus preserve).
if { [catch {set_proto_mode -default keep_design} err] } {
    puts "WARNING: set_proto_mode keep_design failed ($err) -- continuing with default."
}

# -----------------------------------------------------------------------------
# 4. Floorplan (skipped if resuming from pdn/place/cts/route)
#    Square aspect, target utilization DIE_UTIL. Innovus auto-sizes the core
#    from the total cell area in the netlist; the explicit margins (10 um
#    on each side) leave room for the power ring.
# -----------------------------------------------------------------------------
if { $RESUME_FROM eq "none" } {
    floorPlan -site unit -r 1.0 $DIE_UTIL 10 10 10 10
    saveDesign "${OUT_DIR}/floorplan.enc"
    report_area > "${RPT_DIR}/area_floorplan.rpt"
    puts ">>> floorplan done"
}

# -----------------------------------------------------------------------------
# 5. Power planning -- denser PDN than the per-leaf script.
#    stream_pipeline at 1 GHz, ARRAY_DIM=64 draws ~1 W TDP (4096 MACs +
#    softmax + postproc). Stripe spacing dropped from 20 um (leaf) to
#    8 um to keep IR-drop under 5%.
# -----------------------------------------------------------------------------
if { $RESUME_FROM eq "none" } {
    globalNetConnect VDD -type pgpin -pin VDD -inst * -override
    globalNetConnect VSS -type pgpin -pin VSS -inst * -override
    globalNetConnect VDD -type tiehi
    globalNetConnect VSS -type tielo

    # Ring on top two metal layers (M9 top/bottom, M8 left/right)
    addRing -nets {VDD VSS} -type core_rings \
            -follow core -layer {top M9 bottom M9 left M8 right M8} \
            -width 3.0 -spacing 1.0 -offset 0.5

    # Denser stripes (8 um pitch vs 20 um in the leaf script)
    addStripe -nets {VDD VSS} -layer M8 -direction vertical \
              -width 0.8 -spacing 2.0 -set_to_set_distance 8 \
              -start_from left -switch_layer_over_obs 1
    addStripe -nets {VDD VSS} -layer M9 -direction horizontal \
              -width 0.8 -spacing 2.0 -set_to_set_distance 8 \
              -start_from bottom -switch_layer_over_obs 1

    # M1 power rails (follow standard-cell rows)
    sroute -nets {VDD VSS} -allowJogging 1 -allowLayerChange 1 \
           -connect {corePin floatingStripe} -layerChangeRange {M1 M9}

    saveDesign "${OUT_DIR}/pdn.enc"
    puts ">>> PDN done"
}

# -----------------------------------------------------------------------------
# 6. Placement
#    -fp false -> don't auto-re-floorplan; honor the one we just built.
#    Pre-CTS opt with -drv only -- hold violations are addressed post-CTS.
#
# Skipped if resuming from place/cts/route checkpoint.
# -----------------------------------------------------------------------------
if { $RESUME_FROM eq "none" || $RESUME_FROM eq "pdn" } {
    setPlaceMode -fp false
    puts ">>> place_design (flowEffort=$FLOW_EFFORT from setDesignMode)..."
    place_design

optDesign -preCTS -drv
report_timing -max_paths 10 > "${RPT_DIR}/timing_post_place.rpt"
    report_area                 > "${RPT_DIR}/area_post_place.rpt"
    saveDesign "${OUT_DIR}/place.enc"
    puts ">>> placement done"
}

# -----------------------------------------------------------------------------
# 7. Clock tree synthesis (skipped if resuming from cts/route)
#    100k+ flop endpoints in stream_pipeline at N=64 -- ccopt_design will
#    auto-build a multi-level H-tree. Default effort is sufficient; higher
#    effort levels mainly trade runtime for skew, which is already <50 ps.
# -----------------------------------------------------------------------------
if { $RESUME_FROM eq "none" || $RESUME_FROM eq "pdn"
                            || $RESUME_FROM eq "place" } {
    # Tell CTS which cells in the SAED32 RVT library are usable as clock
    # buffers / inverters. Without this, Innovus fires IMPCCOPT-1135 and
    # friends ("CTS found neither inverters nor buffers") because the
    # Liberty file doesn't auto-flag them.
    #
    # SAED32 RVT naming: NBUFFXn_RVT for buffers, INVXn_RVT for inverters.
    # n = 1, 2, 4, 8, 16 covers the drive-strength range CTS needs.
    if { [catch {
        set_db cts_buffer_cells \
            "NBUFFX1_RVT NBUFFX2_RVT NBUFFX4_RVT NBUFFX8_RVT NBUFFX16_RVT"
        set_db cts_inverter_cells \
            "INVX1_RVT INVX2_RVT INVX4_RVT INVX8_RVT"
        # No clock gates synthesized in this design.
        set_db cts_clock_gating_cells ""
    } err] } {
        puts "WARNING: set_db cts_*_cells failed ($err); trying legacy syntax."
        # Fall back to older specifyClockTree-style globals if set_db is
        # unsupported in this Innovus version.
        catch {set_ccopt_property buffer_cells \
            {NBUFFX1_RVT NBUFFX2_RVT NBUFFX4_RVT NBUFFX8_RVT NBUFFX16_RVT}}
        catch {set_ccopt_property inverter_cells \
            {INVX1_RVT INVX2_RVT INVX4_RVT INVX8_RVT}}
        catch {set_ccopt_property clock_gating_cells {}}
    }
    puts ">>> CTS cell-lists: buffer=NBUFFXn_RVT inverter=INVXn_RVT"

    create_ccopt_clock_tree_spec
    ccopt_design

    optDesign -postCTS -drv -hold
    report_timing -max_paths 10        > "${RPT_DIR}/timing_post_cts.rpt"
    report_clock_tree                  > "${RPT_DIR}/clock_tree.rpt"
    saveDesign "${OUT_DIR}/cts.enc"
    puts ">>> CTS done"
}

# -----------------------------------------------------------------------------
# 8. Routing (skipped if resuming from route checkpoint)
#    Timing-driven + SI-driven match the per-leaf script.
# -----------------------------------------------------------------------------
if { $RESUME_FROM ne "route" } {
    setNanoRouteMode -drouteStartIteration default
    setNanoRouteMode -routeWithTimingDriven true
    setNanoRouteMode -routeWithSiDriven true
    routeDesign

    optDesign -postRoute -drv -hold -setup
    report_timing -max_paths 20         > "${RPT_DIR}/timing_post_route.rpt"
    report_power                        > "${RPT_DIR}/power_post_route.rpt"
    report_area                         > "${RPT_DIR}/area_post_route.rpt"
    saveDesign "${OUT_DIR}/route.enc"
    puts ">>> route done"
}

# -----------------------------------------------------------------------------
# 9. Verification (Innovus-internal)
# -----------------------------------------------------------------------------
verify_drc             -report "${RPT_DIR}/drc.rpt"
verify_connectivity    -report "${RPT_DIR}/connectivity.rpt"
verify_process_antenna -report "${RPT_DIR}/antenna.rpt"

# -----------------------------------------------------------------------------
# 10. Final reports and streamout
# -----------------------------------------------------------------------------
extractRC -outfile "${OUT_DIR}/final.spef"
saveNetlist "${OUT_DIR}/final.v"
defOut -netlist -placement -routing "${OUT_DIR}/final.def"

streamOut "${OUT_DIR}/final.gds.gz" \
    -mapFile  "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/tech/stream_out/saed32nm.map" \
    -merge    [list "${LEF_DIR}/../gds/saed32nm_rvt_oa.gds"] \
    -stripes 1 -units 1000 -mode ALL

# One-page human summary
set summary_fh [open "${RPT_DIR}/summary.rpt" w]
puts $summary_fh "Innovus hierarchical P&R summary: $TARGET"
puts $summary_fh "  Top              : $TOP"
puts $summary_fh "  ARRAY_DIM        : $ARRAY_N"
puts $summary_fh "  Clock period     : $CLK_PER ns"
puts $summary_fh "  Die utilization  : $DIE_UTIL"
puts $summary_fh "  Cell area        : [dbGet [dbGet top.fplan.coreBox] -e]"
puts $summary_fh "  Reports          : $RPT_DIR/"
puts $summary_fh "  Final netlist    : $OUT_DIR/final.v"
puts $summary_fh "  Final DEF        : $OUT_DIR/final.def"
puts $summary_fh "  Final GDS        : $OUT_DIR/final.gds.gz"
puts $summary_fh "  Parasitics       : $OUT_DIR/final.spef"
puts $summary_fh "  Route snapshot   : $OUT_DIR/route.enc.dat (read by run_sta_mc.do)"
close $summary_fh

puts ""
puts "=========================================="
puts " Innovus hierarchical P&R complete: $TARGET"
puts " Next: genus -files run_sta_mc.do  -- multi-corner STA + power"
puts "=========================================="

exit
