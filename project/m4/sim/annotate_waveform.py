"""
Annotate final_waveform.png with phase markers.

Adds vertical event lines + text labels above the waveform pane so the
five phases of the end-to-end tb_top macro are obvious at a glance.

Phase boundaries chosen by inspection of the source image:
  Phase 1 (host write A/B):       ~0     -> ~26,000 ns
  Phase 2 (macro issue + busy):   ~26,000 -> ~62,000 ns
  Phase 3 (irq assert = done):    ~62,000 ns
  Phase 4 (host read-back):       ~62,000 -> ~80,000 ns

Run from project/m4/sim/:
    python annotate_waveform.py
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SRC  = HERE / "final_waveform.png"
DST  = HERE / "final_waveform.png"

# Image is 1350x520. Waveform pane runs roughly from x=265 to x=1330 over
# a 0 to ~85,000 ns time range. Calibrated by matching the 20000-ns
# tick-mark positions visible at the bottom of the source image.
X_LEFT   = 265
X_RIGHT  = 1330
T_LEFT   = 0
T_RIGHT  = 85_000
PX_PER_NS = (X_RIGHT - X_LEFT) / (T_RIGHT - T_LEFT)


def t_to_x(t_ns):
    return int(X_LEFT + (t_ns - T_LEFT) * PX_PER_NS)


# (time_ns, label, color, vertical_anchor)
# vertical_anchor: 0 = above top group, 1 = above middle, 2 = above bottom
EVENTS = [
    (1_500,  "T0: rst_n deassert",                            (255, 200,   0), 0),
    (3_000,  "T1: host writes A tile (Q16.16, 4096 elems)",   (255, 100, 100), 0),
    (16_000, "T2: host writes B tile",                        (255, 100, 100), 0),
    (28_000, "T3: macro MODE_FFN_FWD issued",                 (255,   0,   0), 0),
    (30_000, "T4: chiplet busy -- systolic + GELU compute",   (  0, 200, 255), 0),
    (62_000, "T5: ucie_irq asserts (= done)",                 (  0, 255,   0), 0),
    (65_000, "T6: host reads back 16 output samples",         (255, 200,   0), 0),
]


def main():
    img = Image.open(SRC).convert("RGB")
    W, H = img.size
    print(f"source: {W}x{H}")

    # Make room above the waveform for annotation labels by extending the
    # canvas vertically with a black band on top.
    BAND_H = 110
    new = Image.new("RGB", (W, H + BAND_H), (0, 0, 0))
    new.paste(img, (0, BAND_H))
    draw = ImageDraw.Draw(new)

    # Try to load a TrueType font; fall back to default bitmap.
    try:
        font_label  = ImageFont.truetype("arial.ttf", 11)
        font_title  = ImageFont.truetype("arialbd.ttf", 14)
    except OSError:
        font_label  = ImageFont.load_default()
        font_title  = ImageFont.load_default()

    # Title
    draw.text((X_LEFT, 4), "tb_top -- end-to-end UCIe macro: host write -> cmd issue -> compute -> irq -> read-back",
              fill=(255, 255, 255), font=font_title)

    # For each event: draw a vertical dashed line spanning the whole
    # waveform pane and a label at the top.
    label_y_levels = [28, 48, 68, 88]
    used_level_until_x = [-9999] * len(label_y_levels)

    for t_ns, label, color, _anchor in EVENTS:
        x = t_to_x(t_ns)
        # Vertical line through both bands (label band + waveform)
        for y in range(BAND_H, H + BAND_H, 6):
            draw.line([(x, y), (x, y + 3)], fill=color, width=1)

        # Pick lowest y-level that doesn't collide with an in-use label
        for li, ly in enumerate(label_y_levels):
            if used_level_until_x[li] < x - 4:
                y_label = ly
                # Reserve this level up through label text end
                # text bbox width
                bbox = draw.textbbox((0, 0), label, font=font_label)
                lw   = bbox[2] - bbox[0]
                used_level_until_x[li] = x + lw + 10
                break
        else:
            y_label = label_y_levels[-1]

        # Tick mark on the label
        draw.line([(x, y_label - 4), (x, y_label + 4)], fill=color, width=2)
        # Label text
        draw.text((x + 6, y_label - 6), label, fill=color, font=font_label)

    new.save(DST, format="PNG", optimize=True)
    print(f"wrote {DST}")


if __name__ == "__main__":
    main()
