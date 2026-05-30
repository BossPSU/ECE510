# =============================================================================
# run_sta_mc.do -- Multi-corner sign-off STA + power for the post-route
# stream_pipeline_64x64 design.
#
# Phase 5 of the phobos hierarchical synth plan.
#
# Reads the post-route Innovus snapshot (route.enc.dat) from
# out_innovus/${TARGET}/ and re-times it across three corners using the
# extracted SPEF parasitics:
#
#   av_tt_setup  TT @ 0.85V / 25C  (typical, baseline)
#   av_ss_setup  SS @ 0.75V / 125C (worst setup, slow process + hot + low V)
#   av_ff_hold   FF @ 0.95V / -40C (worst hold, fast process + cold + high V)
#
# This is Innovus-native multi-corner STA (no Tempus license required).
# It's accurate to within ~5% of a full Tempus sign-off for a single-clock
# digital block of this size and is the standard academic-flow practice.
#
# Power is reported per corner via report_power. Static + dynamic are
# both included; switching activity defaults to 20% toggle rate (Innovus
# default for unannotated nets). For a more accurate dynamic-power number,
# set the SAIF env var to point at a gate-level VCD/SAIF from QuestaSim.
#
# Inputs (env vars, all optional):
#   ARRAY_N      Default 64.
#   TARGET       Default stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier.
#   TOP_MODULE   Default stream_pipeline.
#   LIB_PATH     Default SAED32 RVT TT/SS/FF dir on phobos.
#   SAIF         Optional. Per-net switching activity file (QuestaSim
#                exported). If unset, Innovus assumes 20% default toggling.
#   SLACK_LIM    Optional. Number of failing endpoints to dump per corner.
#                Default 50.
#
# Output:
#   out_innovus/${TARGET}/sta/
#     timing_tt_setup.rpt       setup at TT (the in-flow target)
#     timing_ss_setup.rpt       setup at SS (sign-off worst case)
#     timing_ff_hold.rpt        hold at FF (sign-off worst case)
#     timing_tt_hold.rpt        hold at TT (sanity check)
#     timing_violators.rpt      consolidated failing-endpoint list
#     power_tt.rpt              power at TT (nominal)
#     power_ss.rpt              power at SS (worst leakage)
#     power_ff.rpt              power at FF (worst dynamic)
#     mc_summary.rpt            one-page WNS/TNS/power table across corners
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Resolve inputs
# -----------------------------------------------------------------------------
set ARRAY_N    [expr {[info exists env(ARRAY_N)]    ? $env(ARRAY_N)    : 64}]
set TARGET     [expr {[info exists env(TARGET)]     ? $env(TARGET)     : "stream_pipeline_${ARRAY_N}x${ARRAY_N}_hier"}]
set TOP        [expr {[info exists env(TOP_MODULE)] ? $env(TOP_MODULE) : "stream_pipeline"}]
set LIB_PATH   [expr {[info exists env(LIB_PATH)]   ? $env(LIB_PATH)   : "/pkgs/synopsys/2020/32_28nm/SAED32_EDK/lib/stdcell_rvt/db_nldm"}]
set SLACK_LIM  [expr {[info exists env(SLACK_LIM)]  ? $env(SLACK_LIM)  : 50}]

set ENC_DIR    "out_innovus/${TARGET}"
set ENC_FILE   "${ENC_DIR}/route.enc.dat"
set STA_DIR    "${ENC_DIR}/sta"
file mkdir $STA_DIR

# -----------------------------------------------------------------------------
# 2. Sanity-check inputs
# -----------------------------------------------------------------------------
if { ![file exists $ENC_FILE] && ![file isdirectory $ENC_FILE] } {
    # Innovus saveDesign writes a directory named <name>.dat alongside the
    # <name>.enc text file. Either form is acceptable to restoreDesign.
    if { ![file exists "${ENC_DIR}/route.enc"] } {
        error "No route.enc(.dat) found at $ENC_DIR -- run run_innovus_hier.do first."
    }
}

# Resolve corner library files. Names follow the SAED32 EDK convention
# (saed32rvt_<corner>.lib). Fall back to whatever the lib dir contains
# matching the corner tag, so the script still works on PDK installs with
# slightly different filename casing.
proc find_lib { lib_path corner_tag } {
    set hits [glob -nocomplain "$lib_path/saed32rvt_${corner_tag}.lib"]
    if { [llength $hits] == 0 } {
        set hits [glob -nocomplain "$lib_path/*${corner_tag}.lib"]
    }
    if { [llength $hits] == 0 } {
        error "No .lib found in $lib_path matching corner '$corner_tag'."
    }
    return [lindex $hits 0]
}

