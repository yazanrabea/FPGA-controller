# Questions for Dima — SIPO / PISO and chip interface (2026-10-22)

From: Yazan and Rahaf (project 10768, NEMO). Draft, not sent yet.

We have built the FPGA side of the SIPO load and PISO read and simulated it against your
RTL (`sipo.sv`, `sipo_wrapper.sv`, `piso.sv`), with the Tower cells stubbed. It works in
simulation with the timing below, but several choices are **our guesses** from the RTL. We
need your answers before we connect the chip. Numbers like Q1/Q6 match our open-question
list (`docs/controller_spec.md` §5).

## What we do now (please tell us if any of this is wrong)

**SIPO load (136 bits):**
1. `rst_sipo` low for 100 ns.
2. `clk_sipo`: 136 clock cycles at 1 MHz, starting high, so there are exactly 136 rising edges.
3. `sipo_in`: the 136-bit frame, bit 135 first. It changes on the **falling** edge of `clk_sipo`, so it is stable for half a period around each rising edge.
4. `cs`: one rising edge, 1 µs after the 136th `clk_sipo` rising edge (`clk_sipo` is already low again).

**PISO read (168 bits):**
1. `clk_piso`: 168 cycles at 1 MHz. Rising edge 1, with `shift` = 0, loads the stages.
2. `shift` goes to 1 in the low phase after edge 1 and stays 1 through edge 168, so edges 2–168 shift.
3. We sample `piso_out` on each **falling** edge of `clk_piso`. Falling edge 1 reads bit 1 before any shift edge.
4. We read the frame as PISO0 first, each stage as out1[13:0], tdc_out1[6:0], out0[13:0], tdc_out0[6:0].

## Questions

### A. SIPO

1. **(Q1, updated) What should `sel[23:8]` be before the first `phirst`?**
   In `sipo_wrapper.sv` the reset branch does `sel[23:8] <= parallel_out[23:8]` while `sipo.sv` resets `parallel_out` on the same `rst_n`. Both are nonblocking, so in simulation `sel[23:8]` gets the value from the **previous** load (0 only the first time). The slice 0 of the frame being loaded (bits [23:8]) never reaches `sel`. Is that intended? Should slice 0 be a dummy?
   Also: a reset branch that loads data instead of a constant is not a normal reset flip-flop. How did this synthesize, and does the silicon behave like the RTL here?
2. **(Q2) How many `phirst` cycles per inference?** `index` goes 24 → 40 → … → 136 and never wraps, so the 8th `phirst` reads past bit 135. Do we have to pulse `rst_sipo` and reload the full 136-bit frame before every inference?
3. **(Q3) Bit and slice order.** Which `sel` bit selects which row/column? What do the 8 bits of `sel[7:0]` select? Is slice k meant to be the k-th group of inputs in time?
4. **`sipo_in` timing.** Is changing `sipo_in` on the falling edge of `clk_sipo` right? What setup/hold does the SIPO need at the pad?
5. **`cs` timing.** Any minimum time between the last `clk_sipo` rising edge and `cs` rising, or a minimum `cs` pulse width? Must `cs` come before the first `phirst`?

### B. PISO

6. **Is our PISO sequence right?** Load with `shift` = 0 on edge 1, set `shift` = 1 while `clk_piso` is low, then 167 shift edges, sampling on falling edges.
7. **Delay from `clk_piso` to `piso_out`.** This includes clk-to-Q, the 4 × `DLY3_X4_18_SVT_WTN`, and the pad. Do you know roughly what it is? It sets our maximum `clk_piso`: we need high time ≥ 30 ns plus this delay. In simulation, 400 ns of delay still works at 1 MHz and 600 ns fails.
8. **(Q5) Column mapping.** Which physical column is `out0`/`out1` of each PISO stage? The pin sheet says `piso_in<13:0>` but the block diagram says `Dout<14:0>`. Is it 14 bits or 15?
9. Is `rst_piso` needed at all before a read, or does the load edge overwrite everything?

### C. Pins, levels, resets

10. **(Q6) Reset polarity at the pad.** Are `rst_sipo` / `rst_piso` active-low at the pad, as in the RTL?
11. **Power-up state.** From FPGA reset until our configuration is applied, the controller drives the chip's resets **low (asserted)** and every other input low. Is it safe to hold the chip in reset like that? Is there a required power-up order between the chip supply and the FPGA I/O? (We haven't checked yet what the pins do before the FPGA bitstream is loaded.)
12. **(Q7) Levels and speed.** Our FMC I/O is fixed at 1.8 V (LVCMOS18). Do the digital pads expect 1.8 V? What are the maximum safe `clk_sipo` / `clk_piso` / `clk` frequencies?
13. **(Q9) `rst_sipo` pad number.** It's pin 37 on "IO-Pins-Dima" but missing from "Blocks Interface - Digital" (pad 39 there is "Unused"). Which is right?

### D. Still open from before (short)

14. **(Q4)** We only supply `clk` and the phases are made on chip, right? At what frequency? How is `phirst` timed relative to `cs`?
15. **(Q6)** What do `reset`, `set`, `s0_p..s2_p`, `pulse` and `rst_dsa` do, and with what polarity?
16. **(Q10)** How wide is the DFT-per-ADC select (2, 3 or 4 bits)? Are `PISO_WR` and the stand-alone test structure still on this chip?
