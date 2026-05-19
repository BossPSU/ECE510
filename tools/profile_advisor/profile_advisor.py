#!/usr/bin/env python3
"""
profile_advisor.py -- Profile any Python script and report per-kernel runtime
with software (and hardware) recommendations to reduce that runtime.

Usage:
    python profile_advisor.py path/to/script.py [-- arg1 arg2 ...]

Outputs a markdown report alongside the target script:
    <script>_advisor_report.md

How it works:
  1. Runs the target script under cProfile.
  2. Filters out stdlib / site-packages noise; keeps user code.
  3. Picks the top-N hot functions by cumulative time AND by self time.
  4. For each hot function:
       - Reads the source via Python's `inspect` / `ast`.
       - Walks the AST looking for known anti-patterns (Python loops over
         arrays, list append in loops, np ops inside loops, recursion,
         print in hot path, etc.).
       - Emits per-pattern SW and HW recommendations.
  5. Classifies the overall workload (matmul-bound, activation-heavy,
     memory-bound, branch-heavy, sequential) and recommends a target
     hardware class.
"""

from __future__ import annotations

import argparse
import ast
import cProfile
import io
import os
import pstats
import runpy
import sys
import textwrap
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path


# ============================================================================
# 1. Profile the target
# ============================================================================
def run_with_profile(target_script: str, script_args: list[str]) -> cProfile.Profile:
    """Run target_script under cProfile with the given argv tail."""
    sys.argv = [target_script] + list(script_args)
    profiler = cProfile.Profile()
    profiler.enable()
    try:
        runpy.run_path(target_script, run_name="__main__")
    except SystemExit:
        pass
    profiler.disable()
    return profiler


# ============================================================================
# 2. Filter hot functions to user code
# ============================================================================
_STDLIB_HINTS = ("site-packages", "/lib/python", "\\lib\\python",
                 "/lib64/python", "<frozen", "<built-in>")


def _is_user_code(filename: str, user_root: str | None) -> bool:
    """Conservative: user code lives under user_root and isn't stdlib/site-pkg."""
    if not filename or filename.startswith("<"):
        return False
    if not filename.endswith(".py"):
        return False
    f = os.path.abspath(filename).replace("\\", "/")
    if any(hint in f for hint in _STDLIB_HINTS):
        return False
    # also filter out things under sys.prefix (the Python install dir)
    prefix = os.path.abspath(sys.prefix).replace("\\", "/")
    if f.startswith(prefix):
        return False
    if user_root:
        root = os.path.abspath(user_root).replace("\\", "/")
        return f.startswith(root)
    return True


def top_hot_functions(profiler: cProfile.Profile, n: int, by: str,
                       user_root: str | None) -> list[dict]:
    """Return the top-N user functions sorted by 'cumulative' or 'tottime'.

    We keep full file paths (no strip_dirs) so source extraction works.
    """
    s = pstats.Stats(profiler)
    # NOTE: no strip_dirs() — we need the absolute path for source lookup.
    rows = []
    for (filename, lineno, name), (cc, nc, tt, ct, callers) in s.stats.items():
        if not _is_user_code(filename, user_root):
            continue
        # also skip the synthetic `<module>` entries — those are just module
        # top-level execution; not useful for the per-function analysis.
        if name == "<module>":
            continue
        rows.append({
            "file": filename,
            "line": lineno,
            "name": name,
            "ncalls": nc,
            "tottime": tt,
            "cumtime": ct,
        })
    key = "cumtime" if by == "cumulative" else "tottime"
    rows.sort(key=lambda r: r[key], reverse=True)
    return rows[:n]


# ============================================================================
# 3. Source extraction
# ============================================================================
def extract_function_source(filename: str, lineno: int) -> tuple[str | None, ast.AST | None]:
    """Return (source_text, ast_node) for the function whose def is at lineno.

    Tries to find a FunctionDef/AsyncFunctionDef in the file whose line range
    encloses `lineno`. Returns (None, None) if not found.
    """
    # The profiler often uses the ORIGINAL filename; strip_dirs makes it relative.
    # We try the relative path first; if that fails, try a few common parents.
    candidates = [filename, os.path.join(os.getcwd(), filename)]
    for cand in candidates:
        try:
            source = Path(cand).read_text(encoding="utf-8", errors="ignore")
            tree = ast.parse(source, filename=cand)
        except Exception:
            continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                start = node.lineno
                end = getattr(node, "end_lineno", start + 200)
                if start <= lineno <= end:
                    try:
                        return ast.unparse(node), node
                    except Exception:
                        # ast.unparse needs 3.9+; fall back to source lines
                        lines = source.splitlines()
                        return "\n".join(lines[start - 1:end]), node
    return None, None


