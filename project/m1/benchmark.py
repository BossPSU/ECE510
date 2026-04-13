"""
Software baseline benchmark for transformer forward+backward pass.
Measures wall-clock time, throughput, and peak memory over 100 runs.
"""

import time
import tracemalloc
import numpy as np
import sys
sys.path.insert(0, r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\codefest\cf02\profiling")

from transformer import init_params, forward, cross_entropy_loss, backward, get_batch

config = {
    "vocab_size": 65,
    "seq_len": 64,
    "d_model": 64,
    "n_heads": 4,
    "d_ff": 256,
    "n_layers": 2,
    "batch_size": 4,
}

NUM_RUNS = 100
FLOPS_PER_ITER = 34_881_536  # ff_backward only (dominant kernel)
# Total FLOPs per full forward+backward iteration (estimated from all functions):
# forward matmuls + backward matmuls + activations ~ 2x ff_backward FLOPs for full model
# More precisely: sum all layer FLOPs analytically
# ff_forward + ff_backward = ~70M FLOPs (2 layers)
# mha_forward + mha_backward = ~40M FLOPs (2 layers)
# layer_norm + softmax + loss ~ 10M FLOPs
# Total ~ 120M FLOPs per iteration
TOTAL_FLOPS_PER_ITER = 120_000_000  # approximate total for full fwd+bwd

params = init_params(
    vocab_size=config["vocab_size"],
    seq_len=config["seq_len"],
    d_model=config["d_model"],
    n_heads=config["n_heads"],
    d_ff=config["d_ff"],
    n_layers=config["n_layers"],
)
rng = np.random.default_rng(42)
data = rng.integers(0, config["vocab_size"], size=1000, dtype=np.int32)

# Warmup
for _ in range(5):
    batch = get_batch(data, config["batch_size"], config["seq_len"], rng)
    logits, caches = forward(batch, params, config)
    loss, dlogits = cross_entropy_loss(logits, batch)
    grads = backward(dlogits, caches, params, config)

# Timed runs
times = []
tracemalloc.start()
peak_mem = 0

for i in range(NUM_RUNS):
    batch = get_batch(data, config["batch_size"], config["seq_len"], rng)

    t0 = time.perf_counter()
    logits, caches = forward(batch, params, config)
    loss, dlogits = cross_entropy_loss(logits, batch)
    grads = backward(dlogits, caches, params, config)
    t1 = time.perf_counter()

    times.append(t1 - t0)
    _, current_peak = tracemalloc.get_traced_memory()
    peak_mem = max(peak_mem, current_peak)

tracemalloc.stop()

times = np.array(times)
median_time = np.median(times)
mean_time = np.mean(times)
std_time = np.std(times)
min_time = np.min(times)
max_time = np.max(times)

tokens_per_iter = config["batch_size"] * config["seq_len"]  # 256 tokens
samples_per_iter = config["batch_size"]  # 4 samples

throughput_samples = samples_per_iter / median_time
throughput_tokens = tokens_per_iter / median_time
throughput_flops = TOTAL_FLOPS_PER_ITER / median_time

print(f"=== Software Baseline Benchmark ===")
print(f"Runs: {NUM_RUNS} (after 5 warmup)")
print(f"")
print(f"Wall-clock time per iteration:")
print(f"  Median: {median_time*1000:.3f} ms")
print(f"  Mean:   {mean_time*1000:.3f} ms")
print(f"  Std:    {std_time*1000:.3f} ms")
print(f"  Min:    {min_time*1000:.3f} ms")
print(f"  Max:    {max_time*1000:.3f} ms")
print(f"")
print(f"Throughput:")
print(f"  {throughput_samples:.1f} samples/sec")
print(f"  {throughput_tokens:.0f} tokens/sec")
print(f"  {throughput_flops/1e6:.1f} MFLOP/s ({throughput_flops/1e9:.3f} GFLOP/s)")
print(f"")
print(f"Memory:")
print(f"  Peak RSS (traced): {peak_mem / 1024 / 1024:.1f} MB")
print(f"")
print(f"Config: {config}")
print(f"Tokens per iteration: {tokens_per_iter}")
print(f"Precision: float64 (8 bytes)")
