#!/usr/bin/env python3
"""analyze_sweep.py -- Fit area(N) = a + b*N^2 + c*N to the sweep data and
extrapolate to 64x64. Emits derived metrics and (if matplotlib available)
a PDF plot for the M3 writeup.

Inputs:
    sweep_results.csv -- produced by collect_sweep_csv.py

Outputs:
    sweep_metrics.txt   -- numeric summary
    sweep_figure.pdf    -- area-vs-N^2 plot with extrapolation (optional)

Usage:
    python3 analyze_sweep.py [--csv sweep_results.csv]
                             [--out-txt sweep_metrics.txt]
                             [--out-pdf sweep_figure.pdf]
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:
    print("ERROR: numpy is required (pip install numpy).", file=sys.stderr)
    sys.exit(1)


def _safe_float(x: str) -> float | None:
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def load_csv(path: Path) -> list[dict]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def filter_by_top(rows: list[dict], top: str) -> list[tuple[int, float]]:
    """Return sorted list of (N, total_area_um2) points for a given top."""
    out: list[tuple[int, float]] = []
    for r in rows:
        if r.get("top") != top:
            continue
        n = _safe_float(r.get("N"))
        a = _safe_float(r.get("total_area_um2") or r.get("cell_area_um2"))
        if n is None or a is None:
            continue
        out.append((int(n), a))
    out.sort()
    return out


def fit_quadratic_plus_linear(points: list[tuple[int, float]]):
    """Fit area(N) = a + b*N^2 + c*N via least squares.

    Returns (params, predict_fn, residuals, r2).
    """
    if len(points) < 3:
        return None, None, None, None
    n_arr = np.array([p[0] for p in points], dtype=float)
    y = np.array([p[1] for p in points], dtype=float)
    # Design matrix: [1, N^2, N]
    X = np.column_stack([np.ones_like(n_arr), n_arr ** 2, n_arr])
    params, residuals, _, _ = np.linalg.lstsq(X, y, rcond=None)
    y_hat = X @ params
    ss_res = float(np.sum((y - y_hat) ** 2))
    ss_tot = float(np.sum((y - y.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 1.0

    def predict(n: float) -> float:
        return float(params[0] + params[1] * n * n + params[2] * n)

    return params, predict, y - y_hat, r2


def fit_confidence_band(points, params, n_query):
    """Crude 95% prediction band via residual standard error.

    Acceptable for the small-n regression we have (5-6 points).
    """
    n_arr = np.array([p[0] for p in points], dtype=float)
    y = np.array([p[1] for p in points], dtype=float)
    X = np.column_stack([np.ones_like(n_arr), n_arr ** 2, n_arr])
    y_hat = X @ params
    resid = y - y_hat
    dof = max(1, len(points) - 3)
    sigma = math.sqrt(float(np.sum(resid ** 2)) / dof)
    # 2-sigma band as ~95% CI (good-enough for the writeup)
    return sigma, 2.0 * sigma


def compute_glue(rows, n_values):
    """Glue area = stream_pipeline(N) - N^2 * per_PE_area(systolic at same N)
                   - fused_postproc_area
    """
    sys_by_n = {n: a for n, a in filter_by_top(rows, "systolic_array_64x64")}
    str_by_n = {n: a for n, a in filter_by_top(rows, "stream_pipeline")}
    fpp = next((float(r["total_area_um2"]) for r in rows
                if r.get("top") == "fused_postproc_unit"
                and _safe_float(r.get("total_area_um2")) is not None),
               None)
    glue = {}
    for n in n_values:
        if n in sys_by_n and n in str_by_n:
            stream_area = str_by_n[n]
            systolic_area = sys_by_n[n]
            g = stream_area - systolic_area
            if fpp is not None:
                g -= fpp
            glue[n] = g
    return glue, fpp


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", default="sweep_results.csv")
    ap.add_argument("--out-txt", default="sweep_metrics.txt")
    ap.add_argument("--out-pdf", default="sweep_figure.pdf")
    args = ap.parse_args()

    rows = load_csv(Path(args.csv))
    if not rows:
        print(f"ERROR: {args.csv} is empty")
        return 1

    lines: list[str] = []
    out = lines.append
    out(f"# M3 sweep analysis -- input: {args.csv}")
    out("")

    # -- Phase 1: systolic-only fit ---------------------------------------
    sys_pts = filter_by_top(rows, "systolic_array_64x64")
    out(f"## systolic_array_64x64 (n_points = {len(sys_pts)})")
    for n, a in sys_pts:
        per_pe = a / (n * n) if n > 0 else float("nan")
        out(f"  N={n:2d}  PEs={n * n:4d}  area={a:12.1f} um^2  per_PE={per_pe:8.2f}")

    sys_params, sys_predict, _, sys_r2 = fit_quadratic_plus_linear(sys_pts)
    if sys_params is not None:
        a0, b0, c0 = sys_params
        out("")
        out(f"  Fit: area(N) = {a0:.2f} + {b0:.4f}*N^2 + {c0:.2f}*N")
        out(f"       R^2   = {sys_r2:.4f}")
        sigma, band = fit_confidence_band(sys_pts, sys_params, 64)
        out(f"       Residual sigma = {sigma:.1f} um^2  (~95% band: +/-{band:.1f} um^2)")
        for n_q in (8, 16, 32, 64):
            pred = sys_predict(n_q)
            out(f"  Predict N={n_q:2d}: {pred:14.1f} um^2  ({pred / 1e6:.3f} mm^2)  +/- {band:.1f}")

    # -- Phase 3: stream_pipeline fit -------------------------------------
    str_pts = filter_by_top(rows, "stream_pipeline")
    out("")
    out(f"## stream_pipeline (n_points = {len(str_pts)})")
    for n, a in str_pts:
        out(f"  N={n:2d}  PEs={n * n:4d}  area={a:12.1f} um^2")

    str_params, str_predict, _, str_r2 = fit_quadratic_plus_linear(str_pts)
    if str_params is not None:
        a1, b1, c1 = str_params
        out("")
        out(f"  Fit: area(N) = {a1:.2f} + {b1:.4f}*N^2 + {c1:.2f}*N")
        out(f"       R^2   = {str_r2:.4f}")
        sigma_s, band_s = fit_confidence_band(str_pts, str_params, 64)
        out(f"       Residual sigma = {sigma_s:.1f} um^2  (~95% band: +/-{band_s:.1f})")
        for n_q in (8, 16, 32, 64):
            pred = str_predict(n_q)
            out(f"  Predict N={n_q:2d}: {pred:14.1f} um^2  ({pred / 1e6:.3f} mm^2)  +/- {band_s:.1f}")

    # -- Fusion-block roll-up ---------------------------------------------
    out("")
    out("## Fusion / control blocks (Phase 2)")
    blocks = ["gelu_unit", "gelu_grad_unit", "softmax_unit", "causal_mask_unit",
              "divider_or_reciprocal_unit", "adder_tree", "fused_postproc_unit",
              "accel_controller", "perf_counter_block",
              "tile_buffer"]  # both NRD variants will appear
    for r in rows:
        top = r.get("top")
        if top not in blocks:
            continue
        a = _safe_float(r.get("total_area_um2"))
        cells = r.get("cells", "NA")
        nrd = r.get("NUM_RD_PORTS", "1")
        suffix = f" (NRD={nrd})" if top == "tile_buffer" else ""
        if a is not None:
            out(f"  {top}{suffix:14s}: {a:12.1f} um^2  cells={cells}")
        else:
            out(f"  {top}{suffix:14s}: (no data)")

    # -- Glue residual ----------------------------------------------------
    glue, fpp_area = compute_glue(rows, [p[0] for p in str_pts])
    if glue:
        out("")
        out("## Stream_pipeline glue overhead")
        out("   glue(N) = stream(N) - systolic(N) - fused_postproc")
        if fpp_area is None:
            out("   (fused_postproc area not available -- glue is upper-bound)")
        for n, g in sorted(glue.items()):
            out(f"   N={n:2d}: glue = {g:12.1f} um^2")

    # -- Chip rollup ------------------------------------------------------
    if str_predict is not None:
        out("")
        out("## Chip-area extrapolation (back-of-envelope)")
        engine_core = str_predict(64)
        ctrl = next((float(r["total_area_um2"]) for r in rows
                     if r.get("top") == "accel_controller"
                     and _safe_float(r.get("total_area_um2")) is not None), 0.0)
        perf = next((float(r["total_area_um2"]) for r in rows
                     if r.get("top") == "perf_counter_block"
                     and _safe_float(r.get("total_area_um2")) is not None), 0.0)
        tb_small = next((float(r["total_area_um2"]) for r in rows
                         if r.get("top") == "tile_buffer"
                         and r.get("NUM_RD_PORTS") == "1"
                         and _safe_float(r.get("total_area_um2")) is not None), 0.0)
        tb_big = next((float(r["total_area_um2"]) for r in rows
                       if r.get("top") == "tile_buffer"
                       and r.get("NUM_RD_PORTS") == "64"
                       and _safe_float(r.get("total_area_um2")) is not None), 0.0)

        engine_base = engine_core + ctrl + perf + 3.0 * tb_small + tb_big
        for overhead in (1.15, 1.30):
            chip = 16.0 * engine_base * overhead
            out(f"   engine_core (stream_pipeline 64x64) = {engine_core:.1f} um^2")
            out(f"   + ctrl({ctrl:.0f}) + perf({perf:.0f}) "
                f"+ 3*tb_p1({tb_small:.0f}) + 1*tb_p64({tb_big:.0f})")
            out(f"   engine = {engine_base:.1f} um^2,  "
                f"chip = 16 x engine x {overhead:.2f} interconnect "
                f"= {16.0 * engine_base * overhead / 1e6:.2f} mm^2")
            out("")

    text = "\n".join(lines)
    Path(args.out_txt).write_text(text)
    print(text)
    print(f"\n>>> wrote {args.out_txt}")

    # -- Optional plot ----------------------------------------------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("(matplotlib not available -- skipping PDF plot)")
        return 0

    fig, ax = plt.subplots(figsize=(7, 5))
    if sys_pts:
        ns = np.array([p[0] for p in sys_pts])
        ys = np.array([p[1] for p in sys_pts])
        ax.scatter(ns ** 2, ys / 1e6, label="systolic measured", color="C0")
        if sys_predict is not None:
            xs = np.linspace(1, 64, 200)
            ax.plot(xs ** 2, np.array([sys_predict(x) for x in xs]) / 1e6,
                    color="C0", linestyle="--", label="systolic fit")
            sigma, band = fit_confidence_band(sys_pts, sys_params, 64)
            ax.fill_between(xs ** 2,
                            (np.array([sys_predict(x) for x in xs]) - band) / 1e6,
                            (np.array([sys_predict(x) for x in xs]) + band) / 1e6,
                            color="C0", alpha=0.15)
    if str_pts:
        ns = np.array([p[0] for p in str_pts])
        ys = np.array([p[1] for p in str_pts])
        ax.scatter(ns ** 2, ys / 1e6, label="stream_pipeline measured",
                   color="C1", marker="s")
        if str_predict is not None:
            xs = np.linspace(1, 64, 200)
            ax.plot(xs ** 2, np.array([str_predict(x) for x in xs]) / 1e6,
                    color="C1", linestyle="--", label="stream fit")

    ax.set_xlabel("PE count  N^2  ($1\\to 4096$)")
    ax.set_ylabel("Area  [mm^2]")
    ax.set_title("M3 sweep: area vs. PE count, fit + extrapolation to 64x64")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(args.out_pdf)
    print(f">>> wrote {args.out_pdf}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
