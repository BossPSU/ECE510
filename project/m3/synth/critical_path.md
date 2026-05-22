# M3 OpenLane critical path -- `mac_pe` leaf

The OpenLane 2 run committed alongside this file (`openlane_run.log`,
`timing_report.txt`, `area_report.txt`, `power_report.txt`) synthesized
the **mixed-precision `mac_pe` processing element** -- the leaf cell that
the 65,536-PE chip is built from. Source: [`synth_top.sv`](synth_top.sv)
(the same self-contained inline of [`project/m2/rtl/mac_pe.sv`](../../m2/rtl/mac_pe.sv)
used for the CF07 deliverable). See [`../synthesis_notes.md`](../synthesis_notes.md)
for why the leaf was synthesized rather than the full integrated `top.sv`.

## Start / end points and the logic stages between them

**Typical corner (`nom_tt_025C_1v80`)** -- the worst path that closes
positive slack:

```
Startpoint:  a_in[15]   (primary input port, clocked by clk)
Endpoint:    _1299_     (rising-edge DFF, the Q16.16 accumulator register)
Path group:  clk
WNS:         +1.475 ns at a 10.0 ns target  (MET)
```

**Slow corner (`nom_ss_100C_1v60`, 12 % undervolt + 100 degC + slow-process)**
fails the same path:

```
WNS:         -4.499 ns at a 10.0 ns target  (VIOLATED, 45 % over budget)
```

## Why this path is the critical one

`mac_pe` has a **single combinational chain from operand pin to the
accumulator flop**, fed once per cycle. There is no internal pipelining.
That chain is the logic stages enumerated below; every other path in
the module is shorter.

```
   a_in[15] (input port)
        |
        |   1. Q16.16 -> Q4.4 quantize  (>>> 12, with sat to +/-7.9375/-8.0)
        v
   a_q44[7:0]
        |
        |   2. 8x8 signed multiply       (Q4.4 * Q4.4 -> Q8.8)
        v
   product_q88[15:0]
        |
        |   3. Q8.8 -> Q16.16 align      (sign-extend + <<8)
        v
   product_q[31:0]
        |
        |   4. Q16.16 accumulator add    (acc_r + product_q)
        v
   _1299_  (DFF, acc_r register)
```

Stages 1-3 are pure combinational; stage 4 is the final add that feeds
the flop. The b-side mirror path (`b_in[*] -> b_q44 -> product_q88 ->
... -> _1299_`) has identical depth and is the symmetric variant of the
same logical path. The reported timer worst is `a_in[15]` (the MSB of
the integer part of `a_in`, where saturation control kicks in).

Post-techmap statistics confirm the shape: 113 XOR/XNOR cells dominate
(multiplier sum/propagate logic + adder carry chain), 68 nor2/xnor2
cells tied as the next group, 65 mux2_1 cells (the saturation and
`clear_acc` MUXes), 88 `dfrtp_2` flops (the Q16.16 accumulator + the
west/north operand forwarding registers). The combinational portion is
~72 % of cell area; sequential ~28 %.

## What would shorten it

The dominant delay component is the **8x8 multiplier carry/sum
network** plus the **32-bit accumulator add** -- both single-cycle
combinational. Two ways to shave the path:

1. **Pipeline `mac_pe`** between `product_q88` (the multiplier output)
   and `product_q` (the aligned/promoted operand into the adder). One
   added flop, splitting the chain at its midpoint. Halves the
   combinational depth roughly. Cost: +1 cycle of MAC latency
   (amortized across long systolic dot products -- a 64-element inner
   reduces by ~1.6 %). This is the M3 RTL fix flagged in
   [`../../../codefest/cf07/synth/m3_plan.md`](../../../codefest/cf07/synth/m3_plan.md).

2. **Derate** to a slower clock at slow PVT. At -4.499 ns over 10 ns,
   the achievable period at SS is ~14.5 ns -> ~69 MHz, a **31 %
   throughput tax** vs the typical-corner 117 MHz f_max. Acceptable
   only if the part is binned for typical-corner deployment;
   unacceptable for a chiplet that may see SS PVT in worst-case
   thermal scenarios.

Path #1 is the right fix and is in the M3 plan. Path #2 is the
fallback. Both are documented in [`../synthesis_notes.md`](../synthesis_notes.md)
under the M4 forward-look.

## Scaling implication for the chip

`mac_pe` is the building block of the 64x64 systolic array, and every
PE in the chip has this same combinational chain. So the per-PE
critical path **is** the chip's per-PE critical path: 16 lanes x 4,096
PEs = 65,536 instances all pay the same -4.499 ns SS gap. Closing it
once (via the pipeline insertion) closes it everywhere. That's what
makes this leaf-level critical path representative of the chip-level
timing story -- with the important caveat (raised in
[`../synthesis_notes.md`](../synthesis_notes.md)) that the chip's
worst path is **not** in `mac_pe`. The Genus per-block sweep
identifies `softmax_unit`'s combinational divider as the actual
chip-level WNS bottleneck (-19,080 ps at the same 1 ns target). M4
addresses the softmax divider; M3's leaf path is the second-worst.
