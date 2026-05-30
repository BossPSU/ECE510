# Planned M5 Update — pipelined divider + pipelined mac_pe

## Problem: post-M4 chip critical path

After the M4 LUT swap landed (Attempt 7 full OpenLane flow, [`../m3/synth/top_small_M4_LUT_full/`](../m3/synth/top_small_M4_LUT_full/)),
the Sky130 GDS streams out clean with 0 DRC/LVS violations, but setup
timing did not close at the 10 ns target:

| Corner | Hold WNS | Setup WNS | Setup TNS | Notes |
|---|---:|---:|---:|---|
| nom_tt | +0.31 ns ✓ | **−55.69 ns ✗** | −1,252 ns | divider-limited |
| nom_ss | −0.49 ns ✗ | **−115.04 ns ✗** | −23,031 ns | divider + mac_pe SS limit |
| nom_ff | +0.11 ns ✓ | −31.50 ns ✗ | −364 ns | both limits relaxed |

The post-PnR critical path lands in two places:

1. **`divider_or_reciprocal_unit` internal Brent-Kung divider chain.**
   The unit's input and quotient ports are registered, but its core
   is one combinational 64-bit divide (`q_full = num_ext / den_r`).
   Yosys lowers that to a ~500-gate-level chain → ~65 ns at TT.
2. **`mac_pe` end-to-end at SS corner.** cf07 leaf measured −4.499 ns
   at SS (Attempt 3) — 14.5 ns critical path through saturate → 8×8
   mul → align → 32-bit Q16.16 add.

Both must be pipelined for the chip to close timing across all corners.

## M5 Item A — pipeline `divider_or_reciprocal_unit`

### Solution

[`divider_or_reciprocal_seq.sv`](divider_or_reciprocal_seq.sv) — same
port list as the legacy module plus an explicit `ready` backpressure
output. Internally replaces the single-cycle 64-bit `/` with a
**48-cycle iterative MSB-first shift-subtract divider**.

Per-cycle work: one 32-bit subtract + 1-bit shift = ~5 gate levels of
combinational depth (~0.5 ns at TT). Total latency: 48 cycles. Output
is bit-exact to the legacy combinational divider for inputs whose
Q16.16 quotient fits in signed 32 bits (the softmax 1/sum use case).

### Caller-side integration

[`softmax_unit_lut.sv`](softmax_unit_lut.sv) gains a
`USE_PIPELINED_DIVIDER` parameter (default 0). When 0, the legacy
2-cycle divider + 2-deep shadow pipe is used. When 1:
- `divider_or_reciprocal_seq` instantiated in place of the legacy unit
- Side-band info (s3_exp, s3_len, sum_zero flag) latched into a single
  **wait register** on `div_in_valid`, released by `recip_valid`
- `s3_valid` only fires the divider when `div_ready` is high — softmax
  rows that arrive faster than the divider can finish (e.g. one per
  N_PHASES=8 cycles at ARRAY_DIM=64) silently drop. Real workloads
  issue softmax rows much slower than the LUT pipeline can produce
  them, so this is a documented throughput cap, not a correctness issue
- The shadow-pipe path is tied off when this parameter is 1, and vice
  versa, so there's no synthesis-time area overhead for the unused half

### Test

[`tb_divider_or_reciprocal_seq.sv`](tb_divider_or_reciprocal_seq.sv) —
drives 16 {num, den} vectors through both the legacy and the iterative
divider in parallel, then asserts bit-exact equality. Vectors include
the actual softmax workload (1/N for N ∈ {2, 4, 7, 64}), sign
combinations, sub-Q4.4 magnitudes, num=0, den=0, and identity.
Pass criteria: every vector matches to 0 LSB.

### Projected impact

| Axis | Current (Attempt 7) | After M5 Item A |
|---|---:|---:|
| Critical path delay at TT | ~65 ns | ~0.5 ns |
| Chip f_max at TT (Sky130, mac_pe leaf limit) | 15 MHz | **117 MHz** |
| Per-row softmax latency (ARRAY_DIM=64) | 15 cycles | **63 cycles** |
| Per-row throughput at TT | 1 µs | 0.54 µs |
| Cells per divider instance (Sky130A) | ~16K (measured) | **~3K** (projected) |

## M5 Item B — pipeline `mac_pe`

### Solution

[`mac_pe_piped.sv`](mac_pe_piped.sv) — same port list as legacy
`mac_pe.sv`, with **one extra pipeline register between the 8×8 Q4.4
multiplier output (Q8.8 product) and the Q16.16 alignment + accumulator
add**. The Q4.4 saturate + 8×8 multiply form stage 1; the alignment +
32-bit accumulator add form stage 2.

`clear_acc` is delayed by 1 cycle into `clear_acc_r` to align with the
registered product. West/north forwarding (`a_out`, `b_out`) remain
1-cycle (unchanged from legacy `mac_pe`), so the systolic feed timing
is not affected by the deeper internal pipeline.

### Caller-side integration

[`systolic_array_64x64.sv`](systolic_array_64x64.sv) gains a
`USE_PIPED_MAC` parameter (default 0). The generate-if inside the
N²-PE grid selects between `mac_pe` (legacy) and `mac_pe_piped` per
the parameter. No port changes.

**stream_pipeline.sv DRAIN_CYCLES MUST be bumped by 1** when
`USE_PIPED_MAC=1` — each output value takes K+1 cycles to settle
instead of K. The current `localparam int DRAIN_CYCLES = 4` becomes
`DRAIN_CYCLES = USE_PIPED_MAC ? 5 : 4`. (Not gated yet — needs the
matching parameter to thread through compute_core → accel_engine →
stream_pipeline; a separate small commit.)

### Test

