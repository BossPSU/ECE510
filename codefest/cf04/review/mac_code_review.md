# MAC Code Review

## LLM sources

| File | LLM / Model | Interface |
|------|-------------|-----------|
| [../hdl/mac_llm_A.v](../hdl/mac_llm_A.v) | Claude Sonnet 4.6 | Claude Code VS Code extension |
| [../hdl/mac_llm_B.v](../hdl/mac_llm_B.v) | GPT 5.3            | Web interface |

Compilation attempts using Icarus Verilog (`iverilog`) in SystemVerilog 2012 mode.

Tool: `C:\iverilog\bin\iverilog.exe`
Flags: `-g2012`

## mac_llm_A.v

Command:
```
iverilog -g2012 -o mac_llm_A.out mac_llm_A.v
```

Output (verbatim):
```
```

Exit code: `0`

Result: **Pass** — no errors, no warnings.

## mac_llm_B.v

Command:
```
iverilog -g2012 -o mac_llm_B.out mac_llm_B.v
```

Output (verbatim):
```
```

Exit code: `0`

Result: **Pass** — no errors, no warnings.

## Summary

Both `mac_llm_A.v` and `mac_llm_B.v` compile cleanly under `iverilog -g2012`
with no errors or warnings emitted. The two files are functionally identical;
they differ only in the use of explicit `begin`/`end` blocks around the
single-statement branches of the `if`/`else` inside the `always_ff` block.

## Testbench Simulation (`mac_tb.v`)

Stimulus sequence:
1. Hold `rst=1` for one cycle to bring the accumulator to a known 0.
2. De-assert `rst` and apply `a=3, b=4` for 3 cycles.
3. Assert `rst` for one cycle.
4. De-assert `rst` and apply `a=-5, b=2` for 2 cycles.

Compile + run command (per DUT):
```
iverilog -g2012 -o mac_<X>_sim.out mac_llm_<X>.v mac_tb.v
vvp mac_<X>_sim.out
```

### mac_llm_A.v simulation output (verbatim)

```
=== MAC Testbench ===
 phase            | time(ns) | rst |   a |   b |        out
------------------+----------+-----+-----+-----+-----------
 init reset       |     6000 |  1  |   0 |   0 |          0
 a=3,b=4 cycle 1  |    16000 |  0  |   3 |   4 |         12
 a=3,b=4 cycle 2  |    26000 |  0  |   3 |   4 |         24
 a=3,b=4 cycle 3  |    36000 |  0  |   3 |   4 |         36
 assert rst       |    46000 |  1  |   3 |   4 |          0
 a=-5,b=2 cycle 1 |    56000 |  0  |  -5 |   2 |        -10
 a=-5,b=2 cycle 2 |    66000 |  0  |  -5 |   2 |        -20
=== End of simulation ===
mac_tb.v:68: $finish called at 66000 (1ps)
```

Compile exit code: `0`. Run exit code: `0`.

### mac_llm_B.v simulation output (verbatim)

```
=== MAC Testbench ===
 phase            | time(ns) | rst |   a |   b |        out
------------------+----------+-----+-----+-----+-----------
 init reset       |     6000 |  1  |   0 |   0 |          0
 a=3,b=4 cycle 1  |    16000 |  0  |   3 |   4 |         12
 a=3,b=4 cycle 2  |    26000 |  0  |   3 |   4 |         24
 a=3,b=4 cycle 3  |    36000 |  0  |   3 |   4 |         36
 assert rst       |    46000 |  1  |   3 |   4 |          0
 a=-5,b=2 cycle 1 |    56000 |  0  |  -5 |   2 |        -10
 a=-5,b=2 cycle 2 |    66000 |  0  |  -5 |   2 |        -20
=== End of simulation ===
mac_tb.v:68: $finish called at 66000 (1ps)
```

Compile exit code: `0`. Run exit code: `0`.

### Functional check

Expected accumulator values for the stimulus sequence:

| Phase            | Expected `out` | Observed (A) | Observed (B) |
|------------------|----------------|--------------|--------------|
| init reset       |              0 |            0 |            0 |
| a=3,b=4 cycle 1  |    0 + 12 = 12 |           12 |           12 |
| a=3,b=4 cycle 2  |   12 + 12 = 24 |           24 |           24 |
| a=3,b=4 cycle 3  |   24 + 12 = 36 |           36 |           36 |
| assert rst       |              0 |            0 |            0 |
| a=-5,b=2 cycle 1 |  0 + (-10)=-10 |          -10 |          -10 |
| a=-5,b=2 cycle 2 | -10+(-10)=-20  |          -20 |          -20 |

Both DUTs match expected behavior exactly and produce identical output.
# MAC Code Review — Issues Found

This review covers the two MAC implementations in [../mac_llm_A.v](../mac_llm_A.v)
and [../mac_llm_B.v](../mac_llm_B.v). The two files differ only in the use of
explicit `begin`/`end` around single-statement branches; both share the same
underlying issues described below.

