"""
Roofline model for Intel i5-10500H CPU.
Plots dominant kernel (ff_backward) and hypothetical accelerator.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# Platform specs: Intel Core i5-10500H
# ============================================================
# 6 cores, base 2.5 GHz, boost 4.5 GHz
# AVX2: 2 FMA units/core x 4 FP64 ops/FMA x 2 FLOP/FMA = 16 FP64 FLOPs/cycle/core
# (FMA = fused multiply-add = 2 FLOPs; AVX2 = 256-bit = 4 x FP64)
# Peak FP64: 6 cores x 16 FLOPs/cycle x 4.5 GHz = 432 GFLOP/s
#
# Memory: 1 channel DDR4-3200 (laptop, single SO-DIMM detected)
# Peak BW: 1 x 8 bytes x 3200 MHz = 25.6 GB/s
# ============================================================

peak_flops = 432e9          # 432 GFLOP/s (FP64, boost clocks, all cores)
peak_bw    = 25.6e9         # 25.6 GB/s (single-channel DDR4-3200)
ridge_point = peak_flops / peak_bw  # FLOPs/byte

# ============================================================
# Dominant kernel: ff_backward
# From ai_calculation.md:
#   FLOPs = 34,881,536
#   Bytes = 6,425,088
#   AI    = 5.43 FLOPs/byte
# ============================================================
kernel_ai    = 34_881_536 / 6_425_088  # 5.43 FLOPs/byte
kernel_flops = 34_881_536

# Attainable perf at this AI (memory-bound region)
kernel_attainable = min(kernel_ai * peak_bw, peak_flops)

# ============================================================
# Hypothetical accelerator
# Custom systolic-array accelerator for ff_backward:
#   - 64x64 systolic array @ 500 MHz → 2x64x64x500M = 4.096 TFLOP/s FP64
#   - On-chip SRAM BW: 256 GB/s (wide bus to local scratchpad)
# ============================================================
accel_peak_flops = 4.096e12    # 4.096 TFLOP/s
accel_peak_bw    = 256e9       # 256 GB/s on-chip
accel_ridge      = accel_peak_flops / accel_peak_bw  # 16 FLOPs/byte

# Same kernel AI, attainable on accelerator
accel_attainable = min(kernel_ai * accel_peak_bw, accel_peak_flops)

# ============================================================
# Plot
# ============================================================
fig, ax = plt.subplots(figsize=(10, 6))

ai_range = np.logspace(-1, 3, 500)

# CPU roofline
cpu_roof = np.minimum(ai_range * peak_bw, peak_flops)
ax.loglog(ai_range, cpu_roof, "b-", linewidth=2.5, label="i5-10500H Roofline (FP64)")

# Accelerator roofline
accel_roof = np.minimum(ai_range * accel_peak_bw, accel_peak_flops)
ax.loglog(ai_range, accel_roof, "r--", linewidth=2.5, label="Accelerator Roofline (FP64)")

# Ridge points
ax.axvline(ridge_point, color="b", linestyle=":", alpha=0.4)
ax.axvline(accel_ridge, color="r", linestyle=":", alpha=0.4)

# Kernel on CPU roofline
ax.plot(kernel_ai, kernel_attainable, "bo", markersize=12, zorder=5)
ax.annotate(
    f"ff_backward (CPU)\nAI = {kernel_ai:.2f} FLOP/B\n{kernel_attainable/1e9:.1f} GFLOP/s",
    xy=(kernel_ai, kernel_attainable),
    xytext=(kernel_ai * 3, kernel_attainable * 0.3),
    fontsize=9, fontweight="bold",
    arrowprops=dict(arrowstyle="->", color="blue"),
    color="blue",
)

# Kernel on accelerator roofline
ax.plot(kernel_ai, accel_attainable, "r^", markersize=12, zorder=5)
ax.annotate(
    f"ff_backward (Accel)\nAI = {kernel_ai:.2f} FLOP/B\n{accel_attainable/1e9:.1f} GFLOP/s",
    xy=(kernel_ai, accel_attainable),
    xytext=(kernel_ai * 3, accel_attainable * 2.5),
    fontsize=9, fontweight="bold",
    arrowprops=dict(arrowstyle="->", color="red"),
    color="red",
)

# Ridge point annotations
ax.annotate(
    f"CPU Ridge\n{ridge_point:.1f} FLOP/B",
    xy=(ridge_point, peak_flops),
    xytext=(ridge_point * 2.5, peak_flops * 0.35),
    fontsize=8, color="blue", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="blue", alpha=0.5),
)
ax.annotate(
    f"Accel Ridge\n{accel_ridge:.1f} FLOP/B",
    xy=(accel_ridge, accel_peak_flops),
    xytext=(accel_ridge * 2.5, accel_peak_flops * 0.35),
    fontsize=8, color="red", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="red", alpha=0.5),
)

# Labels
ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)", fontsize=12)
ax.set_ylabel("Attainable Performance (FLOP/s)", fontsize=12)
ax.set_title("Roofline Model: i5-10500H vs. Hypothetical Accelerator", fontsize=13)
ax.legend(loc="upper left", fontsize=10)
ax.grid(True, which="both", alpha=0.3)
ax.set_xlim(0.1, 1000)
ax.set_ylim(1e9, 1e13)

# Spec box
specs_text = (
    "CPU: i5-10500H (6C, 4.5 GHz boost)\n"
    f"  Peak FP64: {peak_flops/1e9:.0f} GFLOP/s\n"
    f"  Peak BW: {peak_bw/1e9:.1f} GB/s (1ch DDR4-3200)\n"
    f"  Ridge: {ridge_point:.1f} FLOP/B\n\n"
    "Accelerator: 64x64 systolic @ 500 MHz\n"
    f"  Peak FP64: {accel_peak_flops/1e12:.3f} TFLOP/s\n"
    f"  On-chip BW: {accel_peak_bw/1e9:.0f} GB/s\n"
    f"  Ridge: {accel_ridge:.1f} FLOP/B"
)
ax.text(
    0.98, 0.02, specs_text,
    transform=ax.transAxes, fontsize=7.5,
    verticalalignment="bottom", horizontalalignment="right",
    bbox=dict(boxstyle="round,pad=0.4", facecolor="wheat", alpha=0.8),
    family="monospace",
)

plt.tight_layout()
plt.savefig(
    r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf02\profiling\roofline_project.pdf",
    dpi=150, bbox_inches="tight",
)
print("Saved roofline_project.pdf")
