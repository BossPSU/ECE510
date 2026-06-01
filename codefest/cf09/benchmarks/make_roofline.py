"""
CLLM Task 9 roofline plot.

Plots:
  - Sky130 accelerator chip roofline at the SS sign-off corner (45 MHz,
    full 64x64-spec scaling), with peak compute ceiling and a SRAM
    bandwidth ceiling derived from the M1 Heilmeier 256 GB/s on-chip
    target.
  - i5-10500H CPU baseline roofline (for comparison) using the M1
    datasheet figures (425 GFLOP/s peak fp64 from AVX2, 25.6 GB/s
    DRAM bandwidth).
  - The accelerator's attainable point at the M1 ff_backward kernel
    arithmetic intensity (5.43 FLOP/B), labeled PROJECTED.

Run from repo root:  python codefest/cf09/benchmarks/make_roofline.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = os.path.join(os.path.dirname(__file__), "roofline_plot.png")

# -----------------------------------------------------------------------------
# Platform numbers (all from project/m1/sw_baseline.md, the chip's M1 Heilmeier
# spec, and project/m3/synth/runs/M5_optD_attempt9/ post-PnR STA).
# -----------------------------------------------------------------------------

# M1 CPU baseline (i5-10500H, single-channel DDR4-3200, AVX2 fp64).
CPU_PEAK_GFLOPS = 432.0      # 6 cores * 4 elements/AVX * 2 ops * 4.5 GHz boost
CPU_DRAM_GBPS   = 25.6        # single-channel DDR4-3200

# Accelerator: HW chip at SAED32 SS, full 64x64 M1-spec configuration.
# Peak = freq * useful ops per cycle = 45e6 * 8192 = 369 GOPS at Sky130 SS.
# At SAED32 chip-target 500 MHz, peak = 500e6 * 8192 = 4096 GOPS.
# Use the more conservative Sky130 SS number as the accelerator point so
# the plot is grounded in *measured* (post-PnR) silicon timing.
ACC_PEAK_GOPS_SKY130_SS  = 369.0
ACC_PEAK_GOPS_SAED32_SPEC = 4096.0

# On-chip SRAM bandwidth budget from Heilmeier: 256 GB/s sustained out of
# the tile-buffer multi-port reads at ARRAY_DIM=64.
ACC_SRAM_GBPS    = 256.0
# UCIe chiplet-to-host interface BW from M1 interface_selection.md.
ACC_UCIE_GBPS    = 8.0

# Kernel arithmetic intensity from CMAN analysis (M1 ff_backward):
KERNEL_AI_NO_REUSE   = 0.5    # no-reuse lower bound (loads weights every iter)
KERNEL_AI_FULL_REUSE = 5.43    # full weight reuse (M1 baseline AI, the ridge of cf02)

# -----------------------------------------------------------------------------
# Plot
# -----------------------------------------------------------------------------
ai = np.logspace(-1.5, 3, 200)  # FLOPs/byte

fig, ax = plt.subplots(figsize=(8, 5.5), dpi=140)

# CPU roofline (gray)
cpu_mem  = CPU_DRAM_GBPS * ai
cpu_roof = np.minimum(cpu_mem, CPU_PEAK_GFLOPS)
ax.plot(ai, cpu_roof, color="0.55", lw=1.7, label=f"CPU (i5-10500H): peak {CPU_PEAK_GFLOPS:.0f} GFLOP/s, DRAM {CPU_DRAM_GBPS:.1f} GB/s")

# Accelerator roofline (Sky130 SS, 64x64-spec) -- the "currently buildable" curve
acc_sram = ACC_SRAM_GBPS * ai
acc_sky130 = np.minimum(acc_sram, ACC_PEAK_GOPS_SKY130_SS)
ax.plot(ai, acc_sky130, color="C0", lw=2.2, label=f"Chip @ Sky130 SS (45 MHz, 4096 PEs): peak {ACC_PEAK_GOPS_SKY130_SS:.0f} GOPS, SRAM {ACC_SRAM_GBPS:.0f} GB/s")

# Accelerator roofline (SAED32 M1-spec, projected) -- the "design target" curve
acc_saed32 = np.minimum(acc_sram, ACC_PEAK_GOPS_SAED32_SPEC)
ax.plot(ai, acc_saed32, color="C0", lw=2.2, ls=":",
        label=f"Chip @ SAED32 500 MHz (projected M1 spec): peak {ACC_PEAK_GOPS_SAED32_SPEC:.0f} GOPS")

# UCIe interface BW ceiling
ucie = ACC_UCIE_GBPS * ai
# Only show in the AI region where it actually matters (below the SRAM ceiling)
ax.plot(ai, np.minimum(ucie, ACC_PEAK_GOPS_SAED32_SPEC), color="C3", lw=1.2, ls="--",
        label=f"UCIe x16 host-interface BW: {ACC_UCIE_GBPS:.0f} GB/s")

# Kernel AI markers
def mark_kernel_point(x, roof_fn, label, color, marker="o"):
    y = roof_fn(x)
    ax.scatter([x], [y], s=80, marker=marker, color=color, zorder=5,
               edgecolor="black", lw=0.8)
    ax.annotate(label, (x, y), xytext=(10, -15), textcoords="offset points",
                fontsize=8.5)
    ax.axvline(x, ymin=0, ymax=1, color=color, lw=0.5, ls=":", alpha=0.35)

mark_kernel_point(KERNEL_AI_NO_REUSE, lambda a: min(ACC_SRAM_GBPS*a, ACC_PEAK_GOPS_SKY130_SS),
                  "AI no-reuse = 0.5 FLOP/B",  "C2")
mark_kernel_point(KERNEL_AI_FULL_REUSE, lambda a: min(ACC_SRAM_GBPS*a, ACC_PEAK_GOPS_SKY130_SS),
                  "AI full-reuse = 5.43 FLOP/B\n(PROJECTED accelerator point)",
                  "C1", marker="s")

# Ridge points
sky_ridge = ACC_PEAK_GOPS_SKY130_SS / ACC_SRAM_GBPS
ax.axvline(sky_ridge, color="C0", lw=0.5, ls=":", alpha=0.4)
ax.text(sky_ridge*1.05, ACC_PEAK_GOPS_SKY130_SS*0.45,
        f"Sky130 ridge\nAI = {sky_ridge:.2f} FLOP/B",
        color="C0", fontsize=7.5)

cpu_ridge = CPU_PEAK_GFLOPS / CPU_DRAM_GBPS
ax.axvline(cpu_ridge, color="0.55", lw=0.5, ls=":", alpha=0.4)
ax.text(cpu_ridge*1.05, CPU_PEAK_GFLOPS*0.35,
        f"CPU ridge\nAI = {cpu_ridge:.1f} FLOP/B",
        color="0.45", fontsize=7.5)

# Axes
ax.set_xscale("log")
ax.set_yscale("log")
ax.set_xlim(0.03, 1e3)
ax.set_ylim(0.5, 1e4)
ax.set_xlabel("Arithmetic intensity (FLOP / byte)")
ax.set_ylabel("Attainable performance (GFLOP/s or GOPS)")
ax.set_title("CLLM 9 roofline -- M5 chip (Sky130 SS, post-PnR Attempt 9) vs M1 CPU baseline",
             fontsize=11)
ax.grid(which="both", alpha=0.25, lw=0.5)
ax.legend(loc="lower right", fontsize=8, framealpha=0.95)

# Watermark the projection caveat
ax.text(0.04, 0.96, "All accelerator points: PROJECTED (post-PnR f_max x ops/cycle, no end-to-end cosim)",
        transform=ax.transAxes, fontsize=7.5, color="C3", va="top",
        bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="C3", lw=0.5))

plt.tight_layout()
plt.savefig(OUT, dpi=160)
print(f"wrote {OUT}")
