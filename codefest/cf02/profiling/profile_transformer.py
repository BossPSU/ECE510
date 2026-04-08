"""
Profile transformer.py: run forward+backward 10 times under cProfile.
Identifies the computationally dominant kernel.
"""

import cProfile
import pstats
import io
import sys
import numpy as np

# Add the directory containing transformer.py to the path
sys.path.insert(0, r"C:\Users\david\OneDrive\Documents\psu\510\GitHub\project")

from transformer import (
    init_params, forward, cross_entropy_loss, backward, get_batch
)

# Small model config matching transformer.py defaults
config = {
    "vocab_size": 65,
    "seq_len": 64,
    "d_model": 64,
    "n_heads": 4,
    "d_ff": 256,
    "n_layers": 2,
    "batch_size": 4,
}

NUM_RUNS = 1000

def run_forward_backward():
    """Single forward + backward pass."""
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

    for _ in range(NUM_RUNS):
        batch = get_batch(data, config["batch_size"], config["seq_len"], rng)
        logits, caches = forward(batch, params, config)
        loss, dlogits = cross_entropy_loss(logits, batch)
        grads = backward(dlogits, caches, params, config)


if __name__ == "__main__":
    profiler = cProfile.Profile()
    profiler.enable()
    run_forward_backward()
    profiler.disable()

    # Print to console
    stream = io.StringIO()
    stats = pstats.Stats(profiler, stream=stream)
    stats.strip_dirs()
    stats.sort_stats("cumulative")
    stats.print_stats(40)
    output = stream.getvalue()
    print(output)

    # Also save sorted by tottime
    stream2 = io.StringIO()
    stats2 = pstats.Stats(profiler, stream=stream2)
    stats2.strip_dirs()
    stats2.sort_stats("tottime")
    stats2.print_stats(40)
    output2 = stream2.getvalue()

    # Save full results
    report_path = r"C:\Users\david\OneDrive\Documents\psu\510\codefests\project\transformer_profile_results.txt"
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("=" * 80 + "\n")
        f.write(f"Transformer Profiling: {NUM_RUNS} forward+backward passes\n")
        f.write(f"Config: {config}\n")
        f.write("=" * 80 + "\n\n")
        f.write("--- Sorted by CUMULATIVE time ---\n\n")
        f.write(output)
        f.write("\n\n--- Sorted by TOTAL (self) time ---\n\n")
        f.write(output2)

    print(f"\nFull results saved to {report_path}")
