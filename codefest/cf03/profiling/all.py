"""
Roofline plot with both ff_backward and attention kernels plotted
for all platforms at FP32. Shows why Accel+ matters.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ============================================================
# Platform specs (FP32)
# ============================================================
cpu_peak_flops = 864e9
cpu_peak_bw    = 25.6e9
cpu_ridge      = cpu_peak_flops / cpu_peak_bw

gpu3050_peak_flops = 5.3e12
gpu3050_peak_bw    = 192e9
gpu3050_ridge      = gpu3050_peak_flops / gpu3050_peak_bw

gpu4080_peak_flops = 48.7e12
gpu4080_peak_bw    = 716.8e9
gpu4080_ridge      = gpu4080_peak_flops / gpu4080_peak_bw

accel_peak_flops = 8.192e12
accel_peak_bw    = 256e9
accel_ridge      = accel_peak_flops / accel_peak_bw

accelp_peak_flops = 8.192e12
accelp_peak_bw    = 512e9
accelp_ridge      = accelp_peak_flops / accelp_peak_bw

# ============================================================
# Kernel 1: ff_backward (FP32)
# FLOPs: 34,881,536 (4 matmuls + gelu_grad + reductions)
# ============================================================
ff_flops = 34_881_536

# Unfused: all operands loaded/stored including intermediates
ff_bytes_unfused = 803_136 * 4   # 3,212,544 bytes
ff_ai_unfused = ff_flops / ff_bytes_unfused  # 10.86 FLOP/B

# Fused: intermediates (dh_act, gelu_grad result, dh) stay in registers
# Only external inputs + final outputs touch SRAM
# Inputs:  dout(16384) + W2(16384) + h(65536) + h_act(65536) + x(16384) + W1(16384) = 196,608
# Outputs: dx(16384) + dW1(16384) + db1(256) + dW2(16384) + db2(64) = 49,472
ff_bytes_fused = (196_608 + 49_472) * 4  # 984,320 bytes
ff_ai_fused = ff_flops / ff_bytes_fused  # 35.4 FLOP/B

# ============================================================
# Kernel 2: mha_forward + mha_backward (attention, FP32)
# Config: B=4, T=64, D=64, H=4, d_head=16
# ============================================================
B, T, D, H = 4, 64, 64, 4
d_head = D // H
N_tok = B * T  # 256

# mha_forward FLOPs:
#   Q = x @ Wq:           2 * N * D * D = 2,097,152
#   K = x @ Wk:           2,097,152
#   V = x @ Wv:           2,097,152
#   scores = Q @ K.T:     B*H * 2*T*T*d_head = 16 * 2*64*64*16 = 2,097,152
#   softmax:               ~3 * B*H*T*T = 3*16*4096 = 196,608
#   ctx = attn @ V:        2,097,152
#   out = ctx @ Wo:        2,097,152
fwd_matmuls = 6 * (2 * N_tok * D * D)  # Q,K,V,scores,attn@V,Wo = but scores and attn@V have different dims
# More precisely:
fwd_qkv = 3 * (2 * N_tok * D * D)                    # 3 * 2,097,152 = 6,291,456
fwd_scores = B * H * (2 * T * d_head * T)              # 16 * 131,072  = 2,097,152
fwd_attnv = B * H * (2 * T * T * d_head)               # 16 * 131,072  = 2,097,152
fwd_wo = 2 * N_tok * D * D                             # 2,097,152
fwd_softmax = 3 * B * H * T * T                         # 196,608
mha_fwd_flops = fwd_qkv + fwd_scores + fwd_attnv + fwd_wo + fwd_softmax  # 12,779,520

# mha_backward FLOPs:
#   dctx @ Wo.T:           2 * N * D * D = 2,097,152
#   dWo = ctx.T @ dout:    2,097,152
#   dV = attn.T @ dctx:    B*H * 2*T*T*d_head = 2,097,152
#   dattn = dctx @ V.T:    2,097,152
#   softmax_backward:      ~4 * B*H*T*T = 262,144
#   dQ = dscores @ K:      2,097,152
#   dK = dscores.T @ Q:    2,097,152
#   dx = dQ@Wq.T + dK@Wk.T + dV@Wv.T:  3 * 2,097,152 = 6,291,456
#   dWq, dWk, dWv:         3 * 2,097,152 = 6,291,456
#   bias grads (bq,bk,bv,bo): 4 * N*D = 65,536
bwd_matmuls = 10 * (2 * N_tok * D * D)  # rough: most are (N,D)@(D,D) or equivalent
# More precisely:
bwd_wo = 2 * (2 * N_tok * D * D)                       # dctx@Wo.T + dWo: 4,194,304
bwd_attn = B * H * 2 * (2 * T * T * d_head)             # dV + dattn: 4,194,304
bwd_softmax = 4 * B * H * T * T                         # 262,144
bwd_qk = B * H * 2 * (2 * T * d_head * T)               # dQ + dK: 4,194,304
bwd_proj = 3 * (2 * N_tok * D * D)                      # dx components: 6,291,456
bwd_wgrad = 3 * (2 * N_tok * D * D)                     # dWq,dWk,dWv: 6,291,456
bwd_bias = 4 * N_tok * D                                 # 65,536
mha_bwd_flops = bwd_wo + bwd_attn + bwd_softmax + bwd_qk + bwd_proj + bwd_wgrad + bwd_bias
# = 4,194,304 + 4,194,304 + 262,144 + 4,194,304 + 6,291,456 + 6,291,456 + 65,536 = 25,493,504

attn_flops = mha_fwd_flops + mha_bwd_flops  # ~38,273,024

# Attention bytes (unfused): all inputs, outputs, AND intermediates
# Inputs: x(N*D), Wq,Wk,Wv,Wo(D*D each), biases(4*D)
# Intermediates: Q,K,V(N*D each), scores(B*H*T*T), attn(B*H*T*T), ctx(N*D)
#   + backward intermediates: dctx, dattn, dscores, dQ, dK, dV (same shapes)
# Outputs: out(N*D), dWq,dWk,dWv,dWo(D*D each), dbq,dbk,dbv,dbo(D each), dx(N*D)
attn_input_elems = N_tok*D + 4*D*D + 4*D                 # 33,024
attn_output_elems = N_tok*D + 4*D*D + 4*D + N_tok*D      # 49,408
attn_intermediate_elems = (
    3 * N_tok * D +          # Q, K, V
    2 * B * H * T * T +      # scores, attn
    N_tok * D +              # ctx
    # backward intermediates
    N_tok * D +              # dctx
    2 * B * H * T * T +      # dattn, dscores
    3 * N_tok * D            # dQ, dK, dV
)  # = 6*N*D + 4*B*H*T*T = 6*16384 + 4*65536 = 98,304 + 262,144 = 360,448

attn_bytes_unfused = (attn_input_elems + attn_output_elems + attn_intermediate_elems) * 4
attn_ai_unfused = attn_flops / attn_bytes_unfused

# Fused attention: only external inputs/outputs, intermediates stay on-chip
attn_bytes_fused = (attn_input_elems + attn_output_elems) * 4
attn_ai_fused = attn_flops / attn_bytes_fused

print(f"Attention FLOPs: {attn_flops:,}")
print(f"Attention unfused: {attn_bytes_unfused:,} bytes, AI = {attn_ai_unfused:.2f} FLOP/B")
print(f"Attention fused:   {attn_bytes_fused:,} bytes, AI = {attn_ai_fused:.2f} FLOP/B")

# ============================================================
# Attainable performance for each kernel on each platform
# ============================================================
def attainable(ai, peak_flops, peak_bw):
    return min(ai * peak_bw, peak_flops)

platforms = {
    "CPU":     (cpu_peak_flops, cpu_peak_bw, cpu_ridge, "b", "s"),
    "3050 Ti": (gpu3050_peak_flops, gpu3050_peak_bw, gpu3050_ridge, "g", "o"),
    "4080":    (gpu4080_peak_flops, gpu4080_peak_bw, gpu4080_ridge, "r", "o"),
    "Accel":   (accel_peak_flops, accel_peak_bw, accel_ridge, "m", "^"),
    "Accel+":  (accelp_peak_flops, accelp_peak_bw, accelp_ridge, "m", "D"),
}

# ============================================================
# Plot
# ============================================================
fig, ax = plt.subplots(figsize=(13, 7))
ai_range = np.logspace(-2, 3, 500)

# Draw rooflines
for name, (pf, pb, ridge, color, _) in platforms.items():
    style = "--" if name == "Accel" else "-"
    alpha = 0.7 if name in ("CPU", "Accel") else 0.85
    lw = 2.5 if name in ("4080", "Accel+", "3050 Ti") else 2
    roof = np.minimum(ai_range * pb, pf)
    ax.loglog(ai_range, roof, color=color, linestyle=style, linewidth=lw, alpha=alpha,
        label=f"{name} — {pf/1e12:.1f}T, {pb/1e9:.0f} GB/s" if pf >= 1e12 else f"{name} — {pf/1e9:.0f}G, {pb/1e9:.1f} GB/s")
    ax.axvline(ridge, color=color, linestyle=":", alpha=0.15)

# ---- ff_backward points ----
# CPU, 3050, 4080: unfused AI (they can't fuse)
for name in ["CPU", "3050 Ti", "4080"]:
    pf, pb, ridge, color, marker = platforms[name]
    perf = attainable(ff_ai_unfused, pf, pb)
    ax.plot(ff_ai_unfused, perf, color=color, marker=marker, markersize=9, zorder=5)
    bound = "mem" if ff_ai_unfused < ridge else "comp"
    # Annotation positions
    if name == "CPU":
        xt, yt = ff_ai_unfused * 0.08, perf * 0.7
    elif name == "3050 Ti":
        xt, yt = ff_ai_unfused * 0.08, perf * 1.8
    else:
        xt, yt = ff_ai_unfused * 2.5, perf * 2
    ax.annotate(f"ff_bwd ({name})\n{perf/1e9:.0f} G/s [{bound}]",
        xy=(ff_ai_unfused, perf), xytext=(xt, yt),
        fontsize=7, fontweight="bold", color=color,
        arrowprops=dict(arrowstyle="->", color=color, alpha=0.6))

# Accel, Accel+: fused AI
for name in ["Accel", "Accel+"]:
    pf, pb, ridge, color, marker = platforms[name]
    perf = attainable(ff_ai_fused, pf, pb)
    ax.plot(ff_ai_fused, perf, color=color, marker=marker, markersize=10, zorder=5)
    bound = "mem" if ff_ai_fused < ridge else "COMP"
    if name == "Accel":
        xt, yt = ff_ai_fused * 2, perf * 0.3
    else:
        xt, yt = ff_ai_fused * 2.5, perf * 0.4
    ax.annotate(f"ff_bwd ({name} fused)\n{perf/1e9:.0f} G/s [{bound}]",
        xy=(ff_ai_fused, perf), xytext=(xt, yt),
        fontsize=7, fontweight="bold", color=color,
        arrowprops=dict(arrowstyle="->", color=color, alpha=0.6))

# ---- attention points ----
# CPU, 3050, 4080: unfused AI
for name in ["CPU", "3050 Ti", "4080"]:
    pf, pb, ridge, color, marker = platforms[name]
    perf = attainable(attn_ai_unfused, pf, pb)
    ax.plot(attn_ai_unfused, perf, color=color, marker="*", markersize=10, zorder=5, alpha=0.7)
    bound = "mem" if attn_ai_unfused < ridge else "comp"
    if name == "CPU":
        xt, yt = attn_ai_unfused * 0.1, perf * 0.35
    elif name == "3050 Ti":
        xt, yt = attn_ai_unfused * 0.1, perf * 2
    else:
        xt, yt = attn_ai_unfused * 2, perf * 0.35
    ax.annotate(f"attn ({name})\n{perf/1e9:.0f} G/s [{bound}]",
        xy=(attn_ai_unfused, perf), xytext=(xt, yt),
        fontsize=7, color=color, alpha=0.8,
        arrowprops=dict(arrowstyle="->", color=color, alpha=0.4))

# Accel+: fused attention (Accel doesn't have softmax unit, so no attn point for it)
pf, pb, ridge, color, marker = platforms["Accel+"]
perf_attn_accelp = attainable(attn_ai_fused, pf, pb)
ax.plot(attn_ai_fused, perf_attn_accelp, color=color, marker="*", markersize=12, zorder=5)
bound = "mem" if attn_ai_fused < ridge else "COMP"
ax.annotate(f"attn (Accel+ fused)\n{perf_attn_accelp/1e9:.0f} G/s [{bound}]",
    xy=(attn_ai_fused, perf_attn_accelp),
    xytext=(attn_ai_fused * 0.07, perf_attn_accelp * 1.5),
    fontsize=7, fontweight="bold", color=color,
    arrowprops=dict(arrowstyle="->", color=color, alpha=0.6))

# Labels
ax.set_xlabel("Arithmetic Intensity (FLOPs / Byte)", fontsize=12)
ax.set_ylabel("Performance (FLOP/s)", fontsize=12)
ax.set_title("Combined Roofline (FP32): ff_backward + Attention — All Platforms", fontsize=13)
ax.legend(loc="upper left", fontsize=8)
ax.grid(True, which="both", alpha=0.3)
ax.set_xlim(0.05, 1000)
ax.set_ylim(1e9, 1e14)

# Specs box
specs = (
    "FP32 Roofline — two kernels plotted\n"
    f"  ff_backward: {ff_flops:,} FLOPs\n"
    f"    unfused AI = {ff_ai_unfused:.1f}, fused AI = {ff_ai_fused:.1f}\n"
    f"  attention:   {attn_flops:,} FLOPs\n"
    f"    unfused AI = {attn_ai_unfused:.1f}, fused AI = {attn_ai_fused:.1f}\n\n"
    "  ★ = attention kernel\n"
    "  ● / ■ / ▲ / ◆ = ff_backward kernel"
)
ax.text(0.98, 0.02, specs, transform=ax.transAxes, fontsize=7,
    verticalalignment="bottom", horizontalalignment="right",
    bbox=dict(boxstyle="round,pad=0.4", facecolor="wheat", alpha=0.8),
    family="monospace")

plt.tight_layout()
plt.savefig(
    r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf03\profiling\all.png",
    dpi=150, bbox_inches="tight")
print("Saved all.png")
