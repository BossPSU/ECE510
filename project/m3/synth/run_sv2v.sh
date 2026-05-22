#!/usr/bin/env bash
# Convert M3 integrated-build SV stack to Verilog 2005 for OpenLane.
# Run from project/m3/synth/. Output: v/top_small.v
set -e

# Strip Windows /mnt/ entries so we don't pick up Windows binaries.
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd:)"

SV2V=/nix/store/5z12s81fhh85rjq0d0wdkaz35l27r3hl-sv2v-0.0.13.1/bin/sv2v

mkdir -p v

"$SV2V" \
    accel_pkg.sv \
    ../../m2/rtl/stream_if.sv \
    ../../m2/rtl/sram_if.sv \
    ../../m2/rtl/cmd_if.sv \
    ../../m2/rtl/tile_if.sv \
    ../../m2/rtl/ctrl_if.sv \
    ../../m2/rtl/status_if.sv \
    ../../m2/rtl/mac_pe.sv \
    ../../m2/rtl/systolic_array_64x64.sv \
    ../../m2/rtl/gelu_lut.sv \
    ../../m2/rtl/exp_lut.sv \
    ../../m2/rtl/adder_tree.sv \
    ../../m2/rtl/gelu_unit.sv \
    ../../m2/rtl/gelu_grad_unit.sv \
    ../../m2/rtl/softmax_unit.sv \
    ../../m2/rtl/causal_mask_unit.sv \
    ../../m2/rtl/divider_or_reciprocal_unit.sv \
    ../../m2/rtl/fused_postproc_unit.sv \
    ../../m2/rtl/pipeline_stage.sv \
    ../../m2/rtl/skid_buffer.sv \
    ../../m2/rtl/stream_mux.sv \
    ../../m2/rtl/tile_loader.sv \
    ../../m2/rtl/tile_writer.sv \
    ../../m2/rtl/sram_bank.sv \
    ../../m2/rtl/scratchpad_ctrl.sv \
    ../../m2/rtl/address_gen.sv \
    ../../m2/rtl/dma_engine.sv \
    ../../m2/rtl/double_buffer_ctrl.sv \
    ../../m2/rtl/tile_buffer.sv \
    ../../m2/rtl/stream_pipeline.sv \
    ../../m2/rtl/mode_decoder.sv \
    ../../m2/rtl/tile_scheduler.sv \
    ../../m2/rtl/tile_dispatcher.sv \
    ../../m2/rtl/accel_controller.sv \
    ../../m2/rtl/perf_counter_block.sv \
    ../../m2/rtl/csr_block.sv \
    accel_engine.sv \
    accel_top.sv \
    ../../m2/rtl/compute_core.sv \
    ../../m2/rtl/interface.sv \
    top_small.sv \
    --top=top_small \
    --write=v/top_small.v

echo "sv2v: wrote $(wc -l < v/top_small.v) lines to v/top_small.v"
