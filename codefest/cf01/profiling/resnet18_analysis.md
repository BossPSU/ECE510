# ResNet-18 Top 5 Layers by MAC Count

Single FP32 forward pass, input size: (1, 3, 224, 224)

| Rank | Layer Name | Location | MACs | Parameters |
|------|-----------|----------|------|------------|
| 1 | Conv2d: 1-1 (conv1) | 7x7, stride 2 | 118,013,952 | 9,408 |
| 2 | Conv2d: 3-42 (layer4.0.conv2) | 3x3, 512ch | 115,605,504 | 2,359,296 |
| 3 | Conv2d: 3-46 (layer4.1.conv1) | 3x3, 512ch | 115,605,504 | 2,359,296 |
| 4 | Conv2d: 3-49 (layer4.1.conv2) | 3x3, 512ch | 115,605,504 | 2,359,296 |
| 5 | Conv2d: 3-29 (layer3.0.conv2) | 3x3, 256ch | 115,605,504 | 589,824 |

> **Note:** 13 Conv2d layers share the same MAC count of 115,605,504. Ranks 2-5 are selected by descending parameter count as a tie-breaker.

**Total model MACs:** 1,814,083,944
**Total model parameters:** 11,689,512

---

## Most MAC-Intensive Layer: Conv2d 1-1 (conv1)

- **Input:** [1, 3, 224, 224], **Output:** [1, 64, 112, 112]
- **Kernel:** 7x7, stride 2, no bias
- **MACs:** 118,013,952

### Arithmetic Intensity (no reuse, all data loaded from DRAM, FP32)

Each element is FP32 = 4 bytes. Each MAC = 2 FLOPs (one multiply + one add).

**FLOPs:**

```
FLOPs = 2 x MACs = 2 x 118,013,952 = 236,027,904
```

**Bytes transferred:**

```
Input activations:  1 x 3 x 224 x 224   = 150,528 elements   x 4 bytes =   602,112 bytes
Weights:            64 x 3 x 7 x 7      =   9,408 elements   x 4 bytes =    37,632 bytes
Output activations: 1 x 64 x 112 x 112  = 802,816 elements   x 4 bytes = 3,211,264 bytes
                                                                Total   = 3,851,008 bytes
```

**Arithmetic Intensity:**

```
AI = FLOPs / Bytes = 236,027,904 / 3,851,008 = 61.29 FLOPs/byte
```
