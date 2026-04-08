# Arithmetic Intensity: Dominant Kernel (`ff_backward`)

## Config

| Parameter | Value |
|-----------|-------|
| B (batch) | 4 |
| T (seq_len) | 64 |
| D (d_model) | 64 |
| F (d_ff) | 256 |
| N = B*T | 256 |
| Precision | float64 (8 bytes/element) |

## Kernel Code

```python
def ff_backward(dout, cache):
    x, h, h_act, W1, W2 = cache
    B, T, _ = x.shape

    dh_act = dout @ W2.T                                                    # (1)
    dW2 = h_act.reshape(-1, h_act.shape[-1]).T @ dout.reshape(-1, ...)      # (2)
    db2 = dout.sum(axis=(0, 1))                                             # (3)

    dh = dh_act * gelu_grad(h)                                              # (4+5)
    dW1 = x.reshape(-1, x.shape[-1]).T @ dh.reshape(-1, dh.shape[-1])       # (6)
    db1 = dh.sum(axis=(0, 1))                                               # (7)
    dx = dh @ W1.T                                                          # (8)
```

## FLOPs (Analytical Derivation)

For matrix multiply (M,K) @ (K,N): FLOPs = 2*M*K*N (one multiply + one add per output element per K).

### Matrix multiplications

| Op | Description | Shapes | Formula | FLOPs |
|----|-------------|--------|---------|-------|
| (1) | `dout @ W2.T` | (N,D) @ (D,F) | 2 * N * D * F | 2 * 256 * 64 * 256 = 8,388,608 |
| (2) | `h_act.T @ dout` | (F,N) @ (N,D) | 2 * F * N * D | 2 * 256 * 256 * 64 = 8,388,608 |
| (6) | `x.T @ dh` | (D,N) @ (N,F) | 2 * D * N * F | 2 * 64 * 256 * 256 = 8,388,608 |
| (8) | `dx = dh @ W1.T` | (N,F) @ (F,D) | 2 * N * F * D | 2 * 256 * 256 * 64 = 8,388,608 |

**Matmul subtotal: 4 x 8,388,608 = 33,554,432**

### Bias gradient reductions

| Op | Description | Formula | FLOPs |
|----|-------------|---------|-------|
| (3) | `db2 = dout.sum()` | N * D | 256 * 64 = 16,384 |
| (7) | `db1 = dh.sum()` | N * F | 256 * 256 = 65,536 |

**Reduction subtotal: 81,920**

### gelu_grad (element-wise on h, shape (B,T,F), 65,536 elements)

```python
tanh_arg  = sqrt(2/pi) * (x + 0.044715 * x^3)     # 4 mult + 1 add = 5
tanh_val  = tanh(tanh_arg)                          # 1 op
dtanh     = 1.0 - tanh_val^2                        # 1 mult + 1 sub = 2
inner_grad= sqrt(2/pi) * (1.0 + 3*0.044715 * x^2)  # 3 mult + 1 add = 4
return 0.5*(1+tanh_val) + 0.5*x*dtanh*inner_grad    # 4 mult + 2 add = 6
```

**Per element: 18 FLOPs**

| Op | Description | Formula | FLOPs |
|----|-------------|---------|-------|
| (4) | `gelu_grad(h)` | 18 * N * F | 18 * 65,536 = 1,179,648 |
| (5) | `dh = dh_act * gelu_grad` | N * F | 65,536 |

**Elementwise subtotal: 1,245,184**

### Total FLOPs

```
Matmuls:      33,554,432
Reductions:       81,920
Elementwise:   1,245,184
─────────────────────────
Total:        34,881,536
```

## Bytes Transferred (No Reuse, All Loaded from DRAM)

Each operand is loaded from DRAM each time it is used. Each result is written to DRAM.
All values are float64 = 8 bytes per element.

| Op | Reads (elements) | Writes (elements) | Total elements |
|----|-------------------|--------------------|----------------|
| (1) `dout @ W2.T` | dout(N,D)=16,384 + W2(F,D)=16,384 | dh_act(N,F)=65,536 | 98,304 |
| (2) `h_act.T @ dout` | h_act(N,F)=65,536 + dout(N,D)=16,384 | dW2(F,D)=16,384 | 98,304 |
| (3) `db2 = sum(dout)` | dout(N,D)=16,384 | db2(D)=64 | 16,448 |
| (4) `gelu_grad(h)` | h(N,F)=65,536 | result(N,F)=65,536 | 131,072 |
| (5) `dh = dh_act * result` | dh_act(N,F)=65,536 + result(N,F)=65,536 | dh(N,F)=65,536 | 196,608 |
| (6) `x.T @ dh` | x(N,D)=16,384 + dh(N,F)=65,536 | dW1(D,F)=16,384 | 98,304 |
| (7) `db1 = sum(dh)` | dh(N,F)=65,536 | db1(F)=256 | 65,792 |
| (8) `dh @ W1.T` | dh(N,F)=65,536 + W1(D,F)=16,384 | dx(N,D)=16,384 | 98,304 |

```
Total elements:  803,136
Total bytes:     803,136 x 8 = 6,425,088 bytes
```

## Arithmetic Intensity

```
AI = FLOPs / Bytes
   = 34,881,536 / 6,425,088
   = 5.43 FLOPs/byte
```

## Interpretation

An arithmetic intensity of **5.43 FLOPs/byte** is relatively low, indicating that
`ff_backward` is **memory-bandwidth bound** — it spends more time moving data than
computing. This is driven by the gelu_grad activation (18 FLOPs/element but requires
full tensor reads/writes) and the small matrix dimensions (D=64, F=256) which do not
amortize DRAM access costs as effectively as larger matrices would.
