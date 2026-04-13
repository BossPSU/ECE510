# HW/SW Partition Proposal

## (a) Kernel Selected for Hardware Acceleration

The feed-forward backward pass (`ff_backward`) will be accelerated in hardware, along with its dominant sub-kernel `gelu_grad`. Profiling over 1,000 iterations shows `ff_backward` accounts for 32.5% of total compute by cumulative time, with `gelu_grad` alone consuming 18.1% by self-time. The feed-forward block overall (forward + backward) represents 56% of runtime. The roofline analysis confirms this kernel is memory-bound on the i5-10500H at an arithmetic intensity of 5.43 FLOPs/byte, achieving only 139 GFLOP/s against a 432 GFLOP/s compute ceiling. This means the kernel is bottlenecked by the CPU's 25.6 GB/s single-channel DRAM bandwidth, making it an ideal candidate for a hardware accelerator with high on-chip memory bandwidth.

## (b) Software Baseline

The host CPU will continue to handle embedding lookups, loss computation, the Adam optimizer, data loading, and control flow. These collectively account for less than 5% of runtime and involve irregular memory access patterns (e.g., `np.add.at` for embedding gradients) that do not benefit from systolic acceleration. Layer normalization (forward and backward) remains on the CPU as well, representing ~11% of compute but operating on small tensors where accelerator dispatch overhead would negate any gains.

## (c) Interface Bandwidth Requirement

The accelerator targets 1,390 GFLOP/s on `ff_backward`. At AI = 5.43 FLOPs/byte, this requires 1,390 / 5.43 = 256 GB/s of sustained data throughput. The on-chip SRAM bus provides this internally. For the host-to-accelerator interface, each invocation transfers 6,425,088 bytes of operands. At 2,000 calls per training step (2 layers x 1,000 iterations), the interface must sustain at least 6,425,088 x 2 / (target latency per step) — approximately 3.2 GB/s for a 4 ms per-call budget. A UCIe x16 link at 4 GT/s (8 GB/s bidirectional) is sufficient and avoids becoming interface-bound, with 2.2x headroom.

## (d) Compute-Bound vs. Memory-Bound

On the current i5-10500H, the kernel is **memory-bound**: AI of 5.43 falls well below the ridge point of 16.9 FLOPs/byte, so DRAM bandwidth (25.6 GB/s) limits throughput rather than compute. The proposed accelerator with 256 GB/s on-chip SRAM delivers 10x higher bandwidth while scaling compute to 4.096 TFLOP/s, maintaining a ridge point of 16.0 FLOPs/byte. The kernel remains memory-bound on the accelerator (5.43 < 16.0), but the 10x bandwidth increase translates directly to a 10x performance gain. Shifting the kernel to compute-bound would require either increasing arithmetic intensity through algorithmic changes (e.g., operator fusion, tiling for data reuse) or reducing precision to FP32, which would halve bytes transferred and double effective AI to ~10.9 FLOPs/byte.