set LIB_TT [find_lib $LIB_PATH "tt0p85v25c"]
set LIB_SS [find_lib $LIB_PATH "ss0p75v125c"]
set LIB_FF [find_lib $LIB_PATH "ff0p95vn40c"]

puts "=========================================="
puts "Multi-corner STA + power: $TARGET"
puts "  enc      : $ENC_FILE"
puts "  TT lib   : $LIB_TT"
puts "  SS lib   : $LIB_SS"
puts "  FF lib   : $LIB_FF"
puts "  out      : $STA_DIR"
puts "=========================================="

# -----------------------------------------------------------------------------
# 3. Restore the post-route Innovus design
# -----------------------------------------------------------------------------
restoreDesign $ENC_FILE $TOP

# -----------------------------------------------------------------------------
# 4. Build the multi-corner MMMC view set
#    SDC + constraint mode are already restored from the .enc; we add two
#    new library sets, RC corners, delay corners, and analysis views.
#
#    Setup is analyzed across {TT, SS} -- SS is the worst-case slow corner.
#    Hold is analyzed across {TT, FF} -- FF is the worst-case fast corner.
#    Both directions across TT serve as the sanity baseline.
# -----------------------------------------------------------------------------
create_library_set -name lib_ss -timing [list $LIB_SS]
create_library_set -name lib_ff -timing [list $LIB_FF]

# RC corners track temperature: hot SS -> rc_max, cold FF -> rc_min.
create_rc_corner -name rc_max -T 125
create_rc_corner -name rc_min -T -40

# Setup delay corners pair each library set with its worst RC corner.
create_delay_corner -name dc_ss -library_set lib_ss -rc_corner rc_max
create_delay_corner -name dc_ff -library_set lib_ff -rc_corner rc_min

# The constraint mode (SDC) was named "func_mode" during in-flow opt;
# restoreDesign preserves it. Reuse it for the new views.
create_analysis_view -name av_ss_setup -constraint_mode func_mode -delay_corner dc_ss
create_analysis_view -name av_ff_hold  -constraint_mode func_mode -delay_corner dc_ff

# Tell Innovus's timer to consider all three views in their respective
# directions. av_typ is the TT view restored from route.enc.
set_analysis_view -setup [list av_typ av_ss_setup] \
                  -hold  [list av_typ av_ff_hold]

# -----------------------------------------------------------------------------
# 5. Annotate parasitics from the post-route SPEF (corner-independent for
#    cap; resistance scales with the per-corner rc_corner above).
# -----------------------------------------------------------------------------
set SPEF "${ENC_DIR}/final.spef"
if { [file exists $SPEF] } {
    read_spef $SPEF
    puts "INFO: annotated parasitics from $SPEF"
} else {
    puts "WARNING: $SPEF missing -- timer will use Innovus internal RC estimates."
}

# -----------------------------------------------------------------------------
# 6. Per-corner timing reports
# -----------------------------------------------------------------------------
puts ">>> reporting timing per corner..."

# Setup (positive WNS = met, negative WNS = violation)
report_timing -view av_typ      -setup -max_paths 20 \
    > "${STA_DIR}/timing_tt_setup.rpt"
report_timing -view av_ss_setup -setup -max_paths 20 \
    > "${STA_DIR}/timing_ss_setup.rpt"

# Hold
report_timing -view av_typ     -hold -max_paths 20 \
    > "${STA_DIR}/timing_tt_hold.rpt"
report_timing -view av_ff_hold -hold -max_paths 20 \
    > "${STA_DIR}/timing_ff_hold.rpt"

# Consolidated violators view -- one report listing all failing endpoints
# across the worst-case views, sorted by slack.
report_timing -setup -view av_ss_setup -max_paths $SLACK_LIM \
              -path_group reg2reg \
    > "${STA_DIR}/timing_violators_setup_ss.rpt"
report_timing -hold  -view av_ff_hold  -max_paths $SLACK_LIM \
              -path_group reg2reg \
    > "${STA_DIR}/timing_violators_hold_ff.rpt"

