# =============================================================================
# wave.do -- M3 cosim waveform setup. Targets /tb_top (the integrated
# UCIe -> compute_core path). Three annotated groups for the M3
# end-to-end waveform deliverable:
#   1. UCIe host link (external pins of top.sv)
#   2. Interface <-> core boundary inside top.sv
#   3. Lane-0 internals (streaming pipeline + controller FSM)
#
# Source AFTER `vsim` (so hierarchy exists) but BEFORE `run -all`.
# =============================================================================

view wave
catch {delete wave *}

set tb /tb_top
puts "wave.do: target testbench = $tb"

# === Group 1: UCIe host link (the chiplet's only external face) ===
add wave -group "UCIe link" $tb/clk
add wave -group "UCIe link" $tb/rst_n
add wave -group "UCIe link" $tb/ucie_cmd_valid
add wave -group "UCIe link" $tb/ucie_cmd_ready
add wave -group "UCIe link" -radix hex $tb/ucie_cmd_data
add wave -group "UCIe link" $tb/ucie_wr_valid
add wave -group "UCIe link" $tb/ucie_wr_ready
add wave -group "UCIe link" -radix hex $tb/ucie_wr_data
add wave -group "UCIe link" $tb/ucie_rd_req
add wave -group "UCIe link" -radix hex $tb/ucie_rd_addr
add wave -group "UCIe link" -radix hex $tb/ucie_rd_data
add wave -group "UCIe link" $tb/ucie_rd_valid
add wave -group "UCIe link" $tb/ucie_irq
add wave -group "UCIe link" $tb/ucie_busy

# === Group 2: interface <-> compute_core boundary inside top.sv ===
set iface $tb/dut/u_iface
add wave -group "Iface<->Core" $iface/core_macro_cmd_valid
add wave -group "Iface<->Core" $iface/core_macro_cmd_ready
add wave -group "Iface<->Core" -radix hex $iface/core_macro_cmd
add wave -group "Iface<->Core" $iface/core_dma_wr_valid
add wave -group "Iface<->Core" -radix hex $iface/core_dma_wr_addr
add wave -group "Iface<->Core" -radix hex $iface/core_dma_wr_data
add wave -group "Iface<->Core" $iface/core_dma_wr_ready
add wave -group "Iface<->Core" $iface/core_dma_rd_req
add wave -group "Iface<->Core" -radix hex $iface/core_dma_rd_addr
add wave -group "Iface<->Core" -radix hex $iface/core_dma_rd_data
add wave -group "Iface<->Core" $iface/core_dma_rd_valid
add wave -group "Iface<->Core" $iface/core_busy
add wave -group "Iface<->Core" $iface/core_irq

# === Group 3: Lane-0 internals (proof that compute happens) ===
set pipe "$tb/dut/u_core/u_accel_top/gen_lane\[0\]/u_engine/u_pipe"
add wave -group "Lane0 pipe" $pipe/start
add wave -group "Lane0 pipe" $pipe/done
add wave -group "Lane0 pipe" $pipe/running_o
add wave -group "Lane0 pipe" $pipe/feed_active
add wave -group "Lane0 pipe" $pipe/out_active
add wave -group "Lane0 pipe" -radix unsigned $pipe/cycle_cnt
add wave -group "Lane0 pipe" $pipe/out_wr_en
add wave -group "Lane0 pipe" -radix hex $pipe/out_wr_idx
add wave -group "Lane0 pipe" -radix hex $pipe/out_wr_data

set ctrl "$tb/dut/u_core/u_accel_top/gen_lane\[0\]/u_engine/u_ctrl"
add wave -group "Lane0 FSM" $ctrl/state
add wave -group "Lane0 FSM" $ctrl/cmd_valid
add wave -group "Lane0 FSM" $ctrl/cmd_ready
add wave -group "Lane0 FSM" $ctrl/pipeline_start
add wave -group "Lane0 FSM" $ctrl/pipeline_done

configure wave -timelineunits ns -namecolwidth 280 -valuecolwidth 110 \
               -justifyvalue left -snapdistance 10

puts "wave.do: done."
