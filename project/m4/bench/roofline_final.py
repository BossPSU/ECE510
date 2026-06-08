"""
Generate roofline_final.png for the M4 deliverable.

Two rooflines:
  - M1 CPU target: i5-10500H, 25.6 GB/s single-channel DDR4-3200,
    peak FLOP/s estimate from M1 docs.
  - M4 accelerator: 4096 PEs @ 500 MHz, 2 FLOP/MAC -> 4.096 TFLOP/s peak.
    Effective off-chip BW is the UCIe-like chiplet channel; we use the
    same DRAM-side 25.6 GB/s for an apples-to-apples external-BW point
    and additionally show the on-chip SRAM-driven ridge (since the
    architecture's reuse pattern keeps the working set on-chip after
    the initial load).

Two measured points:
  - M1 SW baseline sustained: 3.398 GFLOP/s @ AI=5.43 FLOPs/byte.
  - M4 measured on a single 64x64 FFN_BWD tile: 8.07 GFLOP/s
    (includes load+drain overhead). AI computed from FLOPs / bytes-moved
    over the chiplet boundary for that macro.

Run:
    python roofline_final.py
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def roofline(ai_grid, peak_flops, bw_bytes_per_sec):
    return np.minimum(peak_flops, bw_bytes_per_sec * ai_grid)


def main():
    ai = np.logspace(-1, 4, 1000)  # 0.1 .. 10,000 FLOPs/byte

    # ---- M1 CPU target -------------------------------------------------------
    # i5-10500H: ~6 cores * 4.5 GHz boost * 16 FLOP/cycle (AVX2 fma fp64)
    # = 432 GFLOP/s peak in theory; M1 docs use the empirically-attainable
    # "139 GFLOP/s at AI=5.43" which is DRAM-bound on the single-channel
    # 25.6 GB/s line. We plot both: theoretical peak ceiling + DRAM line.
    cpu_peak_gflops    = 432.0
    cpu_bw_gbps        = 25.6  # single-channel DDR4-3200

    cpu_roof = roofline(ai, cpu_peak_gflops, cpu_bw_gbps)

    # ---- M4 accelerator ------------------------------------------------------
    # 64x64 = 4096 PEs * 500 MHz * 2 FLOP/MAC = 4096 GFLOP/s peak.
    accel_peak_gflops  = 4096.0
    # External-channel (UCIe-style) bandwidth: bound by interface.sv -- a
    # single 32-bit Q16.16 word per cycle at 500 MHz on the host-side ports
    # = 4 B/cycle * 500 MHz = 2 GB/s. All bytes in this plot are counted
    # at the Q16.16 wire/scratchpad format (4 B/element), the format that
    # actually moves through the memory hierarchy until the MAC input.
    accel_extbw_gbps   = 2.0
    # On-chip SRAM-feed bandwidth into the systolic array: 64 rows feed
    # the array each cycle from tile_buffer holding Q16.16 (4 B/elem)
    # = 64 elements/cycle * 4 B * 500 MHz = 128 GB/s.
    accel_sram_gbps    = 128.0

    accel_roof_ext  = roofline(ai, accel_peak_gflops, accel_extbw_gbps)
    accel_roof_sram = roofline(ai, accel_peak_gflops, accel_sram_gbps)

    # ---- Measured points -----------------------------------------------------
    # M1 baseline: FFN backward, AI=5.43, attained 3.398 GFLOP/s.
    sw_point = (5.43, 3.398)

    # M4 single-tile measurement: ff_backward macro = 32,989 cycles @ 500 MHz.
    # FLOPs/macro = 2 * (64*64*64 MACs) + 64*64*2 (GELU' multiply) = 532,480
    # Bytes moved over chiplet boundary for one macro: 3 tile loads (A, B, AUX)
    # + 1 output write-back, each 4096 Q16.16 elements * 4 B = 16,384 B per
    # tile * 4 tiles = 65,536 B total.
    # AI = 532480 / 65536 = 8.12 FLOPs/byte (Q16.16 wire).
    # Attained = 532480 FLOP / 65.978e-6 s = 8.07 GFLOP/s.
    m4_point_meas = (8.12, 8.07)

    # ---- Plot ---------------------------------------------------------------
    fig, ax = plt.subplots(figsize=(8.5, 5.5))

    # CPU roofline (dashed line, blue)
    ax.plot(ai, cpu_roof, "b--", lw=2.0, label=f"CPU (i5-10500H, DDR4 25.6 GB/s) peak {cpu_peak_gflops:.0f} GFLOP/s")

    # M4 accelerator roofline -- external channel (orange, dotted) and SRAM (red, solid)
    ax.plot(ai, accel_roof_ext, "orange", lw=1.8, linestyle=":", label=f"M4 ext channel ({accel_extbw_gbps:.0f} GB/s UCIe-like) peak {accel_peak_gflops:.0f} GFLOP/s")
    ax.plot(ai, accel_roof_sram, "r-", lw=2.2, label=f"M4 on-chip SRAM ({accel_sram_gbps:.0f} GB/s tile-buffer) peak {accel_peak_gflops:.0f} GFLOP/s")

    # Points
    ax.scatter(*sw_point, marker="o", s=120, c="blue", edgecolors="black", zorder=5, label=f"M1 SW baseline: {sw_point[1]:.2f} GFLOP/s @ AI={sw_point[0]:.2f}")
    # M1 annotation: place BELOW the marker in clear air (legend is at
    # bottom-right; M4 annotation occupies upper-right of this marker).
    ax.annotate(f"M1 baseline\n{sw_point[1]:.2f} GFLOP/s", sw_point, xytext=(-46, -30), textcoords="offset points", fontsize=9, ha="left")

    ax.scatter(*m4_point_meas, marker="*", s=240, c="red", edgecolors="black", zorder=5, label=f"M4 measured (1 FFN_BWD tile): {m4_point_meas[1]:.2f} GFLOP/s @ AI={m4_point_meas[0]:.2f}")
    # M4 annotation: place ABOVE-LEFT of the star to avoid colliding with
    # the M1 marker (which sits down and to the left) and the legend.
    ax.annotate(
        f"M4 measured\n{m4_point_meas[1]:.2f} GFLOP/s @ AI={m4_point_meas[0]:.2f}\n(~50% of interface roof,\nbus-bound after fill/drain)",
        m4_point_meas,
        xytext=(-130, 18),
        textcoords="offset points",
        fontsize=9,
        ha="left",
        arrowprops=dict(arrowstyle="->", color="red", lw=0.8, alpha=0.6),
    )

    # M4 peak ridge marker (where compute = memory)
    ridge_sram_ai  = accel_peak_gflops / accel_sram_gbps
    ridge_ext_ai   = accel_peak_gflops / accel_extbw_gbps
    ax.axvline(ridge_sram_ai, color="red", alpha=0.25, linestyle="--", lw=1.0)
    ax.text(ridge_sram_ai * 1.05, 20, f"M4 SRAM ridge\nAI={ridge_sram_ai:.0f}", fontsize=8, color="red", alpha=0.8)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(1e-1, 1e4)
    ax.set_ylim(1e0, 1e4)
    ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)")
    ax.set_ylabel("Performance (GFLOP/s)")
    ax.set_title("M4 Roofline -- Transformer FFN_BWD kernel, M1 baseline vs M4 accelerator")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="lower right", fontsize=8)

    plt.tight_layout()
    plt.savefig("roofline_final.png", dpi=140)
    print("wrote roofline_final.png")


if __name__ == "__main__":
    main()