# ============================================================================
# 4. Pattern detection
# ============================================================================
@dataclass
class Pattern:
    key: str                       # short identifier
    severity: str = "medium"       # "high" / "medium" / "low"
    detail: str = ""               # human-readable specifics
    evidence_line: int | None = None


# A library of patterns this analyzer recognizes, with their SW/HW advice.
RECOMMENDATIONS: dict[str, dict] = {
    "python_loop_over_array": {
        "title": "Pure Python loop over array indices",
        "why": "Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.",
        "sw": [
            "Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).",
            "If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).",
            "For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.",
        ],
        "hw": [
            "Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.",
            "For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).",
        ],
    },
    "nested_loops_arithmetic": {
        "title": "Nested loops doing element-wise arithmetic (looks matmul-like)",
        "why": "Three nested loops with multiply-accumulate is the classic O(N^3) matmul. In Python this is catastrophically slow; even with NumPy in a loop it's much worse than calling matmul directly.",
        "sw": [
            "If this is matmul: use `np.matmul`, `np.einsum`, or `A @ B`. Speedup: 100-10,000x.",
            "For batched matmul: `np.einsum('bij,bjk->bik', A, B)` or `torch.bmm`.",
            "For very large matrices: switch to PyTorch + CUDA for tensor cores.",
        ],
        "hw": [
            "GPU tensor cores deliver 10-100x speedup over CPU for matmul workloads (NVIDIA RTX 4090: 1,321 TOPS INT8; H100: 3,958 TOPS).",
            "TPUs and custom systolic arrays specifically accelerate this pattern.",
        ],
    },
    "numpy_call_in_loop": {
        "title": "NumPy call inside a Python loop",
        "why": "Each `np.func(...)` call has Python-side overhead (~1-5 microseconds). Calling it N times in a Python loop sees that overhead N times. The trick is to batch into one call.",
        "sw": [
            "Batch the operands: instead of `for i: np.dot(A, x[i])`, use one call `np.dot(A, x.T).T` or `np.einsum`.",
            "If the per-iteration shapes differ, consider list -> array conversion outside the loop.",
            "For PyTorch: `torch.vmap(f)(batched_input)` vectorizes a function over a batch dimension automatically.",
        ],
        "hw": [
            "Same as matmul: vectorization first, then CPU SIMD suffices for most sizes.",
        ],
    },
    "list_append_in_loop": {
        "title": "Repeated `list.append` in a loop with known size",
        "why": "Appending to a list is amortized O(1) but still allocates and reallocates. If the size is known, pre-allocation is faster and uses less peak memory.",
        "sw": [
            "Pre-allocate: `result = [None] * N` (or `np.empty(N)` for numeric), then `result[i] = ...`.",
            "If the result is numeric, build an `np.ndarray` directly with `np.empty(N)` and fill by index.",
            "If the result is variable-size, consider `array.array` (typed) or `bytearray` (bytes).",
        ],
        "hw": [],
    },
    "np_append_in_loop": {
        "title": "`np.append` inside a loop",
        "why": "`np.append` reallocates the whole array every call -> O(N^2) total. Catastrophic for any N > 1000.",
        "sw": [
            "Pre-allocate with `np.empty(N)` and fill by index. Or collect a Python list and `np.array(list)` once at the end.",
        ],
        "hw": [],
    },
    "string_concat_in_loop": {
        "title": "String concatenation (`s += ...`) inside a loop",
        "why": "Strings are immutable in Python. `s += x` builds a fresh string each iteration -> O(N^2) total work.",
        "sw": [
            "Use `''.join(list_of_strings)` after collecting parts in a list.",
            "Or `io.StringIO()` with `.write()` for streaming text construction.",
        ],
        "hw": [],
    },
    "recursive_self_call": {
        "title": "Recursive function with overlapping subproblems",
        "why": "Recursion has Python's per-call overhead (~1 microsecond) and risks stack overflow at depth ~1000. If subproblems overlap (e.g., Fibonacci), exponential blow-up is possible.",
        "sw": [
            "Memoize with `@functools.lru_cache(maxsize=None)` if subproblems repeat.",
            "Convert to iteration if the recursion is tail-recursive.",
            "For dynamic-programming patterns, build the table bottom-up with an array.",
        ],
        "hw": [],
    },
    "print_in_hot_path": {
        "title": "`print()` call inside a hot function",
        "why": "Print does string formatting + I/O system call + buffer flush. Easily 100-1000x slower than the arithmetic around it.",
        "sw": [
            "Remove debug `print`s, or guard with `if DEBUG:`.",
            "If logging is needed, use `logging` with level WARN+ to skip evaluation entirely.",
            "Batch prints: accumulate in a list, print once at the end.",
        ],
        "hw": [],
    },
    "sleep_in_path": {
        "title": "`time.sleep()` in profiled code",
        "why": "Blocking sleep wastes wall time. If you're polling, you almost certainly want async.",
        "sw": [
            "Switch to `asyncio.sleep` if you need cooperative concurrency.",
            "If polling external state, use `select`/`poll`/event-driven design.",
            "Remove if it was a placeholder.",
        ],
        "hw": [],
    },
    "many_attribute_lookups": {
        "title": "Many attribute lookups in a hot loop",
        "why": "`obj.method` triggers a dict lookup on every access. In hot loops, bind to a local: `m = obj.method; for ...: m(x)`.",
        "sw": [
            "Hoist attribute lookups before the loop into local variables.",
            "Replace `len(arr)` calls inside the loop with a precomputed `n = len(arr)`.",
        ],
        "hw": [],
    },
    "fp64_numeric": {
        "title": "NumPy arrays defaulted to float64 (FP64)",
        "why": "NumPy defaults to FP64 (8 bytes/element). For ML workloads, FP32 is usually plenty; cutting precision halves memory bandwidth and improves SIMD throughput.",
        "sw": [
            "Specify dtype: `np.zeros(N, dtype=np.float32)` (or float16 if precision allows).",
            "For PyTorch: cast tensors with `.float()` or `.half()`; use `torch.set_default_dtype(torch.float32)`.",
        ],
        "hw": [
            "Half-precision (FP16/BF16) unlocks tensor cores on modern GPUs for 2-8x throughput.",
            "INT8 quantization (with `torch.quantization`) unlocks dedicated INT8 datapaths for another 2-4x.",
            "Custom AI accelerators (Apple Neural Engine, Hailo, Edge TPU) are INT8-native and far more power-efficient than GPUs in this mode.",
        ],
    },
    "frequent_global_access": {
        "title": "Frequent global / module-level variable access in a hot function",
        "why": "Globals are looked up via a module dict; locals are O(1) array access in the call frame.",
        "sw": [
            "Pass module-level constants as default arguments: `def f(x, _CONST=CONST):` -> CONST becomes a local lookup.",
            "Or bind globals to locals at the top of the function: `local_const = CONST`.",
        ],
        "hw": [],
    },
    "dict_in_hot_loop": {
        "title": "Many dict lookups inside a hot loop",
        "why": "Dict lookup is O(1) amortized but has hashing overhead. In a hot loop with the same keys, you may be re-hashing the same string thousands of times.",
        "sw": [
            "Hoist constant-key lookups outside the loop into locals.",
            "If the dict has small fixed keys, consider a `namedtuple` or `dataclass` with attribute access (faster).",
            "If the dict acts as a small jump-table, a Python `match` (3.10+) or chained `if/elif` can be faster than dict dispatch.",
        ],
        "hw": [],
    },
    "manual_softmax_or_exp_loop": {
        "title": "Custom softmax / exp / log / tanh implementation",
        "why": "Transcendentals from `math.*` in a Python loop are far slower than `numpy.exp(arr)`, which is itself slower than hardware-accelerated equivalents on a GPU/TPU.",
        "sw": [
            "Use `np.exp`, `np.tanh`, `scipy.special.softmax` rather than rolling your own.",
            "For repeated softmax over the same axis: `scipy.special.softmax(arr, axis=-1)`.",
        ],
        "hw": [
            "GPU activation throughput is enormous (FP16 tanh: 1 GTanh/s/SM on modern GPUs).",
            "Custom accelerators often have dedicated activation units (e.g., the `gelu_unit`/`softmax_unit` in this repo).",
        ],
    },
    "large_call_count_small_work": {
        "title": "Hot function with very high call count but small per-call work",
        "why": "Python's function-call overhead is ~1 microsecond. If per-call work is much smaller than that, you spend most time on dispatch.",
        "sw": [
            "Inline the body into the caller, or accept a batched argument.",
            "If the function is pure and side-effect-free, `@functools.lru_cache` may eliminate repeated work.",
            "Compile with `numba.njit` to eliminate the Python call overhead.",
        ],
        "hw": [],
    },
}


