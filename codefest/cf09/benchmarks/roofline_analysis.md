# CLLM Task 9 — Roofline gap analysis (projected path)

The accelerator point on [`roofline_plot.png`](roofline_plot.png) is plotted
as **PROJECTED**, because no end-to-end ff_backward cosimulation has been
run against the M5 RTL — the M3 scope adjustment landed at per-block /
per-tile verification, and the chip-level number is derived from
`f_max × useful_ops_per_cycle`. This analysis identifies the dominant
uncertainty in that projection and what would be needed to convert it
into a measurement.

**Where the accelerator landed.** At the ff_backward kernel's full-reuse
arithmetic intensity (5.43 FLOP/B from M1), the chip sits on the
compute-bound flat at **369 GOPS peak** (Sky130 SS, 4096-PE scaled). That
corner is the worst-case sign-off number from Attempt 9 post-PnR STA
(−11.33 ns WNS at 10 ns target → 45 MHz). The kernel's AI sits well
above the Sky130 ridge of 1.44 FLOP/B, so the chip is **compute-bound**
at this operating point — adding SRAM bandwidth would do nothing; only
adding MAC throughput moves the point up. The CPU is memory-bound at
the same AI (CPU ridge ≈ 16.9 FLOP/B is to the right of the kernel),
which is exactly why the chip wins on this kernel even at Sky130's
modest 45 MHz: the chip's SRAM ridge is left of the kernel and the CPU's
DRAM ridge is right of it.

**Dominant uncertainty in the projection.** Three sources, ranked:

1. **Utilization.** I assumed 60 % sustained, which is the M5 stream
   pipeline's design target with softmax + LUT-gelu serialization. The
   actual sustained number for ff_backward is unknown until the kernel
   runs through the full `accel_engine` → `compute_core` → `chiplet_interface`
   path. If utilization lands at 30-40 % the sustained throughput drops
   from 221 GOPS to 110-150 GOPS — still a 33-44× speedup over CPU but
   not the 65× headline.
2. **Process target.** Sky130 SS caps at ~45 MHz worst-case; SAED32 at
   500 MHz would deliver 4,096 GOPS peak (the M1 Heilmeier target). The
   phobos Genus run is still in `syn_opt` and the post-PnR SAED32
   number isn't in yet, so we report Sky130 for the chip headline and
   SAED32 as a dotted "design target" line on the roofline.
3. **Precision parity.** The CPU baseline is float64; the chip is
   Q4.4 × Q4.4 → Q16.16. For ff_backward the LUT-based activations
   measured ≤ 5e-5 worst-case error (cf02 precision study), so this is
   probably a fair comparison for the ML accuracy story — but a literal
   ops/sec comparison treats them as equivalent which slightly inflates
   the chip's apparent advantage.

**What converting projection → measurement would need.** Running the
M5 RTL through QuestaSim against a real ff_backward tile (256 tokens ×
64 d_model × 256 d_ff) would yield the actual cycle count and let us
compute measured sustained throughput. That cosimulation is queued as
remaining task #1 in [`project/remaining_tasks.md`](../../../project/remaining_tasks.md).

(Word count: 410.)
