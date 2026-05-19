# profile_advisor

Profile any Python script and get per-kernel runtime with **software** (and
some **hardware**) recommendations to reduce it.

## Quick start

```sh
python tools/profile_advisor/profile_advisor.py path/to/your_script.py
```

Output: a markdown report alongside the script:

```
your_script_advisor_report.md
```

## What it does

1. Runs your script under `cProfile`.
2. Filters to **user code only** (drops stdlib + site-packages).
3. Lists the **top hot functions** by cumulative time and self time.
4. For each hot function, parses the source with Python's `ast` module and
   looks for known anti-patterns:

   | Pattern | Severity |
   |---|---|
   | Pure Python loop over array indices | high |
   | Nested loops doing element-wise arithmetic (matmul-shaped) | high |
   | NumPy/PyTorch call inside a Python loop | medium |
   | `list.append` or `np.append` in a loop | low / high |
   | String concatenation (`s += ...`) in a loop | low |
   | Recursive function with overlapping subproblems | medium |
   | `print()` in a hot function | medium |
   | `time.sleep()` in profiled code | high |
   | `math.exp`/`tanh`/`log` in a loop instead of `numpy` | medium |
   | `np.zeros`/`ones`/`empty` without `dtype=` (defaults to FP64) | low |
   | Many dict subscripts in a hot loop | low |
   | Very high call count + tiny per-call work (call overhead dominates) | medium |

5. Emits per-pattern **software fixes** (vectorize, memoize, pre-allocate,
   batch numpy calls, etc.) and, where applicable, **hardware
   recommendations** (CPU SIMD, GPU tensor cores, AI accelerators).
6. Classifies the overall workload (matmul-bound, activation-heavy,
   memory-allocation-bound, recursive, FP64-defaulted) and suggests a
   target hardware class.

## Example

The included demo script intentionally contains seven anti-patterns:

```sh
python tools/profile_advisor/profile_advisor.py tools/profile_advisor/example/slow_demo.py
```

Then read [`example/slow_demo_advisor_report.md`](example/slow_demo_advisor_report.md).
You should see the tool flag matmul, python-loop-over-array, np.dot in a
loop, math.exp in a loop, FP64 default, naive recursion, and print in a hot
path — with concrete SW fixes for each and HW recommendations where
applicable.

## CLI options

```
profile_advisor.py [-h] [-n TOP_N] [-o OUT] script [script_args ...]

positional:
  script                Path to the target Python script.
  script_args           Args passed to the target script.

optional:
  -n, --top-n           How many hot functions to deep-dive (default 8).
  -o, --out             Output report path (default: <script>_advisor_report.md).
```

## What this is NOT

- **Not a magic fixer.** It points at hot functions and known
  anti-patterns; you still apply the fixes.
- **Not a memory profiler.** Pair it with `memray` or `tracemalloc` if you
  need allocation tracking.
- **Not a line profiler.** It works at function granularity (cProfile).
  For per-line insight, use `line_profiler` or `scalene`.
- **Not framework-aware beyond surface heuristics.** It recognizes
  `np.*` / `torch.*` / `jnp.*` / `tf.*` call patterns but doesn't model
  framework-specific semantics. PyTorch users should also try
  `torch.profiler` for richer per-op FLOP counts.

## Limitations

- **AST static analysis only.** If a function delegates work to a
  dynamically-loaded helper, the analyzer won't see it.
- **Severity is heuristic.** A `print()` flagged in a hot function may
  actually be cheap (called rarely). Read the timing data alongside.
- **No false-negative guarantee.** A "no anti-patterns detected" result
  doesn't mean the function is optimal — just that no rule fired.
- **Workload classification is high-level.** Use it as a starting point
  for thinking about hardware fit; verify with a real benchmark on the
  target hardware.

## Adding new patterns

The recommendation table is the dictionary `RECOMMENDATIONS` near the top
of `profile_advisor.py`. Each entry has `title`, `why`, `sw` (list of
fixes), and `hw` (list of hardware notes). The corresponding detector
lives in the `PatternAnalyzer` class as a `visit_*` method that appends
to `self.patterns`.

To add a new pattern:

1. Add an entry to `RECOMMENDATIONS` with a unique key.
2. Add detection logic in `PatternAnalyzer` (visit some AST node, append
   a `Pattern(key=..., severity=..., detail=...)` when matched).
3. Test against a script that exhibits the pattern.

## Related tools (use alongside)

- `cProfile` (stdlib) — what this tool wraps
- `snakeviz` — interactive flame charts of `.prof` files
- `py-spy` — sampling profiler (lower overhead, runs on live processes)
- `scalene` — CPU + memory + GPU profiler
- `memray` — memory profiler with flame graphs
- `line_profiler` — per-line timing inside a function
- `torch.profiler` — PyTorch-specific, includes FLOP counts and CUDA events
- `fvcore`, `ptflops`, `DeepSpeed flops profiler` — PyTorch model FLOP counters
