"""
Roofline plot with all platforms at FP32, including RTX 4080.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# i5-10500H CPU (FP32)
# ============================================================
cpu_peak_flops = 864e9       # 864 GFLOP/s FP32
cpu_peak_bw    = 25.6e9      # 25.6 GB/s single-channel DDR4-3200
cpu_ridge      = cpu_peak_flops / cpu_peak_bw

# ============================================================
# RTX 3050 Ti Laptop GPU (FP32)
# ============================================================
gpu3050_peak_flops = 5.3e12   # 5.3 TFLOP/s FP32
gpu3050_peak_bw    = 192e9    # 192 GB/s GDDR6
gpu3050_ridge      = gpu3050_peak_flops / gpu3050_peak_bw

# ============================================================
# RTX 4080 GPU (FP32)
# Source: NVIDIA RTX 4080 spec sheet
#   9728 CUDA cores, boost 2.51 GHz
#   FP32 peak: 48.7 TFLOP/s
#   Memory: 16 GB GDDR6X, 256-bit, 22.4 Gbps -> 716.8 GB/s
# ============================================================
gpu4080_peak_flops = 48.7e12  # 48.7 TFLOP/s FP32
gpu4080_peak_bw    = 716.8e9  # 716.8 GB/s GDDR6X
gpu4080_ridge      = gpu4080_peak_flops / gpu4080_peak_bw

# ============================================================
# Hypothetical accelerator (FP32)
# ============================================================
accel_peak_flops = 8.192e12  # 8.192 TFLOP/s FP32
accel_peak_bw    = 256e9     # 256 GB/s on-chip SRAM
accel_ridge      = accel_peak_flops / accel_peak_bw

# ============================================================
# Accelerator+ (FP32): adds attention (softmax unit) + wider SRAM bus
# Operator fusion (gelu_grad + softmax at systolic output) eliminates
# intermediate memory traffic. Wider SRAM bus (512 GB/s) to feed
# the combined ff_backward + attention workload.
# ~15% more area, ~1.5W more power, covers 80% of runtime
# ============================================================
accelp_peak_flops = 8.192e12  # Same systolic array compute
accelp_peak_bw    = 512e9     # 512 GB/s wider SRAM bus
accelp_ridge      = accelp_peak_flops / accelp_peak_bw

# ============================================================
# Kernel: ff_backward at FP32
# ============================================================
kernel_flops = 34_881_536
kernel_bytes_fp32 = 803_136 * 4
kernel_ai = kernel_flops / kernel_bytes_fp32  # ~10.86 FLOP/B

# Fused AI: both accelerators fuse gelu_grad at systolic output,
# eliminating intermediate memory traffic
# Fused bytes = (196,608 inputs + 49,472 outputs) * 4 = 984,320 bytes
fused_bytes_fp32 = 246_080 * 4  # 984,320 bytes
fused_ai = kernel_flops / fused_bytes_fp32  # ~35.4 FLOP/B

cpu_attainable     = min(kernel_ai * cpu_peak_bw, cpu_peak_flops)
gpu3050_attainable = min(kernel_ai * gpu3050_peak_bw, gpu3050_peak_flops)
gpu4080_attainable = min(kernel_ai * gpu4080_peak_bw, gpu4080_peak_flops)
accel_attainable   = min(fused_ai * accel_peak_bw, accel_peak_flops)
accelp_attainable  = min(fused_ai * accelp_peak_bw, accelp_peak_flops)

# ============================================================
# GEMM kernels (FP32, measured on 3050 Ti)
# ============================================================
N = 1024
gemm_flops = 2.0 * N * N * N

naive_time_ms = 4.050
naive_gflops  = gemm_flops / (naive_time_ms / 1000) / 1e9
naive_effective_ai = (naive_gflops * 1e9) / gpu3050_peak_bw

tiled_time_ms = 4.067
tiled_gflops  = gemm_flops / (tiled_time_ms / 1000) / 1e9
tiled_effective_ai = (tiled_gflops * 1e9) / gpu3050_peak_bw

# ============================================================
# Plot
# ============================================================
fig, ax = plt.subplots(figsize=(12, 7))
ai_range = np.logspace(-2, 3, 500)

# CPU roofline
cpu_roof = np.minimum(ai_range * cpu_peak_bw, cpu_peak_flops)
ax.loglog(ai_range, cpu_roof, "b-", linewidth=2, alpha=0.7,
    label=f"i5-10500H (FP32) — {cpu_peak_flops/1e9:.0f} GFLOP/s, {cpu_peak_bw/1e9:.1f} GB/s")

# RTX 3050 Ti roofline
gpu3050_roof = np.minimum(ai_range * gpu3050_peak_bw, gpu3050_peak_flops)
ax.loglog(ai_range, gpu3050_roof, "g-", linewidth=2.5,
    label=f"RTX 3050 Ti (FP32) — {gpu3050_peak_flops/1e12:.1f} TFLOP/s, {gpu3050_peak_bw/1e9:.0f} GB/s")

# RTX 4080 roofline
gpu4080_roof = np.minimum(ai_range * gpu4080_peak_bw, gpu4080_peak_flops)
ax.loglog(ai_range, gpu4080_roof, "r-", linewidth=2.5, alpha=0.8,
    label=f"RTX 4080 (FP32) — {gpu4080_peak_flops/1e12:.1f} TFLOP/s, {gpu4080_peak_bw/1e9:.0f} GB/s")

# Accelerator roofline
accel_roof = np.minimum(ai_range * accel_peak_bw, accel_peak_flops)
ax.loglog(ai_range, accel_roof, "m--", linewidth=2, alpha=0.7,
    label=f"Accelerator (FP32) — {accel_peak_flops/1e12:.1f} TFLOP/s, {accel_peak_bw/1e9:.0f} GB/s")

# Accelerator+ roofline
accelp_roof = np.minimum(ai_range * accelp_peak_bw, accelp_peak_flops)
ax.loglog(ai_range, accelp_roof, "m-", linewidth=2.5, alpha=0.8,
    label=f"Accelerator+ (FP32) — {accelp_peak_flops/1e12:.1f} TFLOP/s, {accelp_peak_bw/1e9:.0f} GB/s")

# Ridge point lines
for ridge, color in [(cpu_ridge, "b"), (gpu3050_ridge, "g"), (gpu4080_ridge, "r"), (accel_ridge, "m"), (accelp_ridge, "m")]:
    ax.axvline(ridge, color=color, linestyle=":", alpha=0.2)

# ff_backward kernel points
ax.plot(kernel_ai, cpu_attainable, "bs", markersize=10, zorder=5)
ax.annotate(f"ff_backward (CPU)\n{cpu_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, cpu_attainable),
    xytext=(kernel_ai * 0.08, cpu_attainable * 0.6),
    fontsize=8, fontweight="bold", color="blue",
    arrowprops=dict(arrowstyle="->", color="blue", alpha=0.7))

ax.plot(kernel_ai, gpu3050_attainable, "go", markersize=10, zorder=5)
ax.annotate(f"ff_backward (3050 Ti)\n{gpu3050_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, gpu3050_attainable),
    xytext=(kernel_ai * 2.5, gpu3050_attainable * 0.35),
    fontsize=8, fontweight="bold", color="green",
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.7))

ax.plot(kernel_ai, gpu4080_attainable, "ro", markersize=10, zorder=5)
ax.annotate(f"ff_backward (4080)\n{gpu4080_attainable/1e9:.0f} GFLOP/s",
    xy=(kernel_ai, gpu4080_attainable),
    xytext=(kernel_ai * 3, gpu4080_attainable * 2),
    fontsize=8, fontweight="bold", color="red",
    arrowprops=dict(arrowstyle="->", color="red", alpha=0.7))

ax.plot(fused_ai, accel_attainable, "m^", markersize=10, zorder=5)
ax.annotate(f"ff_backward (Accel fused)\nAI = {fused_ai:.1f} FLOP/B\n{accel_attainable/1e9:.0f} GFLOP/s",
    xy=(fused_ai, accel_attainable),
    xytext=(fused_ai * 0.08, accel_attainable * 0.4),
    fontsize=8, fontweight="bold", color="purple",
    arrowprops=dict(arrowstyle="->", color="purple", alpha=0.7))

ax.plot(fused_ai, accelp_attainable, "mD", markersize=12, zorder=5)
ax.annotate(f"ff_backward (Accel+ fused)\nAI = {fused_ai:.1f} FLOP/B\n{accelp_attainable/1e9:.0f} GFLOP/s\nCOMPUTE-BOUND",
    xy=(fused_ai, accelp_attainable),
    xytext=(fused_ai * 2, accelp_attainable * 0.25),
    fontsize=8, fontweight="bold", color="purple",
    arrowprops=dict(arrowstyle="->", color="purple", alpha=0.7))

# GEMM kernel points (measured on 3050 Ti)
ax.plot(naive_effective_ai, naive_gflops * 1e9, "gd", markersize=8, zorder=5, alpha=0.6)
ax.annotate(f"Naive GEMM\n{naive_gflops:.0f} GFLOP/s",
    xy=(naive_effective_ai, naive_gflops * 1e9),
    xytext=(naive_effective_ai * 0.15, naive_gflops * 1e9 * 0.5),
    fontsize=7, color="green", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.5))

ax.plot(tiled_effective_ai, tiled_gflops * 1e9, "gv", markersize=8, zorder=5, alpha=0.6)
ax.annotate(f"Tiled GEMM\n{tiled_gflops:.0f} GFLOP/s",
    xy=(tiled_effective_ai, tiled_gflops * 1e9),
    xytext=(tiled_effective_ai * 2.5, tiled_gflops * 1e9 * 0.4),
    fontsize=7, color="green", alpha=0.7,
    arrowprops=dict(arrowstyle="->", color="green", alpha=0.5))

ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)", fontsize=12)
ax.set_ylabel("Performance (FLOP/s)", fontsize=12)
ax.set_title("Combined Roofline (FP32): CPU / RTX 3050 Ti / RTX 4080 / Accelerator", fontsize=13)
ax.legend(loc="upper left", fontsize=9)
ax.grid(True, which="both", alpha=0.3)
ax.set_xlim(0.01, 1000)
ax.set_ylim(1e9, 1e14)

specs = (
    "All platforms at FP32, AI = {:.1f} FLOP/B\n\n".format(kernel_ai) +
    f"  CPU:       {cpu_attainable/1e9:>6.0f} GFLOP/s  (ridge={cpu_ridge:.1f})\n"
    f"  3050 Ti:   {gpu3050_attainable/1e9:>6.0f} GFLOP/s  (ridge={gpu3050_ridge:.1f})\n"
    f"  Accel:     {accel_attainable/1e9:>6.0f} GFLOP/s  (fused AI={fused_ai:.1f})\n"
    f"  Accel+:    {accelp_attainable/1e9:>6.0f} GFLOP/s  (fused AI={fused_ai:.1f})\n"
    f"  4080:      {gpu4080_attainable/1e9:>6.0f} GFLOP/s  (ridge={gpu4080_ridge:.1f})"
)
ax.text(0.98, 0.02, specs, transform=ax.transAxes, fontsize=7.5,
    verticalalignment="bottom", horizontalalignment="right",
    bbox=dict(boxstyle="round,pad=0.4", facecolor="wheat", alpha=0.8),
    family="monospace")

plt.tight_layout()
plt.savefig(
    r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf03\profiling\max.png",
    dpi=150, bbox_inches="tight")
print("Saved max.png")
print(f"\nff_backward FP32: AI={kernel_ai:.2f} FLOP/B")
print(f"  CPU:     {cpu_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < cpu_ridge else 'compute-bound'}")
print(f"  3050 Ti: {gpu3050_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < gpu3050_ridge else 'compute-bound'}")
print(f"  4080:    {gpu4080_attainable/1e9:.0f} GFLOP/s  {'mem-bound' if kernel_ai < gpu4080_ridge else 'compute-bound'}")
print(f"  Accel:   {accel_attainable/1e9:.0f} GFLOP/s  fused AI={fused_ai:.1f}  {'mem-bound' if fused_ai < accel_ridge else 'COMPUTE-BOUND'}")
print(f"  Accel+:  {accelp_attainable/1e9:.0f} GFLOP/s  fused AI={fused_ai:.1f}  {'mem-bound' if fused_ai < accelp_ridge else 'COMPUTE-BOUND'}")