Both files compiled and simulated correctly under `iverilog -g2012` (see
[../mac_code_review.md](../mac_code_review.md)). The issues below are about
language/tooling assumptions, defensive coding, and portability — not
behavioral bugs in the simulated waveform.

---

## Issue 1 — `.v` extension paired with SystemVerilog-only constructs

### (a) Offending lines

From `mac_llm_A.v` (and identically in `mac_llm_B.v`):

```systemverilog
module mac (
    input  logic               clk,
    input  logic               rst,
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [31:0] out
);

    always_ff @(posedge clk) begin
```

### (b) Why this is wrong / ambiguous

The files are saved with the `.v` extension, which most tools (Verilator,
Synopsys VCS, Cadence Xcelium, Vivado, Quartus, Synplify, etc.) treat as
**Verilog-2001/2005** by default. The bodies, however, use SystemVerilog-only
constructs:

- `logic` (SystemVerilog data type — not legal in Verilog-2001).
- `always_ff` (SystemVerilog — not legal in Verilog-2001).

In our build we had to pass the explicit `-g2012` flag to `iverilog` to
suppress errors. Without that flag the file fails to parse. Synthesis tools
that key the language standard off the file extension (e.g. Vivado's default
behavior for `.v` vs `.sv`) will reject the file. The specification document
itself says *"Synthesizable SystemVerilog"*, so the language is clear — only
the extension is wrong.

### (c) Corrected version

Either rename the files to `.sv`, or — if the `.v` extension is mandatory —
restrict the source to plain Verilog-2001 types:

```verilog
// mac_llm_A.sv  (preferred: rename file)
module mac (
    input  logic               clk,
    input  logic               rst,
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [31:0] out
);
    always_ff @(posedge clk) begin
        if (rst) out <= 32'sd0;
        else     out <= out + (a * b);
    end
endmodule
```

Or, keeping the `.v` extension but using legal Verilog-2001 syntax:

```verilog
// mac_llm_A.v  (Verilog-2001 fallback)
module mac (
    input                       clk,
    input                       rst,
    input  signed [7:0]         a,
    input  signed [7:0]         b,
    output reg signed [31:0]    out
);
    always @(posedge clk) begin
        if (rst) out <= 32'sd0;
        else     out <= out + (a * b);
    end
endmodule
```

---

## Issue 2 — Multiplication relies on context width propagation; relies on tool to sign-extend

### (a) Offending lines

```systemverilog
        end else begin
            out <= out + (a * b);
        end
```

(`mac_llm_B.v` lines 11–13; same expression at line 12 of `mac_llm_A.v`.)

### (b) Why this is ambiguous / fragile

The expression `a * b` is the product of two **8-bit signed** operands.
Per IEEE 1800 the result width is context-determined: because the surrounding
addition `out + (a * b)` and the LHS `out` are 32 bits, the multiplier
operands are conceptually sign-extended to 32 bits before the multiply.

In practice this corner of the LRM (signedness propagation through
parentheses, and the rule that a single unsigned operand makes the whole
expression unsigned) is one of the most common sources of silent bugs in
Verilog code. A few specific risks:

- If a future maintainer changes either `a` or `b` to `logic [7:0]`
  (dropping the `signed` keyword) — perhaps because the testbench drives
  hex values — the entire expression silently becomes **unsigned**, and
  `-5 * 2` will accumulate as `+506` instead of `-10`. There is no
  compile-time error.
- Lint tools (Verilator `-Wall`, Spyglass `W164`, etc.) flag implicit
  width changes on the RHS of `<=` even when they are LRM-legal.
- Some older synthesis flows do not fully implement signed multiplication
  via context propagation through parentheses and produce truncated
  intermediate results.

### (c) Corrected version — make width and signedness explicit

Drop the parentheses and let the expression sit in the addition context, but
explicitly cast the product to a 32-bit signed value so a future change to
operand signedness fails loudly:

```systemverilog
    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + 32'(signed'(a) * signed'(b));
        end
    end
```

Or, equivalently, use a named intermediate that carries the product width:

```systemverilog
    logic signed [15:0] product;
    assign product = a * b;            // 8s × 8s → 16s, no truncation

    always_ff @(posedge clk) begin
        if (rst) out <= 32'sd0;
        else     out <= out + 32'(product);   // explicit sign-extend to 32
    end
```

The 16-bit product width is the exact tight bound for the product of two
signed 8-bit values (`-128*-128 = +16384` fits in `[15:0]` signed).

---

## Issue 3 — No `` `default_nettype none `` directive

### (a) Offending lines

The first lines of both files:

```systemverilog
module mac (
    input  logic               clk,
```

