# =============================================================================
# wave.do -- Add the M2 waveform's signals to the QuestaSim wave window.
#
# This script must run AFTER `vsim` (so the design hierarchy is loaded)
# but BEFORE `run -all` (so signal traces are recorded during the run).
# Calling it after $finish does NOT work because QuestaSim unloads the
# design objects when the testbench finishes; you'd see
# "No objects found matching '/tb_compute_core/...'" errors.
#
# run_compute_core.do already invokes this at the right moment. To
# re-source it manually, restart the simulation with vsim and call
# this BEFORE run -all.
#
# Default target is tb_compute_core. Edit the $tb line for tb_interface.
# =============================================================================

view wave

# >>> Edit this line to switch testbenches <<<
set tb /tb_compute_core
# set tb /tb_interface

# Idempotent: nuke any existing waves so re-sourcing this is clean
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

# Cosmetic: column widths, time units. Zoom is done from
# run_compute_core.do AFTER run -all (when traces actually exist).
configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -snapdistance 10

puts "wave.do: signals added for $tb"
