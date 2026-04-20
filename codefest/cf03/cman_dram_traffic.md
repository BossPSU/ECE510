# DRAM Traffic Analysis

## Part A

- A and B are accessed for every k value from k=N-1 to k=0.
- N = 32, so each element of A and B are accessed 32 times.
- i and j are both equal to N (32), so both A and B are accessed i * j * k (N^3) times.
- Total element accesses to A and B = 2N^3 = 2 * 32^3 = 65536
- Each access moves 4 bytes, so total traffic = 65536 * 4 = 262,144 bytes = 256 KiB

## Part B

- When T = 8, 32 x 32 (N x N) matrix is split into 4x4 (16 total) tiles each of size 8 x 8.
- A and B accessed only once, so total tiles loads is 16 + 16 = 32.
- Each tile has 8 x 8 = 64 elements and each element is 4 bytes, so each tile is 64 * 4 = 256 bytes.
- Total DRAM traffic = 32 * 256 = 8192 bytes = 8 KiB.

## Part C

- Ratio is equal to naive traffic / tile traffic = 262144 / 8192 = 32.
- Naive traffic loads each element N times (N^3) while tiled loads each element only once (N^2). This results in a ratio of N.

## Part D

- Total work = 2N^3 = 65536 FLOPs
- 10 TFLOPs = 10 * 10^12 FLOP/s
- Compute time = total work / compute = 65536 / (10 * 10^12) = 6.55 ns

### Naive case

- Traffic / bandwidth = 262144 / (320 * 10^9) = 819.2 ns
- **Memory bound**

### Tiled case

- Traffic / bandwidth = 8192 / (320 * 10^9) = 25.6 ns
- **Memory bound**