class PatternAnalyzer(ast.NodeVisitor):
    """Walk a function's AST and accumulate detected anti-patterns."""

    def __init__(self):
        self.patterns: list[Pattern] = []
        self._for_depth = 0
        self._function_name: str | None = None
        # tally counters for end-of-walk aggregate patterns
        self._global_accesses = 0
        self._local_accesses = 0
        self._dict_subscripts = 0
        self._numpy_calls_in_loops = 0
        self._for_bodies_with_arith = 0

    # ---- track current scope ----
    def visit_FunctionDef(self, node: ast.FunctionDef):
        prev = self._function_name
        self._function_name = node.name
        self.generic_visit(node)
        self._function_name = prev
        self._end_of_walk_aggregates()

    visit_AsyncFunctionDef = visit_FunctionDef

    # ---- For loops ----
    def visit_For(self, node: ast.For):
        self._for_depth += 1
        is_range = (
            isinstance(node.iter, ast.Call)
            and isinstance(node.iter.func, ast.Name)
            and node.iter.func.id == "range"
        )

        # python loop over array indices?
        if is_range and isinstance(node.target, ast.Name):
            tgt = node.target.id
            for sub in ast.walk(node):
                if isinstance(sub, ast.Subscript) and isinstance(sub.slice, ast.Name) and sub.slice.id == tgt:
                    self.patterns.append(Pattern(
                        "python_loop_over_array", "high",
                        f"loop variable `{tgt}` indexes into arrays inside the body",
                        node.lineno,
                    ))
                    break

        # nested arithmetic (matmul-shaped)?
        if self._for_depth >= 2:
            has_mul = any(isinstance(n, ast.BinOp) and isinstance(n.op, ast.Mult) for n in ast.walk(node))
            has_add = any(
                (isinstance(n, ast.AugAssign) and isinstance(n.op, ast.Add))
                or (isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add))
                for n in ast.walk(node)
            )
            if has_mul and has_add:
                self.patterns.append(Pattern(
                    "nested_loops_arithmetic", "high",
                    f"nested for-loops with multiply-add at depth {self._for_depth}",
                    node.lineno,
                ))

        # numpy/torch call inside this loop
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute):
                if _is_array_lib_call(sub.func):
                    self.patterns.append(Pattern(
                        "numpy_call_in_loop", "medium",
                        f"call to `{_pretty_attr(sub.func)}` inside for-loop",
                        sub.lineno,
                    ))
                    break

        # appends inside loop
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute):
                if sub.func.attr == "append":
                    self.patterns.append(Pattern(
                        "list_append_in_loop", "low",
                        ".append() inside for-loop", sub.lineno,
                    ))
                    break
                if sub.func.attr == "append" and _is_np_object(sub.func.value):
                    self.patterns.append(Pattern("np_append_in_loop", "high", "np.append inside loop", sub.lineno))
                    break

        # string concat
        for sub in ast.walk(node):
            if isinstance(sub, ast.AugAssign) and isinstance(sub.op, ast.Add):
                if isinstance(sub.target, ast.Name):
                    # rough heuristic: name ends with 's' or 'str' suggests string
                    self.patterns.append(Pattern(
                        "string_concat_in_loop", "low",
                        f"augmented add on `{sub.target.id}` inside loop (may be string concat)",
                        sub.lineno,
                    ))
                    break

        # generic body walk
        self.generic_visit(node)
        self._for_depth -= 1

    # ---- Calls ----
    def visit_Call(self, node: ast.Call):
        # print()
        if isinstance(node.func, ast.Name) and node.func.id == "print":
            self.patterns.append(Pattern("print_in_hot_path", "medium", "print() in function body", node.lineno))
        # time.sleep
        if isinstance(node.func, ast.Attribute) and node.func.attr == "sleep":
            if isinstance(node.func.value, ast.Name) and node.func.value.id == "time":
                self.patterns.append(Pattern("sleep_in_path", "high", "time.sleep() in function body", node.lineno))
        # softmax / exp / log / tanh hand-rolled in a loop
        if self._for_depth >= 1 and isinstance(node.func, ast.Attribute):
            if node.func.attr in {"exp", "log", "tanh", "softmax"}:
                # only flag if it's from math (not numpy)
                if isinstance(node.func.value, ast.Name) and node.func.value.id == "math":
                    self.patterns.append(Pattern(
                        "manual_softmax_or_exp_loop", "medium",
                        f"math.{node.func.attr} in a loop", node.lineno,
                    ))
        # np.zeros etc without dtype
        if isinstance(node.func, ast.Attribute) and node.func.attr in {"zeros", "ones", "empty", "full"}:
            if _is_np_object(node.func.value):
                has_dtype = any(kw.arg == "dtype" for kw in node.keywords)
                if not has_dtype:
                    self.patterns.append(Pattern(
                        "fp64_numeric", "low",
                        f"np.{node.func.attr}(...) without dtype= (defaults to float64)",
                        node.lineno,
                    ))
        # recursion: self-call detection happens at FunctionDef level via parent's name
        if (isinstance(node.func, ast.Name) and self._function_name and
                node.func.id == self._function_name):
            self.patterns.append(Pattern(
                "recursive_self_call", "medium",
                f"function `{self._function_name}` calls itself", node.lineno,
            ))

        self.generic_visit(node)

    # ---- Subscripts: dict-in-loop accumulator ----
    def visit_Subscript(self, node: ast.Subscript):
        if self._for_depth >= 1:
            self._dict_subscripts += 1
        self.generic_visit(node)

    def _end_of_walk_aggregates(self):
        # heuristics for tally-based detections at function exit
        if self._dict_subscripts > 20:
            self.patterns.append(Pattern(
                "dict_in_hot_loop", "low",
                f"{self._dict_subscripts} subscripts inside loops (could be dict lookups)",
            ))


