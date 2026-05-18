# CF07 — M3 Plan

**Stack.** `mac_pe` is the leaf. `systolic_array_64x64` adds
**4,096 MACs/cycle** per array (output-stationary, no intermediate
SRAM). `stream_pipeline` fuses matmul with activation so
intermediates never materialize; `tile_buffer` keeps tiles
register-resident; `softmax_unit` and `fused_postproc_unit` pipeline
attention/FFN nonlinearities. Sixteen lanes in `compute_core` run
**65,536 MACs/cycle**.

**Tool limits.** OpenLane on Sky130 chokes past ~50 K cells;
multi-million-cell designs take days or OOM the WSL VM. Genus on
phobos handles leaves cleanly but the flat top-level netlist OOMs
the 64 GB box.

**RTL change.** Pipeline `mac_pe` between multiply and align to close
the **−4.499 ns SS-corner gap** without a 31 % derate; +1 MAC cycle,
amortized in the systolic feed.

**Proof point.** Synthesize `systolic_array_64x64` at **N=4
(16 PEs, ~25 K cells extrapolated from `mac_pe`'s 1,482)** in
OpenLane — within tool limits, directly comparable to phobos's
`sys_4x4` Genus point. Combine with the Genus sweep N ∈ {1…32} and
an `area(N) = a + b·N² + c·N` fit to extrapolate full-chip area
without synthesizing the chip.
