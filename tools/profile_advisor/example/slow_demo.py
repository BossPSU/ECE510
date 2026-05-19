"""Demo script that intentionally contains common Python performance anti-patterns.
Run it through profile_advisor.py to see the report:

    python tools/profile_advisor/profile_advisor.py tools/profile_advisor/example/slow_demo.py
"""

import math
import time

import numpy as np


N = 256
M = 256
K = 256


def matmul_python(A, B):
    """Triple-nested loop matmul -- the matmul-bound anti-pattern."""
    C = [[0.0 for _ in range(M)] for _ in range(N)]
    for i in range(N):
        for j in range(M):
            for k in range(K):
                C[i][j] += A[i][k] * B[k][j]
    return C


def loop_over_array(arr):
    """Pure-Python loop touching every element of a numpy array."""
    s = 0.0
    for i in range(len(arr)):
        s += arr[i] * arr[i]
    return s


def numpy_in_loop(A, xs):
    """np.dot called once per row instead of batched."""
    out = []
    for i in range(len(xs)):
        out.append(np.dot(A, xs[i]))   # also: list append in loop
    return out


def manual_softmax(xs):
    """Custom softmax in a python loop using math.exp."""
    total = 0.0
    out = []
    for x in xs:
        out.append(math.exp(x))
    for v in out:
        total += v
    return [v / total for v in out]


def fp64_default_alloc():
    """numpy alloc without dtype -- defaults to float64."""
    a = np.zeros(1024 * 1024)
    return a.sum()


def recursive_fib(n):
    """Naive recursion with overlapping subproblems."""
    if n < 2:
        return n
    return recursive_fib(n - 1) + recursive_fib(n - 2)


def print_in_hot_path(n):
    """Hot loop with print() -- I/O on every iteration."""
    s = 0
    for i in range(n):
        s += i
        if i % 1000 == 0:
            print(f"  progress: {i}")
    return s


def main():
    print("running demo workload...")

    # 1. python matmul
    rng = np.random.default_rng(0)
    A = rng.random((N, K)).tolist()
    B = rng.random((K, M)).tolist()
    C = matmul_python(A, B)

    # 2. python loop over numpy array
    arr = rng.random(50_000)
    s = loop_over_array(arr)

    # 3. np.dot in a loop
    A_np = rng.random((64, 64))
    xs = rng.random((1000, 64))
    out = numpy_in_loop(A_np, xs)

    # 4. manual softmax
    probs = manual_softmax(rng.random(500).tolist())

    # 5. FP64-defaulted alloc
    tot = fp64_default_alloc()

    # 6. recursive fibonacci
    fib = recursive_fib(28)

    # 7. print in hot path
    s2 = print_in_hot_path(10_000)

    print(f"done. C[0][0]={C[0][0]:.4f} s={s:.4f} fib={fib} s2={s2}")


if __name__ == "__main__":
    main()