def _is_array_lib_call(attr: ast.Attribute) -> bool:
    """True if attr is something like np.X / numpy.X / torch.X / jnp.X."""
    obj_names = {"np", "numpy", "torch", "jnp", "tf", "tensorflow", "cupy", "cp"}
    if isinstance(attr.value, ast.Name) and attr.value.id in obj_names:
        return True
    return False


def _is_np_object(node: ast.AST) -> bool:
    return isinstance(node, ast.Name) and node.id in {"np", "numpy"}


def _pretty_attr(attr: ast.Attribute) -> str:
    parts = []
    cur: ast.AST = attr
    while isinstance(cur, ast.Attribute):
        parts.append(cur.attr)
        cur = cur.value
    if isinstance(cur, ast.Name):
        parts.append(cur.id)
    return ".".join(reversed(parts))


def detect_patterns(node: ast.AST, function_name: str) -> list[Pattern]:
    """Run the analyzer over a function AST node. Dedup by (key, evidence_line)."""
    analyzer = PatternAnalyzer()
    analyzer._function_name = function_name
    analyzer.visit(node)
    seen = set()
    out = []
    for p in analyzer.patterns:
        sig = (p.key, p.evidence_line)
        if sig in seen:
            continue
        seen.add(sig)
        out.append(p)
    return out