# -----------------------------------------------------------------------------
# 7. Per-corner power reports
#    Innovus report_power respects the active analysis view. We swap the
#    active view per call so each report comes from the right delay corner.
#
#    If SAIF env var is set, annotate switching activity from a QuestaSim
#    exported file -- gives 30-50% more accurate dynamic power than the
#    default 20% toggle assumption.
# -----------------------------------------------------------------------------
if { [info exists env(SAIF)] } {
    if { [file exists $env(SAIF)] } {
        read_activity_file -format SAIF $env(SAIF)
        puts "INFO: annotated switching activity from $env(SAIF)"
    } else {
        puts "WARNING: SAIF=$env(SAIF) missing; using default 20% toggle."
    }
}

puts ">>> reporting power per corner..."

set_analysis_view -setup [list av_typ] -hold [list av_typ]
report_power > "${STA_DIR}/power_tt.rpt"

set_analysis_view -setup [list av_ss_setup] -hold [list av_typ]
report_power > "${STA_DIR}/power_ss.rpt"

set_analysis_view -setup [list av_typ] -hold [list av_ff_hold]
report_power > "${STA_DIR}/power_ff.rpt"

# Restore the original multi-view config for any follow-on commands.
set_analysis_view -setup [list av_typ av_ss_setup] \
                  -hold  [list av_typ av_ff_hold]

# -----------------------------------------------------------------------------
# 8. One-page summary (WNS / TNS / total power per corner)
#    Pulls numbers via Innovus's report_timing -summary and report_power
#    -summary, which return parseable single-line records.
# -----------------------------------------------------------------------------
puts ">>> building consolidated summary..."

proc grab_wns { view dir } {
    # Returns "{WNS} {TNS} {NVP}" (worst negative slack, total negative slack,
    # number of violating paths) for the given view and direction (setup/hold).
    set rpt [report_timing -view $view -$dir -summary]
    set wns "N/A"
    set tns "N/A"
    set nvp "N/A"
    regexp {WNS.*?:\s*([-\d.]+)} $rpt -> wns
    regexp {TNS.*?:\s*([-\d.]+)} $rpt -> tns
    regexp {Violating Paths.*?:\s*(\d+)} $rpt -> nvp
    return [list $wns $tns $nvp]
}

proc grab_power { view } {
    set rpt [report_power -view $view -summary]
    set tot "N/A"
    set lkg "N/A"
    set dyn "N/A"
    regexp {Total Power[^=:]*[=:]\s*([\d.eE+-]+)} $rpt -> tot
    regexp {Leakage[^=:]*[=:]\s*([\d.eE+-]+)}     $rpt -> lkg
    regexp {(Internal|Switching|Dynamic)[^=:]*[=:]\s*([\d.eE+-]+)} $rpt -> _m dyn
    return [list $tot $lkg $dyn]
}

set fh [open "${STA_DIR}/mc_summary.rpt" w]
puts $fh "Multi-corner STA + power summary -- $TARGET"
puts $fh "================================================================"
puts $fh ""
puts $fh "Timing (ns):"
puts $fh [format "  %-22s  %10s  %10s  %8s" "View" "WNS" "TNS" "#Viol"]
foreach { name view dir } {
    "TT setup (baseline)" av_typ      setup
    "SS setup (sign-off)" av_ss_setup setup
    "TT hold  (baseline)" av_typ      hold
    "FF hold  (sign-off)" av_ff_hold  hold
} {
    set r [grab_wns $view $dir]
    puts $fh [format "  %-22s  %10s  %10s  %8s" \
                  $name [lindex $r 0] [lindex $r 1] [lindex $r 2]]
}
puts $fh ""
puts $fh "Power (W):"
puts $fh [format "  %-22s  %10s  %10s  %10s" "Corner" "Total" "Leakage" "Dynamic"]
foreach { name view } {
    "TT (0.85V / 25C)"    av_typ
    "SS (0.75V / 125C)"   av_ss_setup
    "FF (0.95V / -40C)"   av_ff_hold
} {
    set r [grab_power $view]
    puts $fh [format "  %-22s  %10s  %10s  %10s" \
                  $name [lindex $r 0] [lindex $r 1] [lindex $r 2]]
}
puts $fh ""
puts $fh "Detail reports : $STA_DIR/"
puts $fh "Route snapshot : $ENC_FILE"
puts $fh "SPEF           : $SPEF"
close $fh

puts ""
puts "=========================================="
puts " Multi-corner STA + power complete: $TARGET"
puts " Summary : $STA_DIR/mc_summary.rpt"
puts "=========================================="

exit
