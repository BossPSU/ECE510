"""
Generate Q16.16 fixed-point LUT .mem files for synthesizable RTL.

Outputs:
  gelu_tanh_lut.mem        — 256 entries of tanh(x) for x in [-4, +4]
  exp_lut.mem              — 256 entries of exp(x) for x in [-8, 0]
  gelu_lut_direct.mem      — 256 entries of GELU(x)  for x in [-4, +4) (M4)
  gelu_grad_lut_direct.mem — 256 entries of GELU'(x) for x in [-4, +4) (M4)

Format: hex value per line, suitable for $readmemh.

LUT-stride conventions
----------------------
The two pre-M4 LUTs (gelu_tanh_lut, exp_lut) use a closed-interval grid:
  entry[i] = f(x_min + (x_max - x_min) * i / (depth - 1))
  step h   = (x_max - x_min) / (depth - 1)   (= 8/255 ~= 0.03137 for 256 entries)
This places entry[0]   = f(x_min) and entry[depth-1] = f(x_max) exactly.

The two new M4 LUTs (gelu_lut_direct, gelu_grad_lut_direct) use a
half-open-interval grid:
  entry[i] = f(x_min + (x_max - x_min) * i / depth)
  step h   = (x_max - x_min) / depth         (= 8/256 = 0.03125 for 256 entries)
This is a power-of-two stride, so address generation collapses to a
single shift (`shifted_q16 >> 11` for the 8-bit address, low 11 bits as
the linear-interpolation fraction). The cost is that entry[depth-1] =
f(x_max - h) instead of f(x_max); the gelu_unit_lut wrapper handles the
final-bin saturation explicitly.
"""

import math


def to_q16_16(val):
    """Convert float to Q16.16 signed 32-bit hex string."""
    fixed = int(round(val * (1 << 16)))
    # Clamp to signed 32-bit range
    if fixed > 0x7FFFFFFF:
        fixed = 0x7FFFFFFF
    elif fixed < -0x80000000:
        fixed = -0x80000000
    # Convert to unsigned 32-bit for hex
    if fixed < 0:
        fixed += 1 << 32
    return f"{fixed:08X}"


def gen_tanh_lut(depth=256, x_min=-4.0, x_max=4.0):
    with open("gelu_tanh_lut.mem", "w") as f:
        for i in range(depth):
            x = x_min + (x_max - x_min) * i / (depth - 1)
            f.write(to_q16_16(math.tanh(x)) + "\n")
    print(f"Wrote gelu_tanh_lut.mem        ({depth} entries, range [{x_min}, {x_max}])")


def gen_exp_lut(depth=256, x_min=-8.0, x_max=0.0):
    with open("exp_lut.mem", "w") as f:
        for i in range(depth):
            x = x_min + (x_max - x_min) * i / (depth - 1)
            f.write(to_q16_16(math.exp(x)) + "\n")
    print(f"Wrote exp_lut.mem              ({depth} entries, range [{x_min}, {x_max}])")


def _gelu(x):
    """Exact GELU via the erf form: GELU(x) = x * 0.5 * (1 + erf(x / sqrt(2)))."""
    return x * 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def _gelu_grad(x):
    """Exact GELU derivative: Phi(x) + x * phi(x)."""
    phi_cdf = 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))
    phi_pdf = math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)
    return phi_cdf + x * phi_pdf


def gen_gelu_direct_lut(depth=256, x_min=-4.0, x_max=4.0, suffix=""):
    """Direct GELU LUT, half-open grid -- entry[i] = GELU(x_min + i*h).

    suffix lets the caller emit per-depth files (gelu_lut_direct_128.mem etc).
    suffix="" preserves the canonical name used by the v_hand modules.
    """
    h = (x_max - x_min) / depth
    fname = f"gelu_lut_direct{suffix}.mem"
    with open(fname, "w") as f:
        for i in range(depth):
            x = x_min + i * h
            f.write(to_q16_16(_gelu(x)) + "\n")
    print(f"Wrote {fname:<32s} ({depth} entries, range [{x_min}, {x_max}), step {h:.5f})")