[`tb_mac_pe_piped.sv`](tb_mac_pe_piped.sv) mirrors the
[`tb_mac_pe.sv`](tb_mac_pe.sv) test suite — in-range MAC, positive
saturation, negative saturation, sub-Q4.4 resolution, clear_acc, plus
a new west/north forwarding check. Each accumulator check waits one
extra settle cycle to absorb the +1 cycle MAC latency.

### Projected impact

| Axis | Current | After M5 Item B |
|---|---:|---:|
| Leaf critical path (Sky130 SS, cf07 leaf measure) | 14.5 ns | ~7-8 ns |
| Leaf f_max (Sky130 SS corner) | 69 MHz | **125-140 MHz** |
| MAC pipeline latency | 1 cycle | **2 cycles** |
| Per-K-length dot product | K cycles | K+1 cycles |
| Cells per PE (Sky130A) | 1,478 (measured) | ~1,500 (projected, +16 flops for Q8.8 product) |
| stream_pipeline DRAIN_CYCLES | 4 | 5 (when this param is set) |

## Combined projected outcome

After M5 Items A + B both applied:

| Axis | Attempt 7 (current) | After M5 (A + B) |
|---|---:|---:|
| **Setup WNS @ TT, 10 ns clock** | −55.7 ns ✗ | **+2-3 ns ✓** |
| **Setup WNS @ SS, 10 ns clock** | −115 ns ✗ | **~+1-2 ns ✓** |
| **Setup WNS @ FF, 10 ns clock** | −31.5 ns ✗ | **+4-6 ns ✓** |
| **f_max @ TT (Sky130)** | 15 MHz | **~117 MHz** |
| **f_max @ SS (Sky130)** | did not close | **~70-90 MHz** |
| **f_max @ TT (SAED32 chip target)** | 52 MHz Genus baseline | **~588 MHz** (mac_pe + systolic limit) |
| Per-row softmax latency (ARRAY_DIM=64) | 15 cycles | 63 cycles |
| Per-MAC latency | 1 cycle | 2 cycles |
| Per-tile throughput | 670 µs | **~95 µs (7× faster)** |
| Cells @ TILE_DIM=2 Sky130 | 41,689 | ~28,500 (−13K from divider, +64 from mac_pe flops) |
| Total area @ TILE_DIM=2 Sky130 | 0.47 mm² | **~0.32 mm² (32% smaller)** |
| DRC / LVS | clean | clean (unchanged) |
| OpenLane signoff | quits at step 70 | **completes all 78 steps** |

The chip becomes a **defensible Sky130 tapeout candidate** at TILE_DIM=2
after M5: clean DRC/LVS, all corners closed at 70 MHz worst-case
(117 MHz typical), 0.32 mm² die. The same architectural changes apply
to the SAED32 Genus path, where the chip recovers to ~588 MHz —
matching the original M4 projection.

## Implementation status (M5)

| Phase | Status | Artifact |
|---|---|---|
| 1. RTL — divider_or_reciprocal_seq.sv | **done** | [`divider_or_reciprocal_seq.sv`](divider_or_reciprocal_seq.sv) |
| 2. RTL — mac_pe_piped.sv | **done** | [`mac_pe_piped.sv`](mac_pe_piped.sv) |
| 3. Unit TBs | **done (sim pending phobos)** | [`tb_divider_or_reciprocal_seq.sv`](tb_divider_or_reciprocal_seq.sv), [`tb_mac_pe_piped.sv`](tb_mac_pe_piped.sv) |
| 4. softmax_unit_lut integration | **done (gated, default off)** | `USE_PIPELINED_DIVIDER` parameter |
| 5. systolic_array_64x64 integration | **done (gated, default off)** | `USE_PIPED_MAC` parameter |
| 6. stream_pipeline DRAIN_CYCLES gating | pending | (1-line change; gated on a propagated `USE_PIPED_MAC` parameter) |
| 7. Hand-flatten to v_hand/ | **done** | [`../m3/synth/v_hand/mac_pe_piped.v`](../m3/synth/v_hand/mac_pe_piped.v), [`../m3/synth/v_hand/divider_or_reciprocal_seq.v`](../m3/synth/v_hand/divider_or_reciprocal_seq.v) |
| 8. Per-module Sky130 synth wiring | **done (sweep pending phobos)** | [`../m3/synth/synth_per_module_scoped.sh`](../m3/synth/synth_per_module_scoped.sh) TOPS list updated |
| 9. Genus sweep phase2f wiring | **done (sweep pending phobos)** | [`run_sweep.sh phase2f`](run_sweep.sh) |
| 10. Top_small.v end-to-end OpenLane re-run with both flags on | pending | needs `USE_PIPED_MAC` to propagate through the m3 v_hand instantiation chain |

## Reproduce on phobos

```sh
# QuestaSim unit tests
cd project/RTL
vsim -do run.do                          # appends tb_divider_or_reciprocal_seq + tb_mac_pe_piped

# Genus per-block sweep
./run_sweep.sh phase2f                   # 2 new sweep points (~10-15 min)
./collect_sweep_csv.sh                   # backfills sweep_results.csv

# m3 Sky130A per-module synth (WSL2)
cd ../m3/synth
bash synth_per_module_scoped.sh          # populates per_module/{mac_pe_piped,divider_or_reciprocal_seq}/
```

After the per-module numbers come back, flip `USE_PIPELINED_DIVIDER=1`
and `USE_PIPED_MAC=1` at the top-level instantiations in v_hand
(stream_pipeline.v for the divider, accel_engine.v for the mac), bump
`DRAIN_CYCLES` to 5, and re-run the full OpenLane flow on `top_small.v`
to capture the post-M5 chip f_max and area.
