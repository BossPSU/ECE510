# GEMM Analysis: Naive vs. Tiled

## (a) Why the naive kernel is memory-bound

The naive kernel assigns one thread per output element, and each thread independently reads an entire row of A (1024 floats) and an entire column of B (1024 floats) from global memory. With no data sharing between threads, every element of A and B is loaded N = 1024 times across all threads, producing total DRAM traffic of 2N^3 x 4 = 8.59 GB for only 2N^3 = 2.15 GFLOPs of compute. This gives an arithmetic intensity of 0.25 FLOPs/byte — far below the RTX 3050 Ti's ridge point of 27.6 FLOPs/byte. On the roofline, the kernel sits deep in the memory-bound region. The measured 530 GFLOP/s exceeds the theoretical bandwidth ceiling (0.25 x 192 = 48 GFLOP/s) because the GPU's L2 cache (2 MB) captures significant reuse of B's columns, but performance remains well below the 5.3 TFLOP/s compute peak.

## (b) How tiling reduces DRAM traffic

The tiled kernel loads 8x8 tiles of A and B into shared memory, where all 64 threads in a block reuse each loaded element TILE = 8 times. Instead of each element being loaded N = 1024 times, it is loaded N/TILE = 128 times across all blocks. Total DRAM traffic drops to 2N^3/TILE x 4 = 1.07 GB — an 8x reduction matching the tile size. Arithmetic intensity increases from 0.25 to 2.0 FLOPs/byte.

## (c) Whether tiling achieved the expected improvement

Tiling reduced theoretical DRAM traffic by 8x and increased arithmetic intensity by 8x, yet measured throughput remained nearly identical (530 vs 528 GFLOP/s). The tiled kernel did **not** achieve the expected speedup. The remaining bottleneck is likely L2 cache effectiveness: the naive kernel already benefits from substantial L2 reuse (B's columns fit partially in the 2 MB L2), so the gap between actual naive traffic and theoretical naive traffic is much smaller than 8x. Additionally, the TILE=8 configuration uses only 64 threads per block, which underutilizes the SM's warp schedulers and limits occupancy. A larger tile (e.g., 16 or 32) would improve both reuse ratio and occupancy.
