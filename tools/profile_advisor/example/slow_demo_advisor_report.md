# Profile Advisor Report

**Target script:** `tools/profile_advisor/example/slow_demo.py`

**Total cumulative time (user code, top hits):** 3.742 s


## Top user functions — by cumulative time

| Rank | Function | File:Line | Calls | Self (s) | Cumulative (s) | % of top hits |
|---:|---|---|---:|---:|---:|---:|
| 1 | `main` | `slow_demo.py:78` | 1 | 0.002 | 1.891 | 50.5% |
| 2 | `matmul_python` | `slow_demo.py:18` | 1 | 1.499 | 1.499 | 40.0% |
| 3 | `recursive_fib` | `slow_demo.py:61` | 1,028,457 | 0.329 | 0.329 | 8.8% |
| 4 | `loop_over_array` | `slow_demo.py:28` | 1 | 0.014 | 0.014 | 0.4% |
| 5 | `fp64_default_alloc` | `slow_demo.py:55` | 1 | 0.000 | 0.004 | 0.1% |
| 6 | `numpy_in_loop` | `slow_demo.py:36` | 1 | 0.003 | 0.003 | 0.1% |
| 7 | `print_in_hot_path` | `slow_demo.py:68` | 1 | 0.001 | 0.001 | 0.0% |
| 8 | `manual_softmax` | `slow_demo.py:44` | 1 | 0.000 | 0.000 | 0.0% |

## Top user functions — by self time

| Rank | Function | File:Line | Calls | Self (s) | Cumulative (s) |
|---:|---|---|---:|---:|---:|
| 1 | `matmul_python` | `slow_demo.py:18` | 1 | 1.499 | 1.499 |
| 2 | `recursive_fib` | `slow_demo.py:61` | 1,028,457 | 0.329 | 0.329 |
| 3 | `loop_over_array` | `slow_demo.py:28` | 1 | 0.014 | 0.014 |
| 4 | `numpy_in_loop` | `slow_demo.py:36` | 1 | 0.003 | 0.003 |
| 5 | `main` | `slow_demo.py:78` | 1 | 0.002 | 1.891 |
| 6 | `print_in_hot_path` | `slow_demo.py:68` | 1 | 0.001 | 0.001 |
| 7 | `manual_softmax` | `slow_demo.py:44` | 1 | 0.000 | 0.000 |
| 8 | `fp64_default_alloc` | `slow_demo.py:55` | 1 | 0.000 | 0.004 |

## Per-function analysis

### `main` — `slow_demo.py:78`

- Calls: **1**, self time: **0.002 s**, cum time: **1.891 s**

**Detected patterns:**

#### [MEDIUM] `print()` call inside a hot function
- _Evidence:_ print() in function body (line 79)
- _Why it's slow:_ Print does string formatting + I/O system call + buffer flush. Easily 100-1000x slower than the arithmetic around it.
- _Software fixes:_
  - Remove debug `print`s, or guard with `if DEBUG:`.
  - If logging is needed, use `logging` with level WARN+ to skip evaluation entirely.
  - Batch prints: accumulate in a list, print once at the end.

#### [MEDIUM] `print()` call inside a hot function
- _Evidence:_ print() in function body (line 108)
- _Why it's slow:_ Print does string formatting + I/O system call + buffer flush. Easily 100-1000x slower than the arithmetic around it.
- _Software fixes:_
  - Remove debug `print`s, or guard with `if DEBUG:`.
  - If logging is needed, use `logging` with level WARN+ to skip evaluation entirely.
  - Batch prints: accumulate in a list, print once at the end.

**Source:**
```python
def main():
    print('running demo workload...')
    rng = np.random.default_rng(0)
    A = rng.random((N, K)).tolist()
    B = rng.random((K, M)).tolist()
    C = matmul_python(A, B)
    arr = rng.random(50000)
    s = loop_over_array(arr)
    A_np = rng.random((64, 64))
    xs = rng.random((1000, 64))
    out = numpy_in_loop(A_np, xs)
    probs = manual_softmax(rng.random(500).tolist())
    tot = fp64_default_alloc()
    fib = recursive_fib(28)
    s2 = print_in_hot_path(10000)
    print(f'done. C[0][0]={C[0][0]:.4f} s={s:.4f} fib={fib} s2={s2}')
```

### `matmul_python` — `slow_demo.py:18`

- Calls: **1**, self time: **1.499 s**, cum time: **1.499 s**

**Detected patterns:**

#### [HIGH] Pure Python loop over array indices
- _Evidence:_ loop variable `i` indexes into arrays inside the body (line 21)
- _Why it's slow:_ Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.
- _Software fixes:_
  - Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).
  - If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).
  - For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.
- _Hardware would help by:_
  - Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.
  - For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).