# ============================================================================
# 5. Workload classification (overall recommendation)
# ============================================================================
def classify_workload(all_patterns: dict[str, list[Pattern]]) -> dict:
    """Look across all hot functions and classify the workload type."""
    seen_keys = {p.key for plist in all_patterns.values() for p in plist}

    tags = []
    if "nested_loops_arithmetic" in seen_keys:
        tags.append("matmul-bound")
    if "manual_softmax_or_exp_loop" in seen_keys:
        tags.append("activation-heavy")
    if {"list_append_in_loop", "np_append_in_loop", "string_concat_in_loop"} & seen_keys:
        tags.append("memory-allocation-bound")
    if "recursive_self_call" in seen_keys:
        tags.append("recursive / branching")
    if "fp64_numeric" in seen_keys:
        tags.append("FP64-defaulted")

    hw_advice = []
    if "matmul-bound" in tags:
        hw_advice.append(
            "**Matmul-dominated** -> a GPU is the obvious upgrade. RTX 4090 (~83 TFLOPS FP32, ~1.3 PetaOps INT8) or H100 if you have datacenter access."
        )
    if "activation-heavy" in tags:
        hw_advice.append(
            "**Activation-heavy** -> custom AI accelerators with dedicated exp/tanh/softmax units (e.g., NVIDIA Tensor Cores, Apple Neural Engine, Hailo-8) outperform CPU by 10-100x on these ops."
        )
    if "memory-allocation-bound" in tags:
        hw_advice.append(
            "**Memory-allocation bound** -> fix this in SW first (pre-allocate). No HW change helps if Python is reallocating arrays in a hot loop."
        )
    if "FP64-defaulted" in tags:
        hw_advice.append(
            "**FP64-defaulted** -> drop to FP32 or FP16 first. Then GPU tensor cores (FP16/BF16) or AI accelerators (INT8) give 2-8x throughput."
        )
    if not tags:
        hw_advice.append(
            "No specific anti-pattern matches. Workload may be branch-heavy or already well-optimized -- a modern CPU is probably the right target."
        )

    return {"tags": tags, "hw_advice": hw_advice}