def gen_gelu_grad_direct_lut(depth=256, x_min=-4.0, x_max=4.0, suffix=""):
    """Direct GELU-derivative LUT, half-open grid -- entry[i] = GELU'(x_min + i*h)."""
    h = (x_max - x_min) / depth
    fname = f"gelu_grad_lut_direct{suffix}.mem"
    with open(fname, "w") as f:
        for i in range(depth):
            x = x_min + i * h
            f.write(to_q16_16(_gelu_grad(x)) + "\n")
    print(f"Wrote {fname:<32s} ({depth} entries, range [{x_min}, {x_max}), step {h:.5f})")


def _measure_lut_precision(true_fn, depth, x_min=-4.0, x_max=4.0,
                           samples=10001, sat_value_fn=None):
    """Measure worst-case absolute error of a (depth)-entry direct LUT with
    linear interpolation, when sampled at `samples` evenly-spaced points
    across [x_min, x_max).

    Mirrors the RTL math: clamp x to [x_min, x_max - 1 Q16.16 LSB],
    convert to Q16.16, address gen via top bits of (x - x_min) scaled to
    span [0, depth), linear-interpolate adjacent entries using a Q16.16
    fractional weight, and quantize the result back to Q16.16. Then
    compares to true f(x).

    If sat_value_fn is provided, the simulation applies the RTL
    saturation: for x in [x_max - h, x_max), use sat_value_fn(x) instead
    of the LUT result. This eliminates the boundary dead zone in the
    last entry's interval. Returns (worst_err, worst_x) over the full
    sample range INCLUDING the saturation tail.
    """
    h = (x_max - x_min) / depth
    # Build LUT in Q16.16 (matching the .mem contents exactly)
    lut_q16 = []
    for i in range(depth):
        x_i = x_min + i * h
        v = true_fn(x_i)
        q = int(round(v * (1 << 16)))
        if q > 0x7FFFFFFF:
            q = 0x7FFFFFFF
        elif q < -0x80000000:
            q = -0x80000000
        lut_q16.append(q)

    addr_bits = max(1, int(math.log2(depth)))
    # frac_bits = Q16.16 fractional bits below the entry stride.
    # For depth=256, addr_bits=8, frac is the next 11 bits ( << 5 to scale to 1.0 )
    # For depth=128, addr_bits=7, frac is next 12 bits ( << 4 )
    # For depth=64,  addr_bits=6, frac is next 13 bits ( << 3 )
    # Generic: total bits below x_min in (x-x_min)*scale that map to one
    # LUT entry: (16 - log2(depth/8))  -- because (x-x_min) in Q16.16 has
    # 16 fractional bits, and the entry stride is 8/depth.
    # Concretely, shift = 16 - addr_bits + 3   (since width(x_max-x_min)=3 bits).
    shift_to_addr = 19 - addr_bits  # >> shift_to_addr gives 8-bit addr at depth=256
    frac_width = shift_to_addr       # = 11 / 12 / 13 for depth 256/128/64

    worst_err = 0.0
    worst_x = None
    for i in range(samples):
        x = x_min + (x_max - x_min) * i / (samples - 1)
        # Clamp to [x_min, x_max - 1 LSB]
        if x >= x_max:
            x = x_max - 1.0 / (1 << 16)
        if x < x_min:
            x = x_min
        shifted_q16 = int(round((x - x_min) * (1 << 16)))
        # Cap at 0x80000 - 1 to keep addr_lo < depth
        if shifted_q16 >= 0x80000:
            shifted_q16 = 0x7FFFF
        addr_lo = shifted_q16 >> shift_to_addr
        addr_hi = min(addr_lo + 1, depth - 1)
        # Fractional position scaled to Q16.16 (so 1.0 == 0x10000):
        # frac_q16 = (low frac_width bits of shifted_q16) << (16 - frac_width)
        low_mask = (1 << frac_width) - 1
        frac_q16 = (shifted_q16 & low_mask) << (16 - frac_width)
        # Linear interp in Q16.16: result = lo + ((hi - lo) * frac) >> 16
        lo = lut_q16[addr_lo]
        hi = lut_q16[addr_hi]
        diff = hi - lo
        # Signed product, truncated like the RTL q_mul (>> 16, drop low 16)
        # In RTL we use product[47:16]; equivalent to (diff*frac) >> 16 for
        # 32-bit signed inputs that don't overflow the 64-bit product.
        delta = (diff * frac_q16) >> 16
        interp_q16 = lo + delta
        interp = interp_q16 / 65536.0
        # Saturation override at the upper tail (matches a hypothetical
        # RTL fix where sat_pos triggers at x > x_max - h instead of x > x_max).
        if sat_value_fn is not None and x >= x_max - h:
            interp = sat_value_fn(x)
        true_val = true_fn(x)
        err = abs(interp - true_val)
        if err > worst_err:
            worst_err = err
            worst_x = x
    return worst_err, worst_x


