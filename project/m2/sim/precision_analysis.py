#!/usr/bin/env python3
"""
precision_analysis.py — Q16.16 vs FP32 quantization-error study for the
ECE 410/510 M2 deliverable. Compares the dominant kernels of the chiplet
(GEMM + GELU forward, GELU' for backward, softmax) on 100 random inputs
and reports MAE, max error, and relative error so precision.md can
quote them with provenance.

Usage:
    python3 precision_analysis.py > precision_results.txt
"""
import math
import random

random.seed(0xECE510)
N_SAMPLES = 100
FRAC = 16
ONE = 1 << FRAC
INT_MAX_Q1616 = (1 << 31) - 1
INT_MIN_Q1616 = -(1 << 31)


def to_q(x: float) -> int:
    q = int(x * ONE)
    return max(INT_MIN_Q1616, min(INT_MAX_Q1616, q))


def from_q(q: int) -> float:
    return q / ONE


def q_mul(a: int, b: int) -> int:
    """Truncating Q16.16 multiply, matches accel_pkg::q_mul."""
    p = a * b
    return (p >> FRAC) & 0xFFFFFFFF if (p >> FRAC) >= 0 else \
        ((p >> FRAC) | ~0xFFFFFFFF)


def q_mul_clean(a_q: int, b_q: int) -> int:
    # Mirror SystemVerilog 32-bit truncation behaviour
    p = a_q * b_q
    p32 = (p >> FRAC) & 0xFFFFFFFF
    if p32 & (1 << 31):
        p32 -= 1 << 32
    return p32


# ---- GELU (clamped polynomial in DUT) -----------------------------------
SQRT_2_PI = 0.7978845608
GELU_C1 = 0.044715
CLAMP_X = 16.0


def gelu_fp32(x: float) -> float:
    z = SQRT_2_PI * (x + GELU_C1 * x * x * x)
    return 0.5 * x * (1.0 + math.tanh(z))


def gelu_q1616(x: float) -> float:
    # Clamp the input that goes into the polynomial (matches gelu_unit.sv)
    xp = max(-CLAMP_X, min(CLAMP_X, x))
    z = SQRT_2_PI * (xp + GELU_C1 * xp * xp * xp)
    # Saturate z to [-4, 4] (matches Q_SAT_POS / Q_SAT_NEG)
    if z > 4.0:
        t = 1.0
    elif z < -4.0:
        t = -1.0
    else:
        # Pade(z) = z*(27+z^2) / (27+9*z^2)
        t = z * (27.0 + z * z) / (27.0 + 9.0 * z * z)
    # Forward path uses ORIGINAL x, not clamped, in the final 0.5*x*(1+t)
    return 0.5 * x * (1.0 + t)


# ---- Softmax (range-reduced exp) ---------------------------------------
def softmax_fp32(scores):
    m = max(scores)
    e = [math.exp(s - m) for s in scores]
    z = sum(e)
    return [v / z for v in e]


def q_exp_approx(x: float) -> float:
    if x >= 0.0:
        return 1.0
    if x < -16.0:
        return 0.0
    y = x / 4.0
    num = 12.0 + 6.0 * y + y * y
    den = 12.0 - 6.0 * y + y * y
    p = num / den
    return p ** 4   # range-reduced Pade


def softmax_q1616(scores):
    m = max(scores)
    e = [q_exp_approx(s - m) for s in scores]
    z = sum(e)
    return [v / z if z > 0 else 0.0 for v in e]


# ---- GELU gradient -----------------------------------------------------
def gelu_grad_fp32(x: float) -> float:
    z = SQRT_2_PI * (x + GELU_C1 * x * x * x)
    t = math.tanh(z)
    dt = 1.0 - t * t
    return 0.5 * (1.0 + t) + \
           0.5 * x * dt * SQRT_2_PI * (1.0 + 3.0 * GELU_C1 * x * x)


def gelu_grad_q1616(x: float) -> float:
    xp = max(-CLAMP_X, min(CLAMP_X, x))
    z = SQRT_2_PI * (xp + GELU_C1 * xp * xp * xp)
    if z > 4.0:
        t, dt = 1.0, 0.0
    elif z < -4.0:
        t, dt = -1.0, 0.0
    else:
        t = z * (27.0 + z * z) / (27.0 + 9.0 * z * z)
        dt = 1.0 - t * t
    return 0.5 * (1.0 + t) + \
           0.5 * x * dt * SQRT_2_PI * (1.0 + 3.0 * GELU_C1 * xp * xp)