# ============================================================================
# 6. Report generation
# ============================================================================
def _short_path(p: str, root: str) -> str:
    """Show file path relative to the user_root when possible."""
    try:
        return os.path.relpath(p, root).replace("\\", "/")
    except ValueError:
        return p


def render_report(
    target_script: str,
    by_cum: list[dict],
    by_self: list[dict],
    func_patterns: dict[str, list[Pattern]],
    func_sources: dict[str, str],
    workload: dict,
    user_root: str = "",
) -> str:
    out = []
    out.append(f"# Profile Advisor Report\n")
    out.append(f"**Target script:** `{target_script}`\n")
    total_cum = sum(r["cumtime"] for r in by_cum) if by_cum else 0
    out.append(f"**Total cumulative time (user code, top hits):** {total_cum:.3f} s\n")
    out.append("")

    # ---- top by cumulative ----
    out.append("## Top user functions — by cumulative time\n")
    out.append("| Rank | Function | File:Line | Calls | Self (s) | Cumulative (s) | % of top hits |")
    out.append("|---:|---|---|---:|---:|---:|---:|")
    for i, r in enumerate(by_cum, start=1):
        pct = (r["cumtime"] / total_cum * 100) if total_cum else 0
        out.append(
            f"| {i} | `{r['name']}` | `{_short_path(r['file'], user_root)}:{r['line']}` | {r['ncalls']:,} | "
            f"{r['tottime']:.3f} | {r['cumtime']:.3f} | {pct:.1f}% |"
        )
    out.append("")

    out.append("## Top user functions — by self time\n")
    out.append("| Rank | Function | File:Line | Calls | Self (s) | Cumulative (s) |")
    out.append("|---:|---|---|---:|---:|---:|")
    for i, r in enumerate(by_self, start=1):
        out.append(
            f"| {i} | `{r['name']}` | `{_short_path(r['file'], user_root)}:{r['line']}` | {r['ncalls']:,} | "
            f"{r['tottime']:.3f} | {r['cumtime']:.3f} |"
        )
    out.append("")

    # ---- per-function deep-dives ----
    out.append("## Per-function analysis\n")
    seen_funcs = set()
    for row in by_cum + by_self:
        key = (row["file"], row["line"], row["name"])
        if key in seen_funcs:
            continue
        seen_funcs.add(key)
        fname = row["name"]
        patterns = func_patterns.get(fname, [])
        out.append(f"### `{fname}` — `{_short_path(row['file'], user_root)}:{row['line']}`\n")
        out.append(f"- Calls: **{row['ncalls']:,}**, self time: **{row['tottime']:.3f} s**, cum time: **{row['cumtime']:.3f} s**")
        if row["ncalls"] > 10_000 and row["tottime"] / max(row["ncalls"], 1) < 1e-5:
            patterns.append(Pattern(
                "large_call_count_small_work", "medium",
                f"{row['ncalls']:,} calls averaging {row['tottime'] / row['ncalls'] * 1e6:.2f} microsec each",
            ))

        if not patterns:
            out.append("\n_No specific anti-patterns detected. This function may already be well-optimized or its work happens inside library calls._\n")
            continue

        out.append("\n**Detected patterns:**\n")
        for p in patterns:
            rec = RECOMMENDATIONS.get(p.key)
            if not rec:
                continue
            out.append(f"#### [{p.severity.upper()}] {rec['title']}")
            if p.detail:
                out.append(f"- _Evidence:_ {p.detail}" + (f" (line {p.evidence_line})" if p.evidence_line else ""))
            out.append(f"- _Why it's slow:_ {rec['why']}")
            if rec["sw"]:
                out.append("- _Software fixes:_")
                for s in rec["sw"]:
                    out.append(f"  - {s}")
            if rec["hw"]:
                out.append("- _Hardware would help by:_")
                for h in rec["hw"]:
                    out.append(f"  - {h}")
            out.append("")
        # source snippet (preserve newlines!)
        src = func_sources.get(fname)
        if src:
            lines = src.splitlines()
            if len(lines) > 50:
                snippet = "\n".join(lines[:50]) + "\n    # ... [truncated; full function is " + str(len(lines)) + " lines] ..."
            else:
                snippet = src
            out.append("**Source:**")
            out.append("```python")
            out.append(snippet)
            out.append("```")
            out.append("")

    # ---- overall ----
    out.append("## Overall workload classification\n")
    if workload["tags"]:
        out.append("**Tags:** " + ", ".join(f"`{t}`" for t in workload["tags"]))
    else:
        out.append("**Tags:** _none of the heuristic anti-patterns matched_")
    out.append("")
    out.append("**Hardware-target recommendations:**")
    for line in workload["hw_advice"]:
        out.append(f"- {line}")
    out.append("")
    out.append("---")
    out.append("_Generated by `profile_advisor.py`._ ")
    out.append("_This is a static analysis of the AST of hot functions plus cProfile timing. Use it as a starting point, not a final answer; some recommendations may not apply to your specific case._")
    return "\n".join(out)