#### [HIGH] Pure Python loop over array indices
- _Evidence:_ loop variable `j` indexes into arrays inside the body (line 22)
- _Why it's slow:_ Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.
- _Software fixes:_
  - Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).
  - If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).
  - For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.
- _Hardware would help by:_
  - Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.
  - For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).

#### [HIGH] Nested loops doing element-wise arithmetic (looks matmul-like)
- _Evidence:_ nested for-loops with multiply-add at depth 2 (line 22)
- _Why it's slow:_ Three nested loops with multiply-accumulate is the classic O(N^3) matmul. In Python this is catastrophically slow; even with NumPy in a loop it's much worse than calling matmul directly.
- _Software fixes:_
  - If this is matmul: use `np.matmul`, `np.einsum`, or `A @ B`. Speedup: 100-10,000x.
  - For batched matmul: `np.einsum('bij,bjk->bik', A, B)` or `torch.bmm`.
  - For very large matrices: switch to PyTorch + CUDA for tensor cores.
- _Hardware would help by:_
  - GPU tensor cores deliver 10-100x speedup over CPU for matmul workloads (NVIDIA RTX 4090: 1,321 TOPS INT8; H100: 3,958 TOPS).
  - TPUs and custom systolic arrays specifically accelerate this pattern.

#### [HIGH] Pure Python loop over array indices
- _Evidence:_ loop variable `k` indexes into arrays inside the body (line 23)
- _Why it's slow:_ Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.
- _Software fixes:_
  - Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).
  - If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).
  - For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.
- _Hardware would help by:_
  - Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.
  - For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).

#### [HIGH] Nested loops doing element-wise arithmetic (looks matmul-like)
- _Evidence:_ nested for-loops with multiply-add at depth 3 (line 23)
- _Why it's slow:_ Three nested loops with multiply-accumulate is the classic O(N^3) matmul. In Python this is catastrophically slow; even with NumPy in a loop it's much worse than calling matmul directly.
- _Software fixes:_
  - If this is matmul: use `np.matmul`, `np.einsum`, or `A @ B`. Speedup: 100-10,000x.
  - For batched matmul: `np.einsum('bij,bjk->bik', A, B)` or `torch.bmm`.
  - For very large matrices: switch to PyTorch + CUDA for tensor cores.
- _Hardware would help by:_
  - GPU tensor cores deliver 10-100x speedup over CPU for matmul workloads (NVIDIA RTX 4090: 1,321 TOPS INT8; H100: 3,958 TOPS).
  - TPUs and custom systolic arrays specifically accelerate this pattern.

**Source:**
```python
def matmul_python(A, B):
    """Triple-nested loop matmul -- the matmul-bound anti-pattern."""
    C = [[0.0 for _ in range(M)] for _ in range(N)]
    for i in range(N):
        for j in range(M):
            for k in range(K):
                C[i][j] += A[i][k] * B[k][j]
    return C
```

### `recursive_fib` — `slow_demo.py:61`

- Calls: **1,028,457**, self time: **0.329 s**, cum time: **0.329 s**

**Detected patterns:**

#### [MEDIUM] Recursive function with overlapping subproblems
- _Evidence:_ function `recursive_fib` calls itself (line 65)
- _Why it's slow:_ Recursion has Python's per-call overhead (~1 microsecond) and risks stack overflow at depth ~1000. If subproblems overlap (e.g., Fibonacci), exponential blow-up is possible.
- _Software fixes:_
  - Memoize with `@functools.lru_cache(maxsize=None)` if subproblems repeat.
  - Convert to iteration if the recursion is tail-recursive.
  - For dynamic-programming patterns, build the table bottom-up with an array.

#### [MEDIUM] Hot function with very high call count but small per-call work
- _Evidence:_ 1,028,457 calls averaging 0.32 microsec each
- _Why it's slow:_ Python's function-call overhead is ~1 microsecond. If per-call work is much smaller than that, you spend most time on dispatch.
- _Software fixes:_
  - Inline the body into the caller, or accept a batched argument.
  - If the function is pure and side-effect-free, `@functools.lru_cache` may eliminate repeated work.
  - Compile with `numba.njit` to eliminate the Python call overhead.

**Source:**
```python
def recursive_fib(n):
    """Naive recursion with overlapping subproblems."""
    if n < 2:
        return n
    return recursive_fib(n - 1) + recursive_fib(n - 2)
```

### `loop_over_array` — `slow_demo.py:28`

- Calls: **1**, self time: **0.014 s**, cum time: **0.014 s**

**Detected patterns:**

#### [HIGH] Pure Python loop over array indices
- _Evidence:_ loop variable `i` indexes into arrays inside the body (line 31)
- _Why it's slow:_ Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.
- _Software fixes:_
  - Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).
  - If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).
  - For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.
- _Hardware would help by:_
  - Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.
  - For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).

