"""
CLLM Task 9 roofline plot -- workload framing (M1's ff_backward).

Plots ff_backward as the kernel (consistent with M1's framing where
ff_backward, ff_forward, attention were the "kernels" of the
80%-accelerated workload story). Two AI markers:

  - CPU view of ff_backward AI: 5.43 FLOP/B (M1 measured, fp64).
  - Chip view of ff_backward AI: 0.25 -> 82 FLOP/B (Q16.16 no-reuse and
    full-reuse bounds across the chiplet interface boundary).

Three platform rooflines:

  - Sky130 SS post-PnR chip (45 MHz x 4096 PEs x 2 ops/MAC = 369 GOPS peak,
    256 GB/s on-chip SRAM per Heilmeier).
  - SAED32 SS projected M1 spec target (500 MHz x 8192 ops/cycle = 4,096 GOPS).
  - M1 CPU baseline (i5-10500H, 432 GFLOP/s peak fp64, 25.6 GB/s DRAM).

The accelerator point is the chip's measured sustained throughput
(221 GOPS) at the chip's full-reuse AI; that point sits on the chip's
compute-bound ceiling.

Run from repo root:  python codefest/cf09/benchmarks/make_roofline.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = os.path.join(os.path.dirname(__file__), "roofline_plot.png")

# -----------------------------------------------------------------------------
# Platform numbers (all from project/m1/sw_baseline.md, the M1 Heilmeier spec,
# and project/m3/synth/runs/M5_optD_attempt9/ post-PnR STA).
# -----------------------------------------------------------------------------

# M1 CPU baseline (i5-10500H, single-channel DDR4-3200, AVX2 fp64).
CPU_PEAK_GFLOPS = 432.0
CPU_DRAM_GBPS   = 25.6
CPU_FF_BACKWARD_AI = 5.43    # M1 measured, fp64 view of ff_backward
CPU_FF_BACKWARD_THROUGHPUT = 3.4  # sustained GFLOP/s on ff_backward portion

# Accelerator: Sky130 SS post-PnR-validated (Attempt 9).
ACC_PEAK_GOPS_SKY130_SS  = 369.0
ACC_PEAK_GOPS_SAED32_SPEC = 4096.0
ACC_SRAM_GBPS    = 256.0       # Heilmeier on-chip SRAM target
ACC_UCIE_GBPS    = 8.0         # M1 interface_selection.md

# ff_backward kernel AI on the chip (Q16.16, 4 B/element):
KERNEL_AI_CHIP_NO_REUSE   = 0.25    # lower bound: every operand re-fetched
KERNEL_AI_CHIP_FULL_REUSE = 82.0    # upper bound: tile_buffer holds intermediates

# Sustained accelerator throughput (post-PnR projection at 60% util):
ACC_SUSTAINED_GOPS_SKY130 = 221.0   # Sky130 SS, full 64x64 spec

# -----------------------------------------------------------------------------
# Plot
# -----------------------------------------------------------------------------
ai = np.logspace(-1.5, 3, 200)

fig, ax = plt.subplots(figsize=(9, 5.8), dpi=140)

# CPU roofline (gray)
cpu_roof = np.minimum(CPU_DRAM_GBPS * ai, CPU_PEAK_GFLOPS)
ax.plot(ai, cpu_roof, color="0.55", lw=1.8,
        label=f"CPU (i5-10500H, fp64): peak {CPU_PEAK_GFLOPS:.0f} GFLOP/s, DRAM {CPU_DRAM_GBPS:.1f} GB/s")

# Sky130 chip roofline (solid blue) -- post-PnR validated
acc_sky130 = np.minimum(ACC_SRAM_GBPS * ai, ACC_PEAK_GOPS_SKY130_SS)
ax.plot(ai, acc_sky130, color="C0", lw=2.4,
        label=f"Chip @ Sky130 SS (45 MHz, 4096 PEs, post-PnR validated): peak {ACC_PEAK_GOPS_SKY130_SS:.0f} GOPS, SRAM {ACC_SRAM_GBPS:.0f} GB/s")

# SAED32 chip roofline (dotted blue) -- M1 spec design target
acc_saed32 = np.minimum(ACC_SRAM_GBPS * ai, ACC_PEAK_GOPS_SAED32_SPEC)
ax.plot(ai, acc_saed32, color="C0", lw=1.6, ls=":",
        label=f"Chip @ SAED32 500 MHz (projected M1 spec): peak {ACC_PEAK_GOPS_SAED32_SPEC:.0f} GOPS")

# UCIe interface BW ceiling (red, dashed) -- shown only where relevant
ax.plot(ai, np.minimum(ACC_UCIE_GBPS * ai, ACC_PEAK_GOPS_SAED32_SPEC),
        color="C3", lw=1.0, ls="--",
        label=f"UCIe x16 host-interface BW: {ACC_UCIE_GBPS:.0f} GB/s")

# ============================================================================
# Workload-framing AI markers: ff_backward as the kernel
# ============================================================================

# 1) CPU's view of ff_backward (M1 measured, fp64): AI = 5.43 FLOP/B
cpu_at_ai = min(CPU_DRAM_GBPS * CPU_FF_BACKWARD_AI, CPU_PEAK_GFLOPS)
ax.scatter([CPU_FF_BACKWARD_AI], [cpu_at_ai], s=110, marker="^",
           color="0.35", zorder=6, edgecolor="black", lw=0.9)
ax.annotate("ff_backward AI on CPU\n(5.43 FLOP/B, fp64, M1 measured)\n-> 139 GFLOP/s peak attainable",
            (CPU_FF_BACKWARD_AI, cpu_at_ai), xytext=(15, -40),
            textcoords="offset points", fontsize=8.5, color="0.25")

# CPU measured sustained on ff_backward (3.4 GFLOP/s, well below peak)
ax.scatter([CPU_FF_BACKWARD_AI], [CPU_FF_BACKWARD_THROUGHPUT],
           s=90, marker="v", color="0.2", zorder=6, edgecolor="black", lw=0.9)
ax.annotate("CPU sustained: 3.4 GFLOP/s\n(M1 measured, ~25x below roofline)",
            (CPU_FF_BACKWARD_AI, CPU_FF_BACKWARD_THROUGHPUT),
            xytext=(15, 5), textcoords="offset points", fontsize=8, color="0.15")

# 2) Chip's view of ff_backward (Q16.16, two bounds)
# Lower bound (no-reuse, 0.25 FLOP/B): would put the chip in mem-bound region
chip_lower_y = min(ACC_SRAM_GBPS * KERNEL_AI_CHIP_NO_REUSE, ACC_PEAK_GOPS_SKY130_SS)
ax.scatter([KERNEL_AI_CHIP_NO_REUSE], [chip_lower_y], s=100, marker="s",
           color="C2", zorder=6, edgecolor="black", lw=0.8)
ax.annotate("ff_backward chip lower-bound\n(0.25 FLOP/B, no off-chip reuse)\n-> 64 GOPS (mem-bound)",
            (KERNEL_AI_CHIP_NO_REUSE, chip_lower_y),
            xytext=(-90, -55), textcoords="offset points", fontsize=8, color="C2")

# Upper bound (full reuse, 82 FLOP/B): where the chip's tile_buffer puts it
chip_upper_y = min(ACC_SRAM_GBPS * KERNEL_AI_CHIP_FULL_REUSE, ACC_PEAK_GOPS_SKY130_SS)
ax.scatter([KERNEL_AI_CHIP_FULL_REUSE], [chip_upper_y], s=130, marker="*",
           color="C1", zorder=7, edgecolor="black", lw=1.0)
ax.annotate("ff_backward chip upper-bound\n(82 FLOP/B, full tile_buffer reuse)\nPROJECTED accelerator point\n-> 369 GOPS peak / 221 GOPS sustained",
            (KERNEL_AI_CHIP_FULL_REUSE, chip_upper_y),
            xytext=(-220, -55), textcoords="offset points", fontsize=8.5, color="C1",
            arrowprops=dict(arrowstyle="->", color="C1", lw=0.8))

# Chip sustained throughput at the full-reuse AI
ax.scatter([KERNEL_AI_CHIP_FULL_REUSE], [ACC_SUSTAINED_GOPS_SKY130],
           s=110, marker="o", color="C1", zorder=6, edgecolor="black", lw=0.9,
           alpha=0.55)
ax.annotate("Chip sustained: 221 GOPS\n(60% util on ff_backward, PROJECTED)",
            (KERNEL_AI_CHIP_FULL_REUSE, ACC_SUSTAINED_GOPS_SKY130),
            xytext=(15, -5), textcoords="offset points", fontsize=8, color="C1")

# Ridge annotations
sky_ridge = ACC_PEAK_GOPS_SKY130_SS / ACC_SRAM_GBPS
ax.axvline(sky_ridge, color="C0", lw=0.5, ls=":", alpha=0.4)
ax.text(sky_ridge*1.08, ACC_PEAK_GOPS_SKY130_SS*0.50,
        f"Sky130 ridge\nAI = {sky_ridge:.2f} FLOP/B",
        color="C0", fontsize=7.5)

cpu_ridge = CPU_PEAK_GFLOPS / CPU_DRAM_GBPS
ax.axvline(cpu_ridge, color="0.55", lw=0.5, ls=":", alpha=0.4)
ax.text(cpu_ridge*1.08, CPU_PEAK_GFLOPS*0.35,
        f"CPU ridge\nAI = {cpu_ridge:.1f} FLOP/B",
        color="0.45", fontsize=7.5)

# Axes
ax.set_xscale("log")
ax.set_yscale("log")
ax.set_xlim(0.04, 1e3)
ax.set_ylim(0.7, 1e4)
ax.set_xlabel("Arithmetic intensity (FLOP / byte)")
ax.set_ylabel("Attainable performance (GFLOP/s or GOPS)")
ax.set_title("CLLM 9 roofline -- ff_backward kernel (workload framing)\n"
             "Chip @ Sky130 SS (post-PnR Attempt 9) vs M1 CPU baseline",
             fontsize=11)
ax.grid(which="both", alpha=0.25, lw=0.5)
ax.legend(loc="lower right", fontsize=8.2, framealpha=0.95)

# Projection caveat
ax.text(0.04, 0.97, "Chip throughput numbers: PROJECTED (post-PnR f_max x ops/cycle, no end-to-end cosim)",
        transform=ax.transAxes, fontsize=7.5, color="C3", va="top",
        bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="C3", lw=0.5))

plt.tight_layout()
plt.savefig(OUT, dpi=160)
print(f"wrote {OUT}")
