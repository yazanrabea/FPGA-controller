# EXP-12: the sampler inside `chip_top` / `vchip_top` on the board

The in-FPGA sampler proven on the loopback bench (EXP-11) is now part of the chip
controller (`chip_top` `SAMPLER = 1`, decided 2026-11-02, `docs/decisions.md`). This
experiment checks it on the board with `vchip_top`, whose answers are known (EXP-08 / EXP-09):
the 22 controller outputs, the virtual chip's `sipo_out` / `piso_out` and the step number,
recorded during one whole run and read back over JTAG.

**Status: PASS** [measured on board] 2026-11-02: Part A (`vchip_top`, 10 jumpers) and Part B
(`chip_top`, no jumpers, recorded at the pads). [simulated] `chip_top_tb` 21/21 (check 8: every sample = the pins at
the PC's tick, exact; a 1-FF mutant caught), `vchip_top_tb` 9/9; pytest 391.

## 1. Setup
- **Bitstreams** (2026-11-02, 15:08-15:28): `chip_top` WNS +0.095 / WHS +0.010 ns, 18,001 LUT /
  23,807 FF / 8 BRAM; `vchip_top` WNS +0.161 / WHS +0.027 ns, 18,121 LUT / 24,270 FF / 8 BRAM;
  0 critical warnings.
- **Sample** (32 bits): 0-21 the 22 outputs as read back (`vchip_top`: from the output
  registers, `PAD_READBACK = 0`; `chip_top`: at the pads), 22-25 the 4 chip outputs, 26-29 the
  step. Samples at 0x8000 (`docs/link_register_map.md`).
- **Board:** J18 on 1V8, J17. Order: **no jumpers -> program -> the 10 EXP-08 jumpers**
  (J3-3..9 -> J2-20..26, J3-13 -> J2-27, J2-28 -> J3-16, J2-29 -> J2-17).
- **Sequence:** `config/exp09_verify_vchip.yaml` (EXP-08's: 5 us idle, 145 us SIPO load of
  `0x5AA5…E7E7`, PISO read of 168 bits ending on the capture).

## 2. Procedure (from `tools/`)
1. `python -m nemo_ctl.cli seq load ../config/exp09_verify_vchip.yaml --jtag`
2. `python -m nemo_ctl.cli seq sample --jtag --rate 10MHz --samples 3300 --run --wait 5
   --check ../config/exp09_verify_vchip.yaml --out exp12_a.vcd` (the file's `target: chip_top`
   selects the chip layout) -> the 22 outputs PASS against the waves the steps predict; the 4
   chip outputs shown.
3. `python -m nemo_ctl.cli seq read piso_out --jtag --target chip_top` -> the capture cell's
   frame, and the same frame decoded from the record (piso_out at each clk_piso falling edge).

## 3. Results (2026-11-02, lab PC, Rahaf at the bench), [measured on board]

| Time | What | Result |
|---|---|---|
| 15:31:27 | programmed `vchip_top` (no jumpers) | DONE=1; link idle; `sampler_info` = **32 bits x 4096** (the new build) |
| 15:37:09 | run 1 (Rahaf: 10 jumpers on) | 22 outputs **PASS** (22 pass, 0 fail); **`piso_out` 0 edges**; `seq read piso_out` = capture 0x0, 0 edges: J2-17 saw nothing. Cause: the J2-29 -> J2-17 jumper not connected (the wire pulled for EXP-09 step 5); Rahaf re-seated it. Exit code 1 although all judged rows passed (see Problems) |
| 15:39:18 | run 2 | **22 pass, 0 fail, 5 not judged**; record 3196 samples (-10 ns .. 319.49 us), triggered; `sipo_out` 64 edges, **`piso_out` 70 edges**; capture = **`0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6`** |

Run 2 in the record (`docs/measurements/EXP-12_vchip_record.vcd`, drawing `.svg`):
- steps seen in the step bits: 1 at 4.99 us, 2 at 149.99 us (= the table: 5 us, then 145 us).
- `clk_sipo` 272 edges (136 cycles) from 7.09 us, `sipo_in` 64 edges, `cs` 145.09 -> 146.09 us,
  `clk_piso` from 152.09 us, `shift` rises at 152.79 us; the 15 static pins and
  `reset` / `rst_sipo` / `rst_piso` never move. All equal to the predicted waves (tolerance 2
  samples + 20 ns).
- **`piso_out` read at each `clk_piso` falling edge in the record = the first 167 bits of the
  frame, exactly** (`frame >> 1`). The 168th falling edge is the capture that ends the
  sequence; the sampler sees the pins 2 FFs late and stops with the run, so that last edge
  isn't in the record (the capture cell has all 168). A short hold step after the read would
  show it.
- `sipo_out` follows `sipo_in` one clock later during the load (the SIPO's serial output) and
  ends at 1 (EXP-08/09: level 1).

Problems / fixes:
- Run 1: the `piso_out` jumper open (bench). Seen both by the record (flat) and by the capture
  cell (0x0); the sampler pointed at the wire, not at the design.
- `seq sample` exited 1 when every judged row passed: the run (320 us) ended before the
  requested 3300 samples (330 us), so the record was "triggered", not "done", and the CLI
  required "done". Fixed: a triggered record counts (`cli.py`, test
  `test_a_record_the_run_ended_early_still_passes`).

### Part B: `chip_top`, no jumpers (recorded at the pads)
| Time | What | Result |
|---|---|---|
| 15:47:03 | Rahaf: jumpers off; programmed `chip_top` | DONE=1; link idle; sampler 32 x 4096 |
| 15:47:53 | `seq load ../config/chip_sim_test.yaml --jtag`; `seq sample --jtag --rate 10MHz --samples 3300 --run --wait 5 --check ../config/chip_sim_test.yaml --out exp12_b.vcd` | **PASS: 22 pass, 0 fail, 5 not judged, exit 0**; record 3196 samples (-10 ns .. 319.49 us), triggered; steps 1 at 4.99 us, 2 at 149.99 us |

- The 22 outputs **as read back at their pads** (IOBUF -> 2 FFs): `clk_sipo` 272 edges from
  7.09 us, `sipo_in` 64, `cs` 145.09 -> 146.09 us, `clk_piso` 335 from 152.09 us, `shift` up at
  152.79 us, `reset` / `rst_sipo` / `rst_piso` held at 1, the other 14 at 0: equal to the
  predicted waves and to Part A (same times to the sample).
- **`sipo_in` read at each `clk_sipo` rising edge in the record = `0x5AA55A0FF0123456789ABCDEF0C3C3E7E7`,
  all 136 bits** (the chip's sampling edge), decoded from the pad record.
- The 4 chip inputs stay 0 (nothing connected, PULLDOWN).
- Files: `docs/measurements/EXP-12_chip_top_pads_record.vcd` / `.svg`.

### Part C: `chip_top`'s 4 inputs capture known signals (loopback jumpers, 16:16)
Rahaf asked to check that the input captures work without a chip. With `chip_top` loaded (no
jumpers when programmed), 4 jumpers from `chip_top` outputs to its inputs (output -> input,
safe; nothing on J2-20..25): J3-1 (`reset`, held HIGH) -> J3-16 (`sipo_out`, LEVEL); J3-8
(`shift`, rises 2.7 us into the PISO read, after clk_piso's first falling edge) -> J2-17
(`piso_out`, SERIAL 168 on clk_piso falling); J3-4 (`clk_sipo`) -> J2-18 (`dft0_buff`, PERIOD);
J3-7 (`clk_piso`) -> J2-19 (`dft1_buff`, PERIOD). `verify --seq ../config/chip_sim_test.yaml --jtag`:

| Input | Measured | Predicted |
|---|---|---|
| `sipo_out` (J3-16) | level 1 | 1 |
| `piso_out` (J2-17) | capture `0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF` | first bit 0, then 167 ones (MSB first) |
| `dft0_buff` (J2-18) | period 100 ticks | 100 (1 MHz) |
| `dft1_buff` (J2-19) | period 100 ticks | 100 |

Run PASS, exit 0; readback unchanged (sipo_in frame bit-exact). Edges read 0 (cleared when the
run ends, as `cap_cell` does) and `piso_out`'s level 0 is `shift` back at idle after the run.
All four chip-output inputs of `chip_top` (LA16-19) capture correctly on the board: LEVEL,
SERIAL (168 bits, bit order right) and PERIOD.

**The same from the editor (Rahaf, INFERENCE mode, Verify, ~16:40).** First all four read 0:
the mode had no capture on `dft0_buff` / `dft1_buff`, an editor Save (15:52) had set
`piso_out`'s edge to `rising` (refused by `chip_top`), and in INFERENCE `reset` / `shift` are
back LOW when the captures are read. Fixed in `config/nemo_config.yaml`: `piso_out` edge
falling, `dft0_buff` / `dft1_buff: {type: CAPTURE, mode: period}`. Jumpers moved to sources that
are HIGH after the run: J3-6 (`rst_sipo`) -> J3-16, J3-9 (`rst_piso`) -> J2-17; J3-4 -> J2-18 and
J3-7 -> J2-19 as before. Editor Verify:

| Input | Measured (editor) | Predicted |
|---|---|---|
| `sipo_out` (J3-16) | level 1 | 1 |
| `piso_out` (J2-17) | capture `0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF`, level 1 | 168 ones |
| `dft0_buff` (J2-18) | period 100 ticks | 100 |
| `dft1_buff` (J2-19) | period 100 ticks | 100 |

Note for modes: a LEVEL capture reads the pin after the run, when the outputs are back at
their idle levels; `piso_out` in a one-step mode sees `shift` LOW the whole time.

## 4. Conclusion

**Part A PASS.** The sampler inside the chip controller works on the board: it records a whole
chip run (22 outputs, the chip's 2 serial outputs, the step number) at 10 MHz, the 22 outputs
match what the steps predict, and the recorded `piso_out` is the expected frame bit for bit
(167 of 168 bits in the record; the last one ends the run). It also showed a wiring fault
(an open `piso_out` wire) directly. On `vchip_top` the outputs are recorded from inside the
FPGA; the pad version is Part B.

**Part B PASS.** On `chip_top` the same record is taken at the pads: the 22 outputs as the pins
really did it, matching the steps, and the SIPO frame bit-exact from the pins. Together with the
pad readback (EXP-10) the controller now checks every run of the real chip by itself, both as
counts (readback) and as a waveform (sampler). Limit as before: logic level at the FPGA pad, not
after the connector / wire, and not the analog level.