#### [LOW] String concatenation (`s += ...`) inside a loop
- _Evidence:_ augmented add on `s` inside loop (may be string concat) (line 32)
- _Why it's slow:_ Strings are immutable in Python. `s += x` builds a fresh string each iteration -> O(N^2) total work.
- _Software fixes:_
  - Use `''.join(list_of_strings)` after collecting parts in a list.
  - Or `io.StringIO()` with `.write()` for streaming text construction.

**Source:**
```python
def loop_over_array(arr):
    """Pure-Python loop touching every element of a numpy array."""
    s = 0.0
    for i in range(len(arr)):
        s += arr[i] * arr[i]
    return s
```

### `fp64_default_alloc` — `slow_demo.py:55`

- Calls: **1**, self time: **0.000 s**, cum time: **0.004 s**

**Detected patterns:**

#### [LOW] NumPy arrays defaulted to float64 (FP64)
- _Evidence:_ np.zeros(...) without dtype= (defaults to float64) (line 57)
- _Why it's slow:_ NumPy defaults to FP64 (8 bytes/element). For ML workloads, FP32 is usually plenty; cutting precision halves memory bandwidth and improves SIMD throughput.
- _Software fixes:_
  - Specify dtype: `np.zeros(N, dtype=np.float32)` (or float16 if precision allows).
  - For PyTorch: cast tensors with `.float()` or `.half()`; use `torch.set_default_dtype(torch.float32)`.
- _Hardware would help by:_
  - Half-precision (FP16/BF16) unlocks tensor cores on modern GPUs for 2-8x throughput.
  - INT8 quantization (with `torch.quantization`) unlocks dedicated INT8 datapaths for another 2-4x.
  - Custom AI accelerators (Apple Neural Engine, Hailo, Edge TPU) are INT8-native and far more power-efficient than GPUs in this mode.

**Source:**
```python
def fp64_default_alloc():
    """numpy alloc without dtype -- defaults to float64."""
    a = np.zeros(1024 * 1024)
    return a.sum()
```

### `numpy_in_loop` — `slow_demo.py:36`

- Calls: **1**, self time: **0.003 s**, cum time: **0.003 s**

**Detected patterns:**

#### [HIGH] Pure Python loop over array indices
- _Evidence:_ loop variable `i` indexes into arrays inside the body (line 39)
- _Why it's slow:_ Python loops iterating over array elements pay interpreter overhead on every iteration. Each element-level operation is ~100x slower than a vectorized equivalent.
- _Software fixes:_
  - Replace the loop with a NumPy/PyTorch vectorized expression (e.g. `arr ** 2`, `np.sum(arr, axis=0)`, `np.dot(A, B)`).
  - If vectorization is hard to express, try `numpy.vectorize` (cosmetic only, still slow) or `numba.jit(nopython=True)` (real speedup, often 50-100x).
  - For numerical kernels, `Cython` or `pythran` AOT-compile to C for similar gains.
- _Hardware would help by:_
  - Once vectorized, modern CPUs (AVX2/AVX-512) handle this well. No HW change needed for typical workloads.
  - For very large arrays (>1 GB), consider GPU offload via `cupy` (drop-in NumPy replacement).

#### [MEDIUM] NumPy call inside a Python loop
- _Evidence:_ call to `np.dot` inside for-loop (line 40)
- _Why it's slow:_ Each `np.func(...)` call has Python-side overhead (~1-5 microseconds). Calling it N times in a Python loop sees that overhead N times. The trick is to batch into one call.
- _Software fixes:_
  - Batch the operands: instead of `for i: np.dot(A, x[i])`, use one call `np.dot(A, x.T).T` or `np.einsum`.
  - If the per-iteration shapes differ, consider list -> array conversion outside the loop.
  - For PyTorch: `torch.vmap(f)(batched_input)` vectorizes a function over a batch dimension automatically.
- _Hardware would help by:_
  - Same as matmul: vectorization first, then CPU SIMD suffices for most sizes.

#### [LOW] Repeated `list.append` in a loop with known size
- _Evidence:_ .append() inside for-loop (line 40)
- _Why it's slow:_ Appending to a list is amortized O(1) but still allocates and reallocates. If the size is known, pre-allocation is faster and uses less peak memory.
- _Software fixes:_
  - Pre-allocate: `result = [None] * N` (or `np.empty(N)` for numeric), then `result[i] = ...`.
  - If the result is numeric, build an `np.ndarray` directly with `np.empty(N)` and fill by index.
  - If the result is variable-size, consider `array.array` (typed) or `bytearray` (bytes).

**Source:**
```python
def numpy_in_loop(A, xs):
    """np.dot called once per row instead of batched."""
    out = []
    for i in range(len(xs)):
        out.append(np.dot(A, xs[i]))
    return out
```

