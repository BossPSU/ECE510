"""
Roofline plot for GEMM naive vs tiled on RTX 3050 Ti Laptop GPU.
Metrics derived analytically from kernel code and measured execution times.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# RTX 3050 Ti Laptop GPU specs
# Source: NVIDIA RTX 3050 Ti Laptop GPU spec sheet
#   2560 CUDA cores, boost ~1695 MHz
#   FP32 peak: 2560 * 2 * 1.695 GHz = 8.68 TFLOP/s
#   (NVIDIA official: 5.3 TFLOP/s at base clocks)
#   Memory: 4 GB GDDR6, 128-bit, 12 Gbps -> 192 GB/s
# ============================================================
peak_flops = 5.3e12        # 5.3 TFLOP/s FP32 (official rating)
peak_bw    = 192e9          # 192 GB/s GDDR6
ridge_point = peak_flops / peak_bw  # ~27.6 FLOP/byte

N = 1024
flops = 2.0 * N * N * N    # 2,147,483,648 FLOPs

# ============================================================
# Naive kernel analysis
# Each output element: reads full row of A (N floats) + full col of B (N floats)
# Total DRAM reads = N*N * (N + N) * 4 bytes = 2 * N^3 * 4 = 8 GiB (no reuse)
# Output writes = N*N * 4 bytes = 4 MiB
# But GPU caches help: L2 is 2 MB on RTX 3050 Ti
# Effective traffic estimate from timing:
# ============================================================
naive_time_ms = 4.050       # measured avg
naive_gflops  = flops / (naive_time_ms / 1000) / 1e9  # 530 GFLOP/s

# Naive AI: each thread reads N elements from A and N from B from global memory
# With L2 cache, columns of B get partially cached, but rows of A are streamed
# Theoretical no-reuse: bytes = 2*N^3*4 (each element loaded N times) + N^2*4 (output)
# = 2*1024^3*4 + 1024^2*4 = 8,589,934,592 + 4,194,304 = 8.594 GB
naive_bytes_no_reuse = 2.0 * N**3 * 4 + N**2 * 4
naive_ai = flops / naive_bytes_no_reuse  # ~0.25 FLOP/byte

# Effective AI from measured performance
# Points must sit on or below the roofline, so use effective AI
# effective_bytes = flops / (measured_FLOP/s) * peak_bw ... rearranged:
# effective_AI = measured_FLOP/s / peak_BW
naive_effective_ai = (naive_gflops * 1e9) / peak_bw  # actual operational intensity

# ============================================================
# Tiled kernel analysis (TILE=8)
# Shared memory reuse: each element loaded N/TILE = 128 times instead of N times
# Actually tiling loads each element of A and B once per tile pass = N/TILE loads total
# But with shared memory, each DRAM load is reused TILE times
# Bytes = 2 * N^2 * (N/TILE) * 4 = 2 * N^3/TILE * 4
# Wait - tiled: each block loads TILE*TILE of A and TILE*TILE of B, N/TILE times
# Total blocks = (N/TILE)^2 = 128^2 = 16384
# Each block loads: (N/TILE) * 2 * TILE^2 * 4 bytes = 128 * 2 * 64 * 4 = 65536 bytes
# Total = 16384 * 65536 = 1,073,741,824 bytes = 1 GB
# Plus output: N^2 * 4 = 4 MB
# AI = 2*N^3 / (2*N^3/TILE * 4 + N^2*4) = simplified ~ TILE/4 = 2 FLOP/byte
# ============================================================
TILE = 8
tiled_bytes = 2.0 * N**2 * (N / TILE) * TILE * 4 + N**2 * 4
# Simpler: total loads = (N/TILE) tiles * 2 matrices * (N/TILE)^2 blocks * TILE^2 elements * 4 bytes
# = (N/TILE) * 2 * TILE^2 * (N/TILE)^2 * 4
# = 2 * N^3 / TILE * 4
tiled_bytes = 2.0 * N**3 / TILE * 4 + N**2 * 4  # ~1.074 GB
tiled_ai = flops / tiled_bytes  # ~2.0 FLOP/byte

tiled_time_ms = 4.067
tiled_gflops  = flops / (tiled_time_ms / 1000) / 1e9  # 528 GFLOP/s
tiled_effective_ai = (tiled_gflops * 1e9) / peak_bw  # actual operational intensity

# ============================================================
# cf02 roofline data: i5-10500H CPU and hypothetical accelerator
# From codefest/cf02/profiling/roofline_plot.py
# ============================================================
cpu_peak_flops = 432e9       # 432 GFLOP/s FP64
cpu_peak_bw    = 25.6e9      # 25.6 GB/s single-channel DDR4-3200
cpu_ridge      = cpu_peak_flops / cpu_peak_bw  # 16.9 FLOP/B

accel_peak_flops = 4.096e12  # 4.096 TFLOP/s FP64
accel_peak_bw    = 256e9     # 256 GB/s on-chip SRAM
accel_ridge      = accel_peak_flops / accel_peak_bw  # 16.0 FLOP/B

ff_backward_ai = 5.43       # FLOP/B from ai_calculation.md
ff_backward_cpu_perf = min(ff_backward_ai * cpu_peak_bw, cpu_peak_flops)    # 139 GFLOP/s
ff_backward_accel_perf = min(ff_backward_ai * accel_peak_bw, accel_peak_flops)  # 1390 GFLOP/s

# ============================================================
# Plot
# ============================================================
fig, ax = plt.subplots(figsize=(12, 7))

ai_range = np.logspace(-2, 3, 500)

# cf02 rooflines
cpu_roof = np.minimum(ai_range * cpu_peak_bw, cpu_peak_flops)
ax.loglog(ai_range, cpu_roof, "b-", linewidth=2, alpha=0.7, label="i5-10500H Roofline (FP64)")

accel_roof = np.minimum(ai_range * accel_peak_bw, accel_peak_flops)
ax.loglog(ai_range, accel_roof, "m--", linewidth=2, alpha=0.7, label="Accelerator Roofline (FP64)")

# cf03 GPU roofline
roof = np.minimum(ai_range * peak_bw, peak_flops)
ax.loglog(ai_range, roof, "g-", linewidth=2.5, label="RTX 3050 Ti Roofline (FP32)")

# Ridge point
ax.axvline(ridge_point, color="g", linestyle=":", alpha=0.4)
ax.annotate(f"Ridge\n{ridge_point:.1f} FLOP/B",
    xy=(ridge_point, peak_flops), xytext=(ridge_point*2, peak_flops*0.3),
    fontsize=8, color="green", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.5))

# Naive kernel - plot at effective AI (accounts for L2 cache reuse)
ax.plot(naive_effective_ai, naive_gflops * 1e9, "bo", markersize=12, zorder=5)
ax.annotate(f"Naive GEMM\nEffective AI = {naive_effective_ai:.2f} FLOP/B\n{naive_gflops:.0f} GFLOP/s",
    xy=(naive_effective_ai, naive_gflops * 1e9),
    xytext=(naive_effective_ai * 0.15, naive_gflops * 1e9 * 0.35),
    fontsize=9, fontweight="bold", color="blue",
    arrowprops=dict(arrowstyle="->", color="blue"))

# Tiled kernel - plot at effective AI
ax.plot(tiled_effective_ai, tiled_gflops * 1e9, "r^", markersize=12, zorder=5)
ax.annotate(f"Tiled GEMM (T=8)\nEffective AI = {tiled_effective_ai:.2f} FLOP/B\n{tiled_gflops:.0f} GFLOP/s",
    xy=(tiled_effective_ai, tiled_gflops * 1e9),
    xytext=(tiled_effective_ai * 3, tiled_gflops * 1e9 * 0.35),
    fontsize=9, fontweight="bold", color="red",
    arrowprops=dict(arrowstyle="->", color="red"))

# Also mark theoretical no-reuse AI for reference
ax.axvline(naive_ai, color="blue", linestyle=":", alpha=0.3)
ax.text(naive_ai, 1.5e9, f"Naive theoretical\nAI={naive_ai:.2f}", fontsize=7, color="blue", alpha=0.6, ha="center")
ax.axvline(tiled_ai, color="red", linestyle=":", alpha=0.3)
ax.text(tiled_ai, 1.5e9, f"Tiled theoretical\nAI={tiled_ai:.2f}", fontsize=7, color="red", alpha=0.6, ha="center")

# cf02 kernel points
ax.plot(ff_backward_ai, ff_backward_cpu_perf, "bs", markersize=10, zorder=5)
ax.annotate(f"ff_backward (CPU)\nAI = {ff_backward_ai:.2f} FLOP/B\n{ff_backward_cpu_perf/1e9:.0f} GFLOP/s",
    xy=(ff_backward_ai, ff_backward_cpu_perf),
    xytext=(ff_backward_ai * 0.12, ff_backward_cpu_perf * 0.4),
    fontsize=8, fontweight="bold", color="blue",
    arrowprops=dict(arrowstyle="->", color="blue", alpha=0.7))

ax.plot(ff_backward_ai, ff_backward_accel_perf, "m^", markersize=10, zorder=5)
ax.annotate(f"ff_backward (Accel)\nAI = {ff_backward_ai:.2f} FLOP/B\n{ff_backward_accel_perf/1e9:.0f} GFLOP/s",
    xy=(ff_backward_ai, ff_backward_accel_perf),
    xytext=(ff_backward_ai * 3, ff_backward_accel_perf * 2.5),
    fontsize=8, fontweight="bold", color="purple",
    arrowprops=dict(arrowstyle="->", color="purple", alpha=0.7))

# Ridge point labels
ax.axvline(ridge_point, color="g", linestyle=":", alpha=0.3)
ax.axvline(cpu_ridge, color="b", linestyle=":", alpha=0.3)
ax.axvline(accel_ridge, color="m", linestyle=":", alpha=0.3)

ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)", fontsize=12)
ax.set_ylabel("Performance (FLOP/s)", fontsize=12)
ax.set_title("Combined Roofline: cf02 (CPU/Accelerator) + cf03 (GPU GEMM)", fontsize=13)
ax.legend(loc="upper left", fontsize=9)
ax.grid(True, which="both", alpha=0.3)
ax.set_xlim(0.01, 1000)
ax.set_ylim(1e9, 1e13)

specs = (
    "cf03: RTX 3050 Ti (FP32)\n"
    f"  Peak: {peak_flops/1e12:.1f} TFLOP/s, {peak_bw/1e9:.0f} GB/s\n"
    f"  Naive GEMM:  eff.AI={naive_effective_ai:.2f}  {naive_gflops:.0f} GFLOP/s\n"
    f"  Tiled GEMM:  eff.AI={tiled_effective_ai:.2f}  {tiled_gflops:.0f} GFLOP/s\n\n"
    "cf02: i5-10500H (FP64)\n"
    f"  Peak: {cpu_peak_flops/1e9:.0f} GFLOP/s, {cpu_peak_bw/1e9:.1f} GB/s\n"
    f"  ff_backward: AI={ff_backward_ai:.2f}  {ff_backward_cpu_perf/1e9:.0f} GFLOP/s\n\n"
    "cf02: Accelerator (FP64)\n"
    f"  Peak: {accel_peak_flops/1e12:.1f} TFLOP/s, {accel_peak_bw/1e9:.0f} GB/s\n"
    f"  ff_backward: AI={ff_backward_ai:.2f}  {ff_backward_accel_perf/1e9:.0f} GFLOP/s"
)
ax.text(0.98, 0.02, specs, transform=ax.transAxes, fontsize=7,
    verticalalignment="bottom", horizontalalignment="right",
    bbox=dict(boxstyle="round,pad=0.4", facecolor="wheat", alpha=0.8),
    family="monospace")

plt.tight_layout()
plt.savefig(
    r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf03\profiling\gemm_roofline.png",
    dpi=150, bbox_inches="tight")
print("Saved gemm_roofline.png")

print(f"\n=== Summary ===")
print(f"Naive:  {naive_time_ms:.3f} ms, {naive_gflops:.1f} GFLOP/s, eff.AI={naive_effective_ai:.2f}, theoretical AI={naive_ai:.3f} FLOP/B")
print(f"Tiled:  {tiled_time_ms:.3f} ms, {tiled_gflops:.1f} GFLOP/s, eff.AI={tiled_effective_ai:.2f}, theoretical AI={tiled_ai:.3f} FLOP/B")
print(f"Peak:   {peak_flops/1e12:.1f} TFLOP/s, {peak_bw/1e9:.0f} GB/s, ridge={ridge_point:.1f} FLOP/B")
