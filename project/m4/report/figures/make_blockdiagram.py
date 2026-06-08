"""
Generate fig3_blockdiagram.png and fig4_dataflow.png for the M4 report.

Both figures use matplotlib patches so they are reproducible and
do not depend on Graphviz or external diagramming tools.
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as patches


def box(ax, x, y, w, h, label, color="lightblue", fontsize=9, edgecolor="black"):
    rect = patches.FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.05,rounding_size=0.05",
        linewidth=1.2, edgecolor=edgecolor, facecolor=color
    )
    ax.add_patch(rect)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center", fontsize=fontsize, wrap=True)


def arrow(ax, x1, y1, x2, y2, label="", color="black", lw=1.2):
    ax.annotate(
        "", xy=(x2, y2), xytext=(x1, y1),
        arrowprops=dict(arrowstyle="->", color=color, lw=lw)
    )
    if label:
        ax.text((x1 + x2) / 2, (y1 + y2) / 2 + 0.08, label, ha="center", va="bottom", fontsize=7, color=color)


def block_diagram():
    # Natural canvas dimensions matched to fig4 (dataflow) so fitz.Story
    # treats both figures consistently and Figure 3 doesn't get squeezed
    # into leftover space on the previous page.
    fig, ax = plt.subplots(figsize=(11, 7))
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 9)
    ax.axis("off")

    # External host
    box(ax, 0.2, 4.0, 1.8, 1.0, "Host\n(UCIe link)", color="lightyellow")

    # Chiplet boundary
    chip = patches.FancyBboxPatch(
        (2.4, 0.3), 11.4, 8.4, boxstyle="round,pad=0.05,rounding_size=0.1",
        linewidth=1.8, edgecolor="navy", facecolor="aliceblue"
    )
    ax.add_patch(chip)
    ax.text(8.1, 8.4, "Accelerator chiplet (top.sv)", ha="center", fontsize=14, fontweight="bold", color="navy")

    # interface.sv
    box(ax, 2.8, 3.8, 1.8, 1.4, "interface.sv\n(UCIe term.\ncmd / wr / rd /\nirq / busy)", color="lightyellow", fontsize=11)

    # compute_core.sv
    box(ax, 5.2, 0.8, 8.2, 7.0, "", color="lavender", edgecolor="purple")
    ax.text(9.3, 7.4, "compute_core.sv  (16 lanes)", ha="center", fontsize=13, color="purple")

    # accel_controller
    box(ax, 5.4, 5.6, 2.5, 1.4, "accel_controller\n(macro FSM,\ntile sequencer)", color="lightcoral", fontsize=11)

    # tile_dispatcher
    box(ax, 5.4, 3.4, 2.5, 1.4, "tile_dispatcher\n(round-robin\nlanes 0..15)", color="lightcoral", fontsize=11)

    # accel_engine x N
    box(ax, 8.4, 5.4, 2.6, 1.6, "accel_engine[i]\n+ stream_pipeline\n(per lane)", color="lightgreen", fontsize=11)

    # systolic
    box(ax, 11.2, 5.4, 2.4, 1.6, "systolic_array\n64x64 PEs\noutput-stationary", color="orange", fontsize=11)

    # postproc
    box(ax, 8.4, 3.0, 2.6, 1.6, "stream_pipeline\nmatmul -> GELU\n-> softmax", color="lightgreen", fontsize=11)

    # fused postproc
    box(ax, 11.2, 3.0, 2.4, 1.6, "fused_postproc\n(GELU' / dy*GELU')", color="orange", fontsize=11)

    # scratchpad
    box(ax, 5.4, 0.9, 2.5, 1.6, "scratchpad\n(sram_bank,\nscratchpad_ctrl,\ndma_engine)", color="lightcyan", fontsize=11)

    # tile loader/writer/buffer
    box(ax, 8.4, 0.9, 2.6, 1.6, "tile_loader\ntile_buffer\ntile_writer", color="lightcyan", fontsize=11)

    # double buffer / address gen
    box(ax, 11.2, 0.9, 2.4, 1.6, "double_buffer_ctrl\naddress_gen", color="lightcyan", fontsize=11)

    # Arrows
    arrow(ax, 2.0, 4.5, 2.8, 4.5)  # host -> interface
    arrow(ax, 4.6, 4.6, 5.4, 6.0)  # interface -> ctrl
    arrow(ax, 4.6, 4.4, 5.4, 4.0)  # interface -> dispatcher
    arrow(ax, 7.9, 6.3, 8.4, 6.0)  # ctrl -> engine
    arrow(ax, 7.9, 4.1, 8.4, 4.0)  # dispatcher -> postproc

    arrow(ax, 11.0, 6.2, 11.2, 6.2)  # engine -> systolic
    arrow(ax, 11.0, 3.8, 11.2, 3.8)  # postproc -> fused

    arrow(ax, 8.4, 5.5, 7.9, 4.7)  # engine -> dispatcher (feedback)
    arrow(ax, 6.6, 2.5, 6.6, 3.4)  # scratchpad -> dispatcher
    arrow(ax, 9.7, 2.5, 8.4, 3.0, color="gray")  # loader -> stream_pipeline

    ax.text(7, 0.05, "Solid arrows = control flow; data tiles flow scratchpad -> tile_loader -> tile_buffer -> systolic -> tile_writer -> scratchpad", ha="center", fontsize=11, style="italic", color="gray")

    plt.title("Figure 3 - M4 Accelerator Block Diagram", fontsize=12)
    plt.tight_layout()
    plt.savefig("fig3_blockdiagram.png", dpi=140)
    plt.close()
    print("wrote fig3_blockdiagram.png")


def dataflow_diagram():
    # Taller canvas so the B-column labels at top, the array, and the
    # output arrows at bottom each get their own vertical band without
    # overlapping (was a real problem at figsize=(11, 6.5)).
    fig, ax = plt.subplots(figsize=(11, 7.5))
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 9)
    ax.axis("off")

    ax.text(7, 8.6, "Figure 4 - Output-stationary systolic dataflow (FFN forward, K reduction)", ha="center", fontsize=12, fontweight="bold")
    # "Showing N of M" caption -- placed BELOW the title so it does not
    # collide with the B-from-north arrows (which previously cut through
    # the caption text).
    ax.text(7, 8.25, "(showing 4x4 of 64x64 array)", ha="center", fontsize=10, style="italic", color="gray")

    # Draw a 4x4 PE array (representing the 64x64)
    cell_w = 1.0
    cell_h = 0.9
    base_x = 4.5
    base_y = 2.0

    for r in range(4):
        for c in range(4):
            x = base_x + c * cell_w
            y = base_y + r * cell_h
            rect = patches.Rectangle((x, y), cell_w, cell_h, linewidth=1.0, edgecolor="black", facecolor="lightyellow")
            ax.add_patch(rect)
            ax.text(x + cell_w / 2, y + cell_h / 2 + 0.18, f"PE[{r},{c}]", ha="center", va="center", fontsize=7)
            ax.text(x + cell_w / 2, y + cell_h / 2 - 0.18, "acc+=a*b", ha="center", va="center", fontsize=6, color="darkred")

    # A from west: arrows + label on left side of the array
    for r in range(4):
        y_arrow = base_y + r * cell_h + cell_h / 2
        arrow(ax, base_x - 1.5, y_arrow, base_x, y_arrow, color="blue")
    ax.text(base_x - 1.7, base_y + 2 * cell_h, "A row[i]\n(Q4.4)\nW->E", ha="right", va="center", fontsize=9, color="blue")

    # B from north: arrows enter the TOP edge of the array. Label sits
    # ABOVE the arrows in its own clear vertical band (y >= 7.4) so the
    # "showing N of M" caption at y=8.25 still has a half-line of gap.
    array_top = base_y + 4 * cell_h           # = 5.6
    b_arrow_top = array_top + 0.8             # = 6.4
    for c in range(4):
        x_arrow = base_x + c * cell_w + cell_w / 2
        arrow(ax, x_arrow, b_arrow_top, x_arrow, array_top, color="green")
    ax.text(base_x + 2 * cell_w, b_arrow_top + 0.4, "B col[j]   (Q4.4)   N->S", ha="center", va="bottom", fontsize=10, color="green", fontweight="bold")

    # Output drain south
    for c in range(4):
        x_arrow = base_x + c * cell_w + cell_w / 2
        arrow(ax, x_arrow, base_y, x_arrow, base_y - 0.7, color="red")
    ax.text(base_x + 2 * cell_w, base_y - 0.9, "Output tile  (Q16.16, drained after K reductions, written to tile_writer)",
            ha="center", va="top", fontsize=9, color="red")

    # Timing annotation on the right -- vertically aligned with the
    # array's mid-rows so it reads as a 64-cycle K-reduction timeline.
    ax.text(base_x + 4 * cell_w + 1.0, base_y + 3 * cell_h, "Fill: 64 cyc", fontsize=9)
    ax.text(base_x + 4 * cell_w + 1.0, base_y + 2 * cell_h, "Compute: K = 64 cyc", fontsize=9)
    ax.text(base_x + 4 * cell_w + 1.0, base_y + 1 * cell_h, "Drain: 64 cyc", fontsize=9)
    ax.text(base_x + 4 * cell_w + 1.0, base_y + 0 * cell_h - 0.1, "Per-tile compute window = 192 cyc", fontsize=9, fontweight="bold")

    plt.tight_layout()
    plt.savefig("fig4_dataflow.png", dpi=140)
    plt.close()
    print("wrote fig4_dataflow.png")


if __name__ == "__main__":
    block_diagram()
    dataflow_diagram()