### `print_in_hot_path` — `slow_demo.py:68`

- Calls: **1**, self time: **0.001 s**, cum time: **0.001 s**

**Detected patterns:**

#### [LOW] String concatenation (`s += ...`) inside a loop
- _Evidence:_ augmented add on `s` inside loop (may be string concat) (line 72)
- _Why it's slow:_ Strings are immutable in Python. `s += x` builds a fresh string each iteration -> O(N^2) total work.
- _Software fixes:_
  - Use `''.join(list_of_strings)` after collecting parts in a list.
  - Or `io.StringIO()` with `.write()` for streaming text construction.

#### [MEDIUM] `print()` call inside a hot function
- _Evidence:_ print() in function body (line 74)
- _Why it's slow:_ Print does string formatting + I/O system call + buffer flush. Easily 100-1000x slower than the arithmetic around it.
- _Software fixes:_
  - Remove debug `print`s, or guard with `if DEBUG:`.
  - If logging is needed, use `logging` with level WARN+ to skip evaluation entirely.
  - Batch prints: accumulate in a list, print once at the end.

**Source:**
```python
def print_in_hot_path(n):
    """Hot loop with print() -- I/O on every iteration."""
    s = 0
    for i in range(n):
        s += i
        if i % 1000 == 0:
            print(f'  progress: {i}')
    return s
```

### `manual_softmax` — `slow_demo.py:44`

- Calls: **1**, self time: **0.000 s**, cum time: **0.000 s**

**Detected patterns:**

#### [LOW] Repeated `list.append` in a loop with known size
- _Evidence:_ .append() inside for-loop (line 49)
- _Why it's slow:_ Appending to a list is amortized O(1) but still allocates and reallocates. If the size is known, pre-allocation is faster and uses less peak memory.
- _Software fixes:_
  - Pre-allocate: `result = [None] * N` (or `np.empty(N)` for numeric), then `result[i] = ...`.
  - If the result is numeric, build an `np.ndarray` directly with `np.empty(N)` and fill by index.
  - If the result is variable-size, consider `array.array` (typed) or `bytearray` (bytes).

#### [MEDIUM] Custom softmax / exp / log / tanh implementation
- _Evidence:_ math.exp in a loop (line 49)
- _Why it's slow:_ Transcendentals from `math.*` in a Python loop are far slower than `numpy.exp(arr)`, which is itself slower than hardware-accelerated equivalents on a GPU/TPU.
- _Software fixes:_
  - Use `np.exp`, `np.tanh`, `scipy.special.softmax` rather than rolling your own.
  - For repeated softmax over the same axis: `scipy.special.softmax(arr, axis=-1)`.
- _Hardware would help by:_
  - GPU activation throughput is enormous (FP16 tanh: 1 GTanh/s/SM on modern GPUs).
  - Custom accelerators often have dedicated activation units (e.g., the `gelu_unit`/`softmax_unit` in this repo).

#### [LOW] String concatenation (`s += ...`) inside a loop
- _Evidence:_ augmented add on `total` inside loop (may be string concat) (line 51)
- _Why it's slow:_ Strings are immutable in Python. `s += x` builds a fresh string each iteration -> O(N^2) total work.
- _Software fixes:_
  - Use `''.join(list_of_strings)` after collecting parts in a list.
  - Or `io.StringIO()` with `.write()` for streaming text construction.

**Source:**
```python
def manual_softmax(xs):
    """Custom softmax in a python loop using math.exp."""
    total = 0.0
    out = []
    for x in xs:
        out.append(math.exp(x))
    for v in out:
        total += v
    return [v / total for v in out]
```

## Overall workload classification

**Tags:** `matmul-bound`, `activation-heavy`, `memory-allocation-bound`, `recursive / branching`, `FP64-defaulted`

**Hardware-target recommendations:**
- **Matmul-dominated** -> a GPU is the obvious upgrade. RTX 4090 (~83 TFLOPS FP32, ~1.3 PetaOps INT8) or H100 if you have datacenter access.
- **Activation-heavy** -> custom AI accelerators with dedicated exp/tanh/softmax units (e.g., NVIDIA Tensor Cores, Apple Neural Engine, Hailo-8) outperform CPU by 10-100x on these ops.
- **Memory-allocation bound** -> fix this in SW first (pre-allocate). No HW change helps if Python is reallocating arrays in a hot loop.
- **FP64-defaulted** -> drop to FP32 or FP16 first. Then GPU tensor cores (FP16/BF16) or AI accelerators (INT8) give 2-8x throughput.

---
_Generated by `profile_advisor.py`._ 
_This is a static analysis of the AST of hot functions plus cProfile timing. Use it as a starting point, not a final answer; some recommendations may not apply to your specific case._