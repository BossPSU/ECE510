# =============================================================================
# wave.do -- Add the M2 waveform's signals to the QuestaSim wave window.
#
# Caller MUST set ::wave_tb to either /tb_compute_core or /tb_interface
# before sourcing this script. Both run_compute_core.do and run_interface.do
# do this for you. Default fallback is /tb_compute_core.
#
# Run AFTER `vsim` (so the design hierarchy is loaded) but BEFORE
# `run -all` (so signal traces record during the run). After $finish the
# design unloads and add wave reports "No objects found matching ...".
# =============================================================================

view wave
catch {delete wave *}

if {[info exists ::wave_tb]} {
    set tb $::wave_tb
} else {
    set tb /tb_compute_core
    puts "wave.do: ::wave_tb not set, defaulting to $tb"
}
puts "wave.do: target testbench = $tb"

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

    add wave -group "UCIe cmd"  $tb/clk
    add wave -group "UCIe cmd"  $tb/rst_n
    add wave -group "UCIe cmd"  $tb/ucie_cmd_valid
    add wave -group "UCIe cmd"  $tb/ucie_cmd_ready
    add wave -group "UCIe cmd"  -radix hex $tb/ucie_cmd_data
    add wave -group "UCIe cmd"  -radix hex $tb/core_macro_cmd
    add wave -group "UCIe cmd"  $tb/core_macro_cmd_valid
    add wave -group "UCIe cmd"  $tb/core_macro_cmd_ready

    add wave -group "UCIe wr"   $tb/ucie_wr_valid
    add wave -group "UCIe wr"   $tb/ucie_wr_ready
    add wave -group "UCIe wr"   -radix hex $tb/ucie_wr_data
    add wave -group "UCIe wr"   $tb/core_dma_wr_valid
    add wave -group "UCIe wr"   -radix hex $tb/core_dma_wr_addr
    add wave -group "UCIe wr"   -radix hex $tb/core_dma_wr_data
    add wave -group "UCIe wr"   $tb/core_dma_wr_ready

    add wave -group "UCIe rd"   $tb/ucie_rd_req
    add wave -group "UCIe rd"   -radix hex $tb/ucie_rd_addr
    add wave -group "UCIe rd"   -radix hex $tb/ucie_rd_data
    add wave -group "UCIe rd"   $tb/ucie_rd_valid
    add wave -group "UCIe rd"   $tb/core_dma_rd_req
    add wave -group "UCIe rd"   -radix hex $tb/core_dma_rd_data
    add wave -group "UCIe rd"   $tb/core_dma_rd_valid

    add wave -group "Status"    $tb/ucie_busy
    add wave -group "Status"    $tb/ucie_irq
    add wave -group "Status"    $tb/core_busy
    add wave -group "Status"    $tb/core_irq

} else {
    puts "wave.do: ERROR -- ::wave_tb is '$tb' (expected /tb_compute_core or /tb_interface)"
}

configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -snapdistance 10

puts "wave.do: done."
