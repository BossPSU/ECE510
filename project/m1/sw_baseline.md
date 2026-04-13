# Software Baseline Benchmark

## Platform and Configuration

| Parameter | Value |
|-----------|-------|
| CPU | Intel Core i5-10500H (6 cores / 12 threads, 2.5 GHz base, 4.5 GHz boost) |
| RAM | 8 GB DDR4-3200, single-channel |
| OS | Windows 11 Home 10.0.26200 |
| Python | 3.13.12 |
| NumPy | (system default, pure CPU) |
| Precision | float64 (8 bytes per element) |

## Model Configuration

| Parameter | Value |
|-----------|-------|
| vocab_size | 65 (character-level) |
| seq_len | 64 |
| d_model | 64 |
| n_heads | 4 |
| d_ff | 256 |
| n_layers | 2 |
| batch_size | 4 |
| Tokens per iteration | 256 (4 x 64) |

## Execution Time

Measured over 100 runs (after 5 warmup iterations). Each run is a full forward + backward pass.

| Metric | Value |
|--------|-------|
| Median | 35.317 ms |
| Mean | 37.145 ms |
| Std | 5.010 ms |
| Min | 30.483 ms |
| Max | 54.869 ms |

## Throughput

| Metric | Value |
|--------|-------|
| Samples/sec | 113.3 |
| Tokens/sec | 7,249 |
| FLOP/s | 3.398 GFLOP/s |

The 3.4 GFLOP/s measured throughput is consistent with the profiling data in `codefest/cf02/profiling/project_profile.txt`, which showed 41.6 seconds for 1,000 full iterations (~41.6 ms/iter mean including cProfile overhead). The dominant kernel `ff_backward` accounts for 32.5% of this runtime (see `codefest/cf02/analysis/ai_calculation.md`), achieving only 139 GFLOP/s attainable on the CPU roofline — limited by the 25.6 GB/s single-channel DRAM bandwidth at an arithmetic intensity of 5.43 FLOPs/byte.

## Memory Usage

| Metric | Value |
|--------|-------|
| Peak RSS (tracemalloc) | 14.7 MB |

This includes all model parameters (11 weight matrices, biases, embeddings), intermediate activations cached for the backward pass, and gradient tensors. The small footprint reflects the compact model size (d_model=64, 2 layers) and confirms the workload fits entirely in the CPU's L3 cache (12 MB on the i5-10500H), though profiling shows the kernel is still memory-bandwidth bound due to lack of explicit data reuse in the NumPy implementation.

## Reproducibility

To reproduce this benchmark:

```bash
cd project/m1/
python benchmark.py
```

The benchmark script uses `time.perf_counter()` for wall-clock timing, `tracemalloc` for memory tracking, and a fixed random seed (`rng = np.random.default_rng(42)`). The transformer implementation is at `codefest/cf02/profiling/transformer.py`.
