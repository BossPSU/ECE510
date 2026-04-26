"""
Generate Q16.16 fixed-point LUT .mem files for synthesizable RTL.

Outputs:
  gelu_tanh_lut.mem  — 256 entries of tanh(x) for x in [-4, +4]
  exp_lut.mem        — 256 entries of exp(x) for x in [-8, 0]

Format: hex value per line, suitable for $readmemh.
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
    print(f"Wrote gelu_tanh_lut.mem  ({depth} entries, range [{x_min}, {x_max}])")


def gen_exp_lut(depth=256, x_min=-8.0, x_max=0.0):
    with open("exp_lut.mem", "w") as f:
        for i in range(depth):
            x = x_min + (x_max - x_min) * i / (depth - 1)
            f.write(to_q16_16(math.exp(x)) + "\n")
    print(f"Wrote exp_lut.mem        ({depth} entries, range [{x_min}, {x_max}])")


if __name__ == "__main__":
    gen_tanh_lut()
    gen_exp_lut()