def precision_report(depths=(64, 128, 256)):
    """Tabulate worst-case linear-interpolation error vs LUT depth, for
    both the GELU and GELU' LUTs.

    Two measurements per depth:
      - Bare LUT (no saturation override): shows the natural dead-zone
        error in [x_max - h, x_max), which equals roughly h * f'(x_max).
        This is what the CURRENT RTL produces if Q_FOUR is the saturation
        threshold (the LUT doesn't cover the last stride h).
      - LUT + saturation override at x_max - h: applies the RTL's
        sat_value_fn beyond the last LUT entry. This is the precision
        the LUT achieves on the genuine interpolation interior, and is
        the design target if the RTL is fixed to widen the saturation
        threshold (a 1-line change).
    """
    print()
    print("=" * 88)
    print(" LUT precision study -- linear interpolation, range [-4, +4)")
    print("=" * 88)
    Q16_LSB = 1.0 / 65536.0
    print(f" Q16.16 LSB = {Q16_LSB:.7f}  (={Q16_LSB*1e6:.2f} ppm of 1.0)")
    print()
    # Saturation override functions: match the RTL behavior past the LUT range.
    #   GELU(x)  -> x  for x >> 0
    #   GELU'(x) -> 1  for x >> 0
    sat_gelu      = lambda x: x
    sat_gelu_grad = lambda x: 1.0
    hdr = f"  {'depth':>5s}  {'h':>9s}  {'rom_bits':>9s}  {'fn':<6s}  "
    hdr += f"{'bare worst':>13s}  {'/ LSB':>8s}  {'fixed worst':>13s}  {'/ LSB':>8s}"
    print(hdr)
    for d in depths:
        h = 8.0 / d
        bits = d * 32
        err_g_bare,  _ = _measure_lut_precision(_gelu, d)
        err_g_fix,   _ = _measure_lut_precision(_gelu, d, sat_value_fn=sat_gelu)
        err_gg_bare, _ = _measure_lut_precision(_gelu_grad, d)
        err_gg_fix,  _ = _measure_lut_precision(_gelu_grad, d, sat_value_fn=sat_gelu_grad)
        print(f"  {d:5d}  {h:9.5f}  {bits:9d}  GELU    "
              f"{err_g_bare:13.2e}  {err_g_bare/Q16_LSB:8.1f}  "
              f"{err_g_fix:13.2e}  {err_g_fix/Q16_LSB:8.1f}")
        print(f"  {d:5d}  {h:9.5f}  {bits:9d}  GELU'   "
              f"{err_gg_bare:13.2e}  {err_gg_bare/Q16_LSB:8.1f}  "
              f"{err_gg_fix:13.2e}  {err_gg_fix/Q16_LSB:8.1f}")
    print()
    print(" 'bare worst'  = no saturation override past LUT range (current RTL)")
    print(" 'fixed worst' = saturation override at x_max - h (1-line RTL fix)")
    print()


if __name__ == "__main__":
    gen_tanh_lut()
    gen_exp_lut()
    # Canonical 256-entry direct LUTs (consumed by gelu_unit_lut.v / .sv).
    gen_gelu_direct_lut(depth=256)
    gen_gelu_grad_direct_lut(depth=256)
    # Smaller-depth variants for the size/precision study.
    for d in (64, 128):
        gen_gelu_direct_lut(depth=d, suffix=f"_{d}")
        gen_gelu_grad_direct_lut(depth=d, suffix=f"_{d}")
    precision_report()
