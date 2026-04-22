"""
Roofline plot with all platforms at FP32.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# RTX 3050 Ti Laptop GPU (FP32)
# ============================================================
gpu_peak_flops = 5.3e12     # 5.3 TFLOP/s FP32
gpu_peak_bw    = 192e9       # 192 GB/s GDDR6
gpu_ridge      = gpu_peak_flops / gpu_peak_bw

# ============================================================
# i5-10500H CPU (FP32)
# 6 cores, 4.5 GHz boost, AVX2: 2 FMA x 8 FP32/FMA x 2 FLOP = 32 FP32 FLOPs/cycle/core
# Peak FP32: 6 * 32 * 4.5e9 = 864 GFLOP/s
# ============================================================
cpu_peak_flops = 864e9       # 864 GFLOP/s FP32
cpu_peak_bw    = 25.6e9      # 25.6 GB/s single-channel DDR4-3200
cpu_ridge      = cpu_peak_flops / cpu_peak_bw

# ============================================================
# Hypothetical accelerator (FP32)
# 64x64 systolic @ 500 MHz, FP32 doubles MACs vs FP64
# 2 * 64 * 64 * 500e6 * 2 = 8.192 TFLOP/s FP32
# (or simply 2x the FP64 rate)
# ============================================================
accel_peak_flops = 8.192e12  # 8.192 TFLOP/s FP32
accel_peak_bw    = 256e9     # 256 GB/s on-chip SRAM
accel_ridge      = accel_peak_flops / accel_peak_bw

# ============================================================
# Kernel: ff_backward at FP32
# Same FLOPs (34,881,536), but bytes halved (4 bytes/element instead of 8)
# AI = 34,881,536 / (803,136 * 4) = 34,881,536 / 3,212,544 = 10.86 FLOP/B
# ============================================================
kernel_flops = 34_881_536
kernel_bytes_fp32 = 803_136 * 4   # 3,212,544 bytes
kernel_ai = kernel_flops / kernel_bytes_fp32  # ~10.86 FLOP/B

cpu_attainable   = min(kernel_ai * cpu_peak_bw, cpu_peak_flops)
gpu_attainable   = min(kernel_ai * gpu_peak_bw, gpu_peak_flops)
accel_attainable = min(kernel_ai * accel_peak_bw, accel_peak_flops)

# ============================================================
# GEMM kernels (FP32, measured)
# ============================================================
N = 1024
gemm_flops = 2.0 * N * N * N

naive_time_ms = 4.050
naive_gflops  = gemm_flops / (naive_time_ms / 1000) / 1e9
naive_effective_ai = (naive_gflops * 1e9) / gpu_peak_bw

tiled_time_ms = 4.067
tiled_gflops  = gemm_flops / (tiled_time_ms / 1000) / 1e9
tiled_effective_ai = (tiled_gflops * 1e9) / gpu_peak_bw

# ============================================================
# Plot
# ============================================================
fig, ax = plt.subplots(figsize=(12, 7))
ai_range = np.logspace(-2, 3, 500)

# CPU roofline
cpu_roof = np.minimum(ai_range * cpu_peak_bw, cpu_peak_flops)
ax.loglog(ai_range, cpu_roof, "b-", linewidth=2, alpha=0.7, label=f"i5-10500H (FP32) — {cpu_peak_flops/1e9:.0f} GFLOP/s, {cpu_peak_bw/1e9:.1f} GB/s")

# GPU roofline
gpu_roof = np.minimum(ai_range * gpu_peak_bw, gpu_peak_flops)
ax.loglog(ai_range, gpu_roof, "g-", linewidth=2.5, label=f"RTX 3050 Ti (FP32) — {gpu_peak_flops/1e12:.1f} TFLOP/s, {gpu_peak_bw/1e9:.0f} GB/s")

# Accelerator roofline
accel_roof = np.minimum(ai_range * accel_peak_bw, accel_peak_flops)
ax.loglog(ai_range, accel_roof, "m--", linewidth=2, alpha=0.7, label=f"Accelerator (FP32) — {accel_peak_flops/1e12:.1f} TFLOP/s, {accel_peak_bw/1e9:.0f} GB/s")

# Ridge point lines
ax.axvline(cpu_ridge, color="b", linestyle=":", alpha=0.3)
ax.axvline(gpu_ridge, color="g", linestyle=":", alpha=0.3)
ax.axvline(accel_ridge, color="m", linestyle=":", alpha=0.3)

# ff_backward kernel points
ax.plot(kernel_ai, cpu_attainable, "bs", markersize=10, zorder=5)
ax.annotate(f"ff_backward (CPU)\nAI = {kernel_ai:.1f} FLOP/B\n{cpu_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, cpu_attainable),
    xytext=(kernel_ai * 0.1, cpu_attainable * 0.5),
    fontsize=8, fontweight="bold", color="blue",
    arrowprops=dict(arrowstyle="->", color="blue", alpha=0.7))

ax.plot(kernel_ai, gpu_attainable, "go", markersize=10, zorder=5)
ax.annotate(f"ff_backward (GPU)\nAI = {kernel_ai:.1f} FLOP/B\n{gpu_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, gpu_attainable),
    xytext=(kernel_ai * 3, gpu_attainable * 0.4),
    fontsize=8, fontweight="bold", color="green",
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.7))

ax.plot(kernel_ai, accel_attainable, "m^", markersize=10, zorder=5)
ax.annotate(f"ff_backward (Accel)\nAI = {kernel_ai:.1f} FLOP/B\n{accel_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, accel_attainable),
    xytext=(kernel_ai * 3, accel_attainable * 2),
    fontsize=8, fontweight="bold", color="purple",
    arrowprops=dict(arrowstyle="->", color="purple", alpha=0.7))

# GEMM kernel points (measured on GPU at FP32)
ax.plot(naive_effective_ai, naive_gflops * 1e9, "gd", markersize=8, zorder=5, alpha=0.6)
ax.annotate(f"Naive GEMM\n{naive_gflops:.0f} GFLOP/s",
    xy=(naive_effective_ai, naive_gflops * 1e9),
    xytext=(naive_effective_ai * 0.15, naive_gflops * 1e9 * 0.5),
    fontsize=7, color="green", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.5))

ax.plot(tiled_effective_ai, tiled_gflops * 1e9, "gv", markersize=8, zorder=5, alpha=0.6)
ax.annotate(f"Tiled GEMM\n{tiled_gflops:.0f} GFLOP/s",
    xy=(tiled_effective_ai, tiled_gflops * 1e9),
    xytext=(tiled_effective_ai * 2.5, tiled_gflops * 1e9 * 0.5),
    fontsize=7, color="green", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.5))

ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)", fontsize=12)
ax.set_ylabel("Performance (FLOP/s)", fontsize=12)
ax.set_title("Combined Roofline (FP32): CPU / GPU / Accelerator", fontsize=13)
ax.legend(loc="upper left", fontsize=9)
ax.grid(True, which="both", alpha=0.3)
ax.set_xlim(0.01, 1000)
ax.set_ylim(1e9, 1e13)

specs = (
    "All platforms at FP32\n"
    f"  ff_backward AI = {kernel_ai:.1f} FLOP/B\n\n"
    f"  CPU:   {cpu_attainable/1e9:.0f} GFLOP/s (ridge={cpu_ridge:.1f})\n"
    f"  GPU:   {gpu_attainable/1e9:.0f} GFLOP/s (ridge={gpu_ridge:.1f})\n"
    f"  Accel: {accel_attainable/1e9:.0f} GFLOP/s (ridge={accel_ridge:.1f})"
)
ax.text(0.98, 0.02, specs, transform=ax.transAxes, fontsize=7.5,
    verticalalignment="bottom", horizontalalignment="right",
    bbox=dict(boxstyle="round,pad=0.4", facecolor="wheat", alpha=0.8),
    family="monospace")

plt.tight_layout()
plt.savefig(
    r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf03\profiling\roofline32.png",
    dpi=150, bbox_inches="tight")
print("Saved roofline32.png")
print(f"\nff_backward FP32: AI={kernel_ai:.2f} FLOP/B")
print(f"  CPU:   {cpu_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < cpu_ridge else 'compute-bound'}")
print(f"  GPU:   {gpu_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < gpu_ridge else 'compute-bound'}")
print(f"  Accel: {accel_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < accel_ridge else 'compute-bound'}")
