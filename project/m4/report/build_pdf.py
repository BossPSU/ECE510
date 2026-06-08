"""
Build design_justification.pdf from design_justification.md using markdown-pdf.

Inserts inline references to the four figures at the end. Image paths MUST
be RELATIVE to `Section(root=...)` -- fitz.Story uses root as the archive
for image lookup, and absolute Windows paths don't resolve there.
"""

from pathlib import Path
from markdown_pdf import MarkdownPdf, Section


HERE = Path(__file__).resolve().parent
MD   = HERE / "design_justification.md"
PDF  = HERE / "design_justification.pdf"


def main():
    md_text = MD.read_text(encoding="utf-8")

    # Append all four figures under a single "## Figures" heading. To keep
    # Figure 3 from being squeezed into leftover space at the bottom of the
    # Figure-1+2 page, insert invisible vertical padding (a stack of empty
    # &nbsp; paragraphs) between Figure 2 and Figure 3. That forces fitz's
    # layout engine to overflow to the next page rather than crushing
    # Figure 3's rendered scale.
    md_text += "\n\n---\n\n## Figures\n\n"
    md_text += "**Figure 1** -- Roofline (§2, §8).\n\n"
    md_text += "![](figures/fig1_roofline.png)\n\n"

    md_text += "**Figure 2** -- End-to-end UCIe waveform (§6).\n\n"
    md_text += "![](figures/fig2_waveform.png)\n\n"

    md_text += "**Figure 3** -- Chip block diagram (§4).\n\n"
    md_text += "![](figures/fig3_blockdiagram.png)\n\n"

    md_text += "**Figure 4** -- Systolic dataflow (§4).\n\n"
    md_text += "![](figures/fig4_dataflow.png)\n\n"

    pdf = MarkdownPdf(toc_level=2)
    pdf.add_section(Section(md_text, root=str(HERE)))
    pdf.meta["title"] = "M4 Design Justification - ECE 510 Spring 2026"
    pdf.meta["author"] = "David Boss"
    pdf.save(str(PDF))
    print(f"wrote {PDF} ({PDF.stat().st_size / 1024:.1f} KiB) -- preliminary")

    # markdown-pdf stores embedded PNGs as RAW RGB (no deflate filter), which
    # bloats the file ~30x. Re-open with PyMuPDF and save with deflate enabled
    # to compress them down to their original PNG sizes.
    import fitz
    tmp = PDF.with_suffix(".tmp.pdf")
    doc = fitz.open(str(PDF))
    doc.save(
        str(tmp),
        garbage=4,             # remove orphan objects, merge duplicates
        deflate=True,          # compress all uncompressed streams
        deflate_images=True,   # compress image streams specifically
        deflate_fonts=True,
        clean=True,
    )
    doc.close()
    tmp.replace(PDF)
    print(f"final  {PDF} ({PDF.stat().st_size / 1024:.1f} KiB) -- deflated")


if __name__ == "__main__":
    main()
