# =============================================================================
# wave.do -- Configure the QuestaSim wave window for the M2 waveform image.
#
# Usage (in QuestaSim console, AFTER the simulation has finished but BEFORE
# the simulator is unloaded):
#     do wave.do
#
# By default this targets tb_compute_core. To capture the interface TB
# instead, change the $tb assignment below to /tb_interface and rerun.
#
# IMPORTANT: run_compute_core.do ends with `quit -f`, which kills the
# simulation. To keep the GUI loaded for waveform capture either:
#   (a) comment out the trailing `quit -f` line in run_compute_core.do, OR
#   (b) launch with `vsim -gui` and source run_compute_core.do interactively
#       without the final quit.
# =============================================================================

view wave

# >>> Edit this line to switch testbenches <<<
set tb /tb_compute_core
# set tb /tb_interface

# Wipe any existing waves so re-running this script is idempotent
catch {delete wave -all}

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
# Square brackets must be escaped so Tcl doesn't try to command-substitute.
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

# Zoom to Test 1 (FFN forward) -- starts ~24 ns, finishes by ~120 ns
wave zoom range 0ns 150ns
configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -snapdistance 10

puts ""
puts "================================================================"
puts " Wave window configured for $tb"
puts ""
puts " To save the image:"
puts "   File menu -> Export -> Image -> waveform.png"
puts "   (save into project/m2/sim/waveform.png)"
puts "================================================================"
