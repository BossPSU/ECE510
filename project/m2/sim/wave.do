# =============================================================================
# wave.do -- Add the M2 waveform's signals to the QuestaSim wave window.
#
# This script must run AFTER `vsim` (so the design hierarchy is loaded)
# but BEFORE `run -all` (so signal traces record during the run).
# Calling it after $finish does NOT work because QuestaSim unloads the
# design objects when the testbench finishes; you'd see
# "No objects found matching '/.../...'" errors.
#
# Auto-detects which testbench is loaded:
#   * /tb_compute_core -> populates Top / DMA / Lane0 pipe / Lane0 FSM / Perf
#   * /tb_interface    -> populates UCIe cmd / wr / rd / Status
# Override by setting $::wave_tb before sourcing if you ever need to.
#
# run_compute_core.do and run_interface.do both invoke this at the right
# moment. To re-source manually, restart the simulation and call this
# BEFORE run -all.
# =============================================================================

view wave

# Idempotent: nuke any existing waves so re-sourcing this is clean
catch {delete wave *}

# ---- Detect which testbench is loaded -----------------------------------
# Caller can override by setting ::wave_tb beforehand.
if {[info exists ::wave_tb]} {
    set tb $::wave_tb
} else {
    set tb ""
    foreach inst [find instances /*] {
        set name [string trimleft $inst /]
        if {$name eq "tb_compute_core" || $name eq "tb_interface"} {
            set tb /$name
            break
        }
    }
    if {$tb eq ""} {
        puts "wave.do: ERROR -- no tb_compute_core or tb_interface loaded."
        return
    }
}

puts "wave.do: populating signals for $tb"

# =========================================================================
# tb_compute_core: full chiplet top
# =========================================================================
if {$tb eq "/tb_compute_core"} {

    # === Top-level handshake (host-facing) ===
    add wave -group "Top"  $tb/clk
    add wave -group "Top"  $tb/rst_n
    add wave -group "Top"  $tb/macro_cmd_valid
    add wave -group "Top"  $tb/macro_cmd_ready
    add wave -group "Top"  -radix hex $tb/macro_cmd_in
    add wave -group "Top"  $tb/busy
    add wave -group "Top"  $tb/done
    add wave -group "Top"  $tb/irq

    # === DMA traffic ===
    add wave -group "DMA"  $tb/dma_wr_valid
    add wave -group "DMA"  -radix hex $tb/dma_wr_addr
    add wave -group "DMA"  -radix hex $tb/dma_wr_data
    add wave -group "DMA"  $tb/dma_rd_req
    add wave -group "DMA"  -radix hex $tb/dma_rd_addr
    add wave -group "DMA"  -radix hex $tb/dma_rd_data
    add wave -group "DMA"  $tb/dma_rd_valid

    # === Lane-0 streaming pipeline internals ===
    # Square brackets must be escaped so Tcl doesn't try command-substitution.
    set pipe "$tb/dut/u_accel_top/gen_lane\[0\]/u_engine/u_pipe"
    add wave -group "Lane0 pipe"  $pipe/start
    add wave -group "Lane0 pipe"  $pipe/done
    add wave -group "Lane0 pipe"  $pipe/running_o
    add wave -group "Lane0 pipe"  $pipe/feed_active
    add wave -group "Lane0 pipe"  $pipe/out_active
    add wave -group "Lane0 pipe"  -radix unsigned $pipe/cycle_cnt
    add wave -group "Lane0 pipe"  $pipe/out_wr_en
    add wave -group "Lane0 pipe"  -radix hex $pipe/out_wr_idx
    add wave -group "Lane0 pipe"  -radix hex $pipe/out_wr_data

    # === Lane-0 controller FSM (LOAD -> STREAM -> WRITE phases) ===
    set ctrl "$tb/dut/u_accel_top/gen_lane\[0\]/u_engine/u_ctrl"
    add wave -group "Lane0 FSM"   $ctrl/state
    add wave -group "Lane0 FSM"   $ctrl/cmd_valid
    add wave -group "Lane0 FSM"   $ctrl/cmd_ready
    add wave -group "Lane0 FSM"   $ctrl/pipeline_start
    add wave -group "Lane0 FSM"   $ctrl/pipeline_done

    # === Aggregate performance counters ===
    add wave -group "Perf"  -radix unsigned $tb/perf_active
    add wave -group "Perf"  -radix unsigned $tb/perf_stall
    add wave -group "Perf"  -radix unsigned $tb/perf_tiles

# =========================================================================
# tb_interface: pure UCIe protocol-layer DUT
# =========================================================================
} elseif {$tb eq "/tb_interface"} {

    # === UCIe command channel: host-side and unpacked core-side ===
    add wave -group "UCIe cmd"   $tb/clk
    add wave -group "UCIe cmd"   $tb/rst_n
    add wave -group "UCIe cmd"   $tb/ucie_cmd_valid
    add wave -group "UCIe cmd"   $tb/ucie_cmd_ready
    add wave -group "UCIe cmd"   -radix hex $tb/ucie_cmd_data
    add wave -group "UCIe cmd"   -radix hex $tb/core_macro_cmd
    add wave -group "UCIe cmd"   $tb/core_macro_cmd_valid
    add wave -group "UCIe cmd"   $tb/core_macro_cmd_ready

    # === UCIe write channel ===
    add wave -group "UCIe wr"    $tb/ucie_wr_valid
    add wave -group "UCIe wr"    $tb/ucie_wr_ready
    add wave -group "UCIe wr"    -radix hex $tb/ucie_wr_data
    add wave -group "UCIe wr"    $tb/core_dma_wr_valid
    add wave -group "UCIe wr"    -radix hex $tb/core_dma_wr_addr
    add wave -group "UCIe wr"    -radix hex $tb/core_dma_wr_data
    add wave -group "UCIe wr"    $tb/core_dma_wr_ready

    # === UCIe read channel ===
    add wave -group "UCIe rd"    $tb/ucie_rd_req
    add wave -group "UCIe rd"    -radix hex $tb/ucie_rd_addr
    add wave -group "UCIe rd"    -radix hex $tb/ucie_rd_data
    add wave -group "UCIe rd"    $tb/ucie_rd_valid
    add wave -group "UCIe rd"    $tb/core_dma_rd_req
    add wave -group "UCIe rd"    -radix hex $tb/core_dma_rd_data
    add wave -group "UCIe rd"    $tb/core_dma_rd_valid

    # === Status pass-through ===
    add wave -group "Status"     $tb/ucie_busy
    add wave -group "Status"     $tb/ucie_irq
    add wave -group "Status"     $tb/core_busy
    add wave -group "Status"     $tb/core_irq

}

# Cosmetic: column widths, time units. Zoom is done from the run_*.do
# script AFTER run -all (when traces actually exist).
configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -snapdistance 10

puts "wave.do: done."