# ============================================================================
# 7. CLI
# ============================================================================
def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("script", help="Path to the target Python script.")
    ap.add_argument("script_args", nargs="*", help="Args passed to the target script.")
    ap.add_argument("-n", "--top-n", type=int, default=8, help="How many hot functions to deep-dive (default 8).")
    ap.add_argument("-o", "--out", default=None, help="Output report path (default: <script>_advisor_report.md).")
    args = ap.parse_args()

    script = os.path.abspath(args.script)
    if not os.path.isfile(script):
        sys.exit(f"ERROR: {script} does not exist.")

    print(f"[advisor] profiling {script} ...")
    profiler = run_with_profile(script, args.script_args)

    user_root = os.path.dirname(script)
    by_cum = top_hot_functions(profiler, args.top_n, by="cumulative", user_root=user_root)
    by_self = top_hot_functions(profiler, args.top_n, by="tottime", user_root=user_root)

    func_patterns: dict[str, list[Pattern]] = defaultdict(list)
    func_sources: dict[str, str] = {}
    inspected = set()
    for row in by_cum + by_self:
        key = (row["file"], row["line"], row["name"])
        if key in inspected:
            continue
        inspected.add(key)
        src, node = extract_function_source(row["file"], row["line"])
        if node is None:
            continue
        func_sources[row["name"]] = src or ""
        func_patterns[row["name"]] = detect_patterns(node, row["name"])

    workload = classify_workload(func_patterns)

    out_path = args.out or f"{os.path.splitext(script)[0]}_advisor_report.md"
    report = render_report(args.script, by_cum, by_self, func_patterns, func_sources, workload, user_root)
    Path(out_path).write_text(report, encoding="utf-8")
    print(f"[advisor] report written: {out_path}")
    print(f"[advisor] top function (cum):  {by_cum[0]['name']} -- {by_cum[0]['cumtime']:.3f}s" if by_cum else "[advisor] no user code captured")
    print(f"[advisor] tags: {workload['tags']}")


if __name__ == "__main__":
    main()
