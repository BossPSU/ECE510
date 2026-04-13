Heilmeier Questions

1. What are you trying to do? Articulate your objectives using absolutely no jargon.

I want to speed up the slowest part of training a transformer neural network — specifically the feed-forward backward pass and its GELU activation gradient — by designing a custom chip optimized for that calculation. Profiling identified this single kernel (`ff_backward`, including `gelu_grad`) as the most demanding part of the workload, consuming 32.5% of total runtime. The custom chip will use a grid of 4,096 multiply-and-add units and fast on-chip memory to run this kernel roughly 10 times faster than my laptop's CPU.

2. How is it done today, and what are the limits of current practice?

Today the transformer runs in pure NumPy on an Intel i5-10500H CPU (6 cores, single-channel DDR4-3200). Profiling over 1,000 training iterations shows the feed-forward block (forward + backward) accounts for 56% of total compute time, with `gelu_grad` alone at 18.1% and `ff_backward` at 32.5% by cumulative time. The kernel achieves only 139 GFLOP/s out of a theoretical 432 GFLOP/s peak because the arithmetic intensity is 5.43 FLOPs/byte — well below the ridge point of 16.9 FLOPs/byte. The CPU's single-channel DRAM bandwidth of 25.6 GB/s is the bottleneck, not its compute units. Data is reloaded from main memory repeatedly with no on-chip reuse, and the number of parallel multiply operations is limited to what six CPU cores with AVX2 can sustain.

3. What is new in your approach and why do you think it will be succesful?

The new approach is a 64x64 systolic array accelerator running at 500 MHz with 256 GB/s of on-chip SRAM bandwidth — 10 times the CPU's DRAM bandwidth. The roofline analysis shows that at AI = 5.43 FLOPs/byte, the kernel is memory-bound on both platforms, so the 10x bandwidth increase translates directly to a 10x throughput gain (139 GFLOP/s to 1,390 GFLOP/s). Moving data storage onto the chip next to the compute units eliminates the DRAM round-trip that currently limits performance. The systolic array dimensions (64x64) are chosen to match the model's d_model=64, allowing full matrix rows to be processed in a single pass without tiling overhead. The accelerator chiplet connects to the host CPU die via a UCIe x16 link at 4 GT/s (8 GB/s bidirectional), which exceeds the 3.6 GB/s sustained interface bandwidth requirement without becoming interface-bound.
