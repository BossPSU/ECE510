# Interface Selection: UCIe

## Choice

**UCIe (Universal Chiplet Interconnect Express)** is selected as the die-to-die interface between the host CPU and the systolic array accelerator chiplet.

## Host Platform

The assumed host platform is a **laptop SoC package** integrating the Intel i5-10500H CPU die and the accelerator chiplet on a shared organic substrate. UCIe is designed specifically for this chiplet-to-chiplet integration within a multi-die package, as standardized by the UCIe Consortium (UCIe 1.1 specification, 2023).

## Bandwidth Requirement Calculation

From the arithmetic intensity analysis (`codefest/cf02/analysis/ai_calculation.md`), each `ff_backward` invocation transfers:

```
Total data per call = 6,425,088 bytes (803,136 elements x 8 bytes, float64)
```

The accelerator targets 1,390 GFLOP/s throughput on this kernel. At AI = 5.43 FLOPs/byte (`codefest/cf02/analysis/ai_calculation.md`), the required data feed rate is:

```
Required BW = Throughput / AI
            = 1,390 GFLOP/s / 5.43 FLOP/byte
            = 256 GB/s
```

This 256 GB/s is the **on-chip SRAM bandwidth** requirement, handled internally by the accelerator's wide SRAM bus.

For the **host-to-accelerator interface**, data must be transferred at the beginning and end of each kernel invocation. Per call:

```
Interface data = inputs + outputs
               = (dout + W2 + h_act + h + x + W1) + (dh_act + dW2 + db2 + dh + dW1 + db1 + dx)
               = 6,425,088 bytes total

Target kernel latency = 34,881,536 FLOPs / 1,390 GFLOP/s = 0.025 ms

Required interface BW = 6,425,088 bytes / 0.025 ms = 256 GB/s
```

However, the accelerator's on-chip SRAM can buffer operands across calls. With double-buffering (loading the next call's inputs while computing the current call), the interface bandwidth requirement relaxes to matching the kernel's sustained invocation rate rather than single-call latency:

```
Sustained rate = 2 calls/iteration x 1 iteration/35.3 ms = 56.7 calls/sec
Sustained BW   = 56.7 x 6,425,088 bytes = 364 MB/s = 0.36 GB/s (minimum)
```

With a 10x acceleration target (3.53 ms/iteration):

```
Accelerated BW = 56.7 x 10 x 6,425,088 bytes = 3.6 GB/s
```

## UCIe Rated Bandwidth

UCIe standard-package (organic substrate) specifications:

| Configuration | Bandwidth (per module) |
|---------------|----------------------|
| UCIe x16, 4 GT/s | 4 GB/s per direction |
| UCIe x16, 8 GT/s | 8 GB/s per direction |
| UCIe x16, 12 GT/s | 12 GB/s per direction |
| UCIe x64, 4 GT/s | 16 GB/s per direction |

Source: UCIe 1.1 Specification, UCIe Consortium, 2023.

A single **UCIe x16 module at 4 GT/s** provides **4 GB/s per direction (8 GB/s bidirectional)**, which exceeds the 3.6 GB/s sustained requirement with comfortable margin. At the 10x accelerated operating point, the interface utilizes 3.6 / 8.0 = **45% of available bandwidth**, so the design is **not interface-bound**.

## Bottleneck Analysis

| Bandwidth | Value | Status |
|-----------|-------|--------|
| Required (sustained, 10x accel) | 3.6 GB/s | -- |
| UCIe x16 bidirectional | 8.0 GB/s | 2.2x headroom |
| On-chip SRAM internal | 256 GB/s | Separate bus |

The accelerator is **not interface-bound** on UCIe. The roofline bottleneck remains on-chip memory bandwidth (256 GB/s SRAM), not the die-to-die link. UCIe's low latency (~2 ns for die-to-die vs ~100+ ns for PCIe) also reduces per-call dispatch overhead, which matters at the accelerated call rate of ~567 calls/sec.

## Why UCIe Over PCIe

UCIe is preferred over PCIe for this design because:

1. **Chiplet integration**: The accelerator is designed as a companion chiplet on the same package substrate, not a discrete add-in card. UCIe is purpose-built for this topology.
2. **Latency**: UCIe die-to-die latency is ~2 ns, vs ~500 ns-1 us for PCIe (including protocol overhead). At 567 kernel calls/sec, PCIe's per-transaction overhead would consume ~0.5 ms/sec — small but unnecessary.
3. **Power efficiency**: UCIe achieves ~0.5 pJ/bit on organic substrate vs ~5-15 pJ/bit for PCIe, which matters in a laptop thermal envelope.
4. **Bandwidth density**: UCIe provides higher bandwidth per mm of edge, allowing a compact chiplet footprint.