# ---- GEMM (Q16.16 truncating) ------------------------------------------
def gemm_fp32(A, B, M, K, N):
    out = [[0.0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            s = 0.0
            for k in range(K):
                s += A[i][k] * B[k][j]
            out[i][j] = s
    return out


def gemm_q1616(A, B, M, K, N):
    out = [[0.0] * N for _ in range(M)]
    for i in range(M):
        for j in range(N):
            acc = 0  # 32-bit Q16.16 accumulator
            for k in range(K):
                a_q = to_q(A[i][k])
                b_q = to_q(B[k][j])
                acc += q_mul_clean(a_q, b_q)
                # 32-bit signed wrap
                acc &= 0xFFFFFFFF
                if acc & (1 << 31):
                    acc -= 1 << 32
            out[i][j] = from_q(acc)
    return out


# ---- Stat helpers ------------------------------------------------------
def stats(label: str, fp_vals, q_vals):
    n = len(fp_vals)
    abs_err = [abs(a - b) for a, b in zip(fp_vals, q_vals)]
    rel_err = []
    for a, b in zip(fp_vals, q_vals):
        denom = max(abs(a), 1e-9)
        rel_err.append(abs(a - b) / denom)
    mae = sum(abs_err) / n
    max_e = max(abs_err)
    mre = sum(rel_err) / n
    print(f"{label:<24s}  N={n:3d}  "
          f"MAE={mae:.6e}  max={max_e:.6e}  meanRelErr={mre:.4%}")
    return mae, max_e, mre


# ---- Kernels driven on 100 random samples ------------------------------
print("=" * 68)
print(" Q16.16 vs FP32 quantization-error analysis (100 samples each)")
print(" Seed = 0xECE510 — reproducible.")
print("=" * 68)

# 1) GELU forward, x in [-3, 3] (typical pre-activation range)
xs = [random.uniform(-3.0, 3.0) for _ in range(N_SAMPLES)]
fp = [gelu_fp32(x) for x in xs]
q  = [gelu_q1616(x) for x in xs]
stats("gelu  (x in [-3,3])", fp, q)

# 2) GELU forward, x in [-50, 50] (saturated regime; tests the clamp fix)
xs = [random.uniform(-50.0, 50.0) for _ in range(N_SAMPLES)]
fp = [gelu_fp32(x) for x in xs]
q  = [gelu_q1616(x) for x in xs]
stats("gelu  (x in [-50,50])", fp, q)

# 3) GELU' (gradient)
xs = [random.uniform(-3.0, 3.0) for _ in range(N_SAMPLES)]
fp = [gelu_grad_fp32(x) for x in xs]
q  = [gelu_grad_q1616(x) for x in xs]
stats("gelu_grad  (x in [-3,3])", fp, q)

# 4) Softmax row, scores in [-4, 4]
fp_all, q_all = [], []
for _ in range(N_SAMPLES // 4):
    scores = [random.uniform(-4.0, 4.0) for _ in range(4)]
    fp_all += softmax_fp32(scores)
    q_all  += softmax_q1616(scores)
stats("softmax row in [-4,4]", fp_all, q_all)

# 5) Softmax row with wider score range, [-8, 0]
fp_all, q_all = [], []
for _ in range(N_SAMPLES // 4):
    scores = [random.uniform(-8.0, 0.0) for _ in range(4)]
    fp_all += softmax_fp32(scores)
    q_all  += softmax_q1616(scores)
stats("softmax row in [-8,0]", fp_all, q_all)

# 6) GEMM 2x2x2 with values in [-2, 2]
fp_all, q_all = [], []
for _ in range(N_SAMPLES // 4):
    A = [[random.uniform(-2.0, 2.0) for _ in range(2)] for _ in range(2)]
    B = [[random.uniform(-2.0, 2.0) for _ in range(2)] for _ in range(2)]
    fp_o = gemm_fp32(A, B, 2, 2, 2)
    q_o  = gemm_q1616(A, B, 2, 2, 2)
    for r in range(2):
        for c in range(2):
            fp_all.append(fp_o[r][c])
            q_all.append(q_o[r][c])
stats("gemm 2x2x2 in [-2,2]", fp_all, q_all)

print("=" * 68)
