# =============================================================================
# wave.do -- Configure the QuestaSim wave window for the M2 waveform image.
#
# Usage:
#   1) Run the simulation in interactive (GUI) mode WITHOUT quitting at the
#      end. Easiest is to comment out the `quit -f` line at the end of
#      run_compute_core.do, OR launch with:
#          vsim -gui -do "do run_compute_core.do"
#      and add this file's commands manually.
#   2) From the QuestaSim console:
#          do wave.do
#   3) When the wave window populates, do:
#          File menu -> Export -> Image...
#      and save as project/m2/sim/waveform.png.
#
# What it shows:
#   - Top-level handshake (clk, rst_n, macro_cmd_valid/ready, done, busy)
#   - DMA write/read traffic (addr, data, valid)
#   - Lane 0 pipeline internals (pipeline_start/done/running_o, feed/out
#     active flags, out_wr_en/data)
#   - Aggregate perf counters
#   Then zooms to the window where Test 1 (FFN forward) is in progress
#   so the image captures: input load -> compute fusion -> output capture.
# =============================================================================

if {![info exists ::wave_setup_loaded]} {
    set ::wave_setup_loaded 1
}

# Open / focus the wave window
view wave

# Clear any existing waveforms
catch {delete wave -all}

# Detect whether we're in tb_compute_core or tb_interface and set $tb
set tb ""
if {[catch {examine /tb_compute_core/clk} _]} {
    if {![catch {examine /tb_interface/clk} _]} {
        set tb "/tb_interface"
    }
} else {
    set tb "/tb_compute_core"
}
if {$tb eq ""} {
    puts "ERROR: Neither tb_compute_core nor tb_interface is currently loaded."
    puts "       Run 'vsim -gui -do run_compute_core.do' first (and remove the"
    puts "       trailing 'quit -f' so the GUI stays open)."
    return
}
puts "wave.do: detected testbench = $tb"

# ---- Common: top-level handshake ----
add wave -group "Top-level"   $tb/clk
add wave -group "Top-level"   $tb/rst_n

if {$tb eq "/tb_compute_core"} {
    add wave -group "Top-level"   $tb/macro_cmd_valid
    add wave -group "Top-level"   $tb/macro_cmd_ready
    add wave -group "Top-level" -radix hex $tb/macro_cmd_in
    add wave -group "Top-level"   $tb/done
    add wave -group "Top-level"   $tb/busy
    add wave -group "Top-level"   $tb/irq

    # ---- DMA traffic ----
    add wave -group "DMA"        $tb/dma_wr_valid
    add wave -group "DMA" -radix hex $tb/dma_wr_addr
    add wave -group "DMA" -radix hex $tb/dma_wr_data
    add wave -group "DMA"        $tb/dma_rd_req
    add wave -group "DMA" -radix hex $tb/dma_rd_addr
    add wave -group "DMA" -radix hex $tb/dma_rd_data
    add wave -group "DMA"        $tb/dma_rd_valid

    # ---- Lane 0 streaming pipeline ----
    set pipe $tb/dut/u_accel_top/gen_lane\[0\]/u_engine/u_pipe
    add wave -group "Lane0 pipeline" $pipe/start
    add wave -group "Lane0 pipeline" $pipe/done
    add wave -group "Lane0 pipeline" $pipe/running_o
    add wave -group "Lane0 pipeline" $pipe/feed_active
    add wave -group "Lane0 pipeline" $pipe/out_active
    add wave -group "Lane0 pipeline" -radix unsigned $pipe/cycle_cnt
    add wave -group "Lane0 pipeline" $pipe/out_wr_en
    add wave -group "Lane0 pipeline" -radix hex $pipe/out_wr_idx
    add wave -group "Lane0 pipeline" -radix hex $pipe/out_wr_data

    # ---- Lane 0 controller FSM ----
    set ctrl $tb/dut/u_accel_top/gen_lane\[0\]/u_engine/u_ctrl
    add wave -group "Lane0 FSM" $ctrl/state
    add wave -group "Lane0 FSM" $ctrl/cmd_valid
    add wave -group "Lane0 FSM" $ctrl/cmd_ready
    add wave -group "Lane0 FSM" $ctrl/pipeline_start
    add wave -group "Lane0 FSM" $ctrl/pipeline_done

    # ---- Perf counters ----
    add wave -group "Perf" -radix unsigned $tb/perf_active
    add wave -group "Perf" -radix unsigned $tb/perf_stall
    add wave -group "Perf" -radix unsigned $tb/perf_tiles

    # Zoom to first test (Test 1: FFN Forward) - macro issued ~30 ns,
    # done around 70-90 ns. Show 0-150 ns to capture the full first run.
    wave zoom range 0 ns 150 ns

} else {
    # tb_interface
    add wave -group "UCIe cmd" $tb/ucie_cmd_valid
    add wave -group "UCIe cmd" $tb/ucie_cmd_ready
    add wave -group "UCIe cmd" -radix hex $tb/ucie_cmd_data
    add wave -group "UCIe cmd" -radix hex $tb/core_macro_cmd

    add wave -group "UCIe wr"  $tb/ucie_wr_valid
    add wave -group "UCIe wr"  $tb/ucie_wr_ready
    add wave -group "UCIe wr"  -radix hex $tb/ucie_wr_data
    add wave -group "UCIe wr"  -radix hex $tb/core_dma_wr_addr
    add wave -group "UCIe wr"  -radix hex $tb/core_dma_wr_data
    add wave -group "UCIe wr"  $tb/core_dma_wr_valid

    add wave -group "UCIe rd"  $tb/ucie_rd_req
    add wave -group "UCIe rd"  -radix hex $tb/ucie_rd_addr
    add wave -group "UCIe rd"  -radix hex $tb/ucie_rd_data
    add wave -group "UCIe rd"  $tb/ucie_rd_valid
    add wave -group "UCIe rd"  -radix hex $tb/core_dma_rd_data

    add wave -group "Status"   $tb/ucie_busy
    add wave -group "Status"   $tb/ucie_irq
    add wave -group "Status"   $tb/core_busy
    add wave -group "Status"   $tb/core_irq

    wave zoom full
}

# Cosmetic
configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -signalnamewidth 1 -snapdistance 10

puts ""
puts "================================================================"
puts " Wave window configured for $tb."
puts " Time range zoomed to the most informative slice."
puts ""
puts " To save the image:"
puts "   File menu -> Export -> Image -> save as waveform.png"
puts " or via TCL (writes PostScript -- convert externally to PNG):"
puts "   write postscript -portrait -windows {Wave} waveform.ps"
puts "================================================================"