(There is no `` `default_nettype none `` before the `module` keyword.)

### (b) Why this is a defensive-coding gap

Without `` `default_nettype none ``, any typo in a signal name silently
creates a 1-bit implicit wire. For a tiny module like this MAC the risk is
small, but it is a free safety check and is considered standard practice in
production RTL. For example, if someone later writes:

```systemverilog
        out <= out + (a * bb);   // typo: intended 'b'
```

… the code will compile and synthesize, with `bb` becoming an implicit
floating wire. With `` `default_nettype none `` in effect, the typo becomes
an immediate compile error.

### (c) Corrected version

Add the directive at the top of the file and restore the default at the
bottom (so the directive does not leak into other files compiled after this
one):

```systemverilog
`default_nettype none

module mac (
    input  logic               clk,
    input  logic               rst,
    input  logic signed [7:0]  a,
    input  logic signed [7:0]  b,
    output logic signed [31:0] out
);

    always_ff @(posedge clk) begin
        if (rst) out <= 32'sd0;
        else     out <= out + 32'(signed'(a) * signed'(b));
    end

endmodule

`default_nettype wire
```

---

## Summary

| # | Issue                                                  | Severity | Behavioral bug today? |
|---|--------------------------------------------------------|----------|-----------------------|
| 1 | `.v` extension with SystemVerilog-only constructs      | High     | No (tool-dependent failure mode) |
| 2 | Implicit width/sign propagation through `(a * b)`      | Medium   | No (correct under LRM, fragile under change) |
| 3 | Missing `` `default_nettype none ``                    | Low      | No (defensive only) |

Issue 1 will manifest the moment either file is dropped into a Vivado / VCS /
Verilator flow without a per-file language override. Issues 2 and 3 are
defensive — they harden the design against future edits and lint findings.

---

## Corrected Implementation — `mac_correct.v`

A revised implementation addressing all three issues lives at
[../hdl/mac_correct.v](../hdl/mac_correct.v). Trade-off note: because the
`.v` extension was retained, the file uses Verilog-2001 syntax (`always
@(posedge clk)`, `wire`/`reg`) instead of `always_ff` — per Issue 1's
secondary remediation path. The result is a file that parses under default
Verilog-2005 mode with no language-override flag.

### Lint pass (no `-g2012` flag — proves Issue 1 is fixed)

Command:
```
iverilog -o mac_correct_lint.out mac_correct.v
```

Output (verbatim):
```
```

Exit code: `0`. **Pass** — parses cleanly under default Verilog-2005 mode,
which the original `mac_llm_A.v` and `mac_llm_B.v` could not do.

### Testbench simulation against `mac_tb.v`

Command:
```
iverilog -g2012 -o mac_correct_sim.out mac_correct.v mac_tb.v
vvp mac_correct_sim.out
```

(`-g2012` is required here only because the testbench `mac_tb.v` itself uses
`logic`/`always` SV syntax — the DUT `mac_correct.v` does not need it.)

Output (verbatim):
```
=== MAC Testbench ===
 phase            | time(ns) | rst |   a |   b |        out
------------------+----------+-----+-----+-----+-----------
 init reset       |     6000 |  1  |   0 |   0 |          0
 a=3,b=4 cycle 1  |    16000 |  0  |   3 |   4 |         12
 a=3,b=4 cycle 2  |    26000 |  0  |   3 |   4 |         24
 a=3,b=4 cycle 3  |    36000 |  0  |   3 |   4 |         36
 assert rst       |    46000 |  1  |   3 |   4 |          0
 a=-5,b=2 cycle 1 |    56000 |  0  |  -5 |   2 |        -10
 a=-5,b=2 cycle 2 |    66000 |  0  |  -5 |   2 |        -20
=== End of simulation ===
mac_tb.v:68: $finish called at 66000 (1ps)
```

Compile exit code: `0`. Run exit code: `0`.

### Functional check vs. expected

| Phase            | Expected `out` | Observed (`mac_correct.v`) |
|------------------|----------------|----------------------------|
| init reset       |              0 |                          0 |
| a=3,b=4 cycle 1  |    0 + 12 = 12 |                         12 |
| a=3,b=4 cycle 2  |   12 + 12 = 24 |                         24 |
| a=3,b=4 cycle 3  |   24 + 12 = 36 |                         36 |
| assert rst       |              0 |                          0 |
| a=-5,b=2 cycle 1 |  0 + (-10)=-10 |                        -10 |
| a=-5,b=2 cycle 2 | -10+(-10)=-20  |                        -20 |

`mac_correct.v` matches expected behavior on every cycle and produces output
identical to the original `mac_llm_A.v` / `mac_llm_B.v`, while additionally:

- compiling under default Verilog-2005 mode (Issue 1 fixed),
- using a named 16-bit signed `product` and explicit `{{16{product[15]}},
  product}` sign extension to a 32-bit `product_ext` (Issue 2 fixed),
- declaring `` `default_nettype none `` at the top of the file (Issue 3
  fixed).
