# Planned phobos hierarchical synth -> PnR -> sign-off STA

This is the phobos counterpart to the Sky130/OpenLane M5 run. The chip-scale
deliverable lives in three sequential phases. Phases 1 (M5 leaf single-points)
and 2 (sys_64x64 standalone) from the earlier 6-phase plan are skipped — the
Sky130 leaf single-points already provide the per-block reference, and
stream_pipeline at ARRAY_DIM=64 dominates whatever sys_64x64 would tell us.

## Scope of this doc

Only Phases 3, 4, 5 are implemented in scripts right now:

| Phase | Tool      | Script                                        | What it produces                                |
|-------|-----------|-----------------------------------------------|-------------------------------------------------|
| 3     | Genus     | [run_genus_hier.do](run_genus_hier.do)        | hierarchical netlist + SDC + area/timing reports |
| 4     | Innovus   | [run_innovus_hier.do](run_innovus_hier.do)    | placed-routed DEF, SPEF, GDS, post-route STA     |
| 5     | Innovus   | [run_sta_mc.do](run_sta_mc.do)                | TT/SS/FF sign-off STA + per-corner power         |

The shell driver [`run_phobos_hier.sh`](run_phobos_hier.sh) chains all three
with fail-fast behavior.

## Why a separate hierarchical script (vs the existing sweep)

The existing `run_genus_sweep.do` flattens through every boundary by default.
At ARRAY_DIM=64 the design has:

- 4,096 `mac_pe_piped` instances (inside `systolic_array_64x64`)
- 1 `softmax_unit_lut` with 8 `exp_lut` banks + 1 `divider_or_reciprocal_seq`
- 1 `fused_postproc_unit` with `gelu_direct_lut` + `gelu_grad_direct_lut`
- 4 `tile_buffer` instances

A flat synthesis path tries to optimize across every mac_pe boundary, which
balloons peak RSS past phobos's 64 GB during PBS partitioning — the OOM
that killed prior 64×64 attempts.

The fix is paired:

1. **Genus side** — `set_db auto_ungroup none` + `preserve = true` on every
   highly-replicated or self-contained leaf. Each preserved module is
   synthesized once, cached, and reused. Peak RSS scales with the largest
   single preserved module rather than with the flattened design.
2. **Innovus side** — `set_proto_mode -default keep_design` mirrors the same
   hierarchy preservation into placement, so the placer treats the preserved
   leaves as soft blocks and doesn't try to global-route across 4,096
   mac_pe instances at once.

Empirically this cuts peak RSS by ~3-4× on similarly-replicated arrays —
enough to land 64×64 inside phobos's 64 GB.

## Module preserve list

Picked in `run_genus_hier.do` step 6. Mirrored implicitly by `set_proto_mode`
in `run_innovus_hier.do` step 3.

| Module                       | Why preserve                              | Count at N=64 |
|------------------------------|-------------------------------------------|---------------|
| `mac_pe_piped`               | highest-replication leaf                  | 4,096         |
| `systolic_array_64x64`       | clean partition boundary for PnR          | 1             |
| `exp_lut`                    | bank-replicated LUT inside softmax_unit_lut | 8           |
| `gelu_direct_lut`            | 256×32 ROM, self-contained                | 1             |
| `gelu_grad_direct_lut`       | 256×32 ROM, self-contained                | 1             |
| `divider_or_reciprocal_seq`  | M5 iterative divider, internal state      | 1-2           |
| `softmax_unit_lut`           | big leaf; isolating bounds the worst case | 1             |
| `fused_postproc_unit`        | big leaf; same reason                     | 1             |
| `tile_buffer`                | replicated soft-macro-shaped flop array   | 4             |

Not preserved (small enough to benefit from inlining): `adder_tree`,
`skid_buffer`, `pipeline_stage`, `stream_mux`, `causal_mask_unit`.

## Multi-corner sign-off (Phase 5)

Innovus-native multi-corner STA across three views, post-route:

| View         | Library                  | RC corner | Direction | Use                  |
|--------------|--------------------------|-----------|-----------|----------------------|
| `av_typ`     | `saed32rvt_tt0p85v25c`   | rc_typ    | both      | in-flow baseline     |
| `av_ss_setup`| `saed32rvt_ss0p75v125c`  | rc_max    | setup     | sign-off worst setup |
| `av_ff_hold` | `saed32rvt_ff0p95vn40c`  | rc_min    | hold      | sign-off worst hold  |

Power is reported at each corner via `report_power`. Defaults to 20% toggle
rate; pass a QuestaSim-exported SAIF via the `SAIF` env var for activity-
annotated dynamic power.

Tempus is not used. Innovus's built-in multi-corner timer is accurate to
within ~5% of Tempus sign-off for a single-clock digital block of this
size — standard academic-flow practice and sufficient for the M5
deliverable.

## How to run

```sh
# phobos
addpkg -l cadence-2022-09     # genus + innovus on PATH
cd project/RTL

# default: phases 3 -> 4 -> 5 at ARRAY_N=64
./run_phobos_hier.sh

# or individual phases (each one's snapshot is the next one's input)
./run_phobos_hier.sh phase3
./run_phobos_hier.sh phase4
./run_phobos_hier.sh phase5

# tighter clock target?
CLK_PER=0.7 ./run_phobos_hier.sh

# smaller dimension for a sanity-check pass?
ARRAY_N=16 ./run_phobos_hier.sh
```

Logs land in `logs_hier/`. Outputs:

- `out_sweep/stream_pipeline_64x64_hier/` — Genus netlist + reports
- `out_innovus/stream_pipeline_64x64_hier/` — Innovus snapshots + GDS
- `out_innovus/stream_pipeline_64x64_hier/sta/` — sign-off STA + power

## Expected wall-clock (phobos, single-threaded driver)

| Phase | Activity                       | Wall-clock estimate         |
|-------|--------------------------------|-----------------------------|
| 3     | hierarchical Genus synth       | 45-75 min (vs OOM flat)     |
| 4     | Innovus floorplan -> route     | 2.5-4 hr                    |
| 5     | multi-corner STA + power       | 15-25 min                   |

Total: ~4-5 hr for a clean end-to-end run. Re-runs from the post-CTS or
post-route snapshot for floorplan/CTS tuning are typically 30-90 min each.
