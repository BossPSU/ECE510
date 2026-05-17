# CF07 — M3 Plan (Option A, project core)

**Change for M3: pipeline `mac_pe` between the 8×8 multiply and the
Q8.8→Q16.16 align/accumulate.**

Grounded in the synthesis numbers:

- OpenLane (Sky130A, typical corner) reports **WNS = +1.475 ns at 10 ns
  (f_max ≈ 117 MHz)**; the slow corner needs **~14.5 ns**.
  Cadence Genus on SAED32 (separate M3 sweep, 1 GHz target) reports
  WNS = **−560 ps**, i.e. **f_max ≈ 641 MHz on SAED32**.
- Both tools agree on the path shape: `a_in[*]` → quantize/saturate →
  8×8 multiply → align shift → accumulator flop, all combinational. The
  multiplier + adder accounts for **113 of 702 cells** (XOR/XNOR pairs).
- Splitting that path at the Q8.8 boundary cuts combinational depth
  roughly in half. Cost: 1 cycle of added MAC latency (acceptable in a
  systolic feed) and ~16 extra DFFs (≈400 µm² on Sky130,
  ≈3 % of current cell area).

For M3 I will:
1. Add `pipeline_q88_reg` between `product_q88` and `product_q` in
   `mac_pe.sv`.
2. Re-run the Genus sweep at the same N axis to confirm the WNS gap
   closes at 1 ns.
3. Update `timing_analysis.md` with the new per-N WNS curve.
