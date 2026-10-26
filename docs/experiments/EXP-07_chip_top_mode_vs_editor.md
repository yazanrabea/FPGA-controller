# EXP-07: chip_top runs an editor mode; compare the pins with the Signals panel

Chip pipeline step C5 (Rahaf's request, 2026-10-26): "can I open the interface (wizard)
and check that the output is actually what I want to output?" This experiment programs
`chip_top`, runs one mode from `config/nemo_config.yaml` with
`python -m nemo_ctl.cli run-mode --mode <M> --jtag`, and compares what the **logic
analyser** shows on every chip-input pin with what the editor's **Signals panel** draws
for the same mode. It is also the **first board check of 17 output pins** that have never
been checked (LA05-15, LA20-25; `docs/pin_verification.md`).

**Status: PLANNED, not run.** No chip is connected. Nothing below has been measured.

## 1. Setup

- **Design**: `chip_top`, bitstream `build/chip_top/chip_top.runs/impl_1/chip_top.bit`
  (built 2026-10-26 in C4, timing met +0.112 ns). Pins: generated
  `fpga/constraints/chip_top.xdc` from `pin_map`; outputs DRIVE 4 / SLEW SLOW, inputs PULLDOWN.
- **Board**: ZedBoard, **J18 on 1V8**, PROG micro-USB on **J17**, switches don't matter
  (chip_top doesn't read them). **Remove all the EXP-01 loopback jumpers.** In chip_top
  LA16-19 are FPGA inputs and every other mapped pin is an output, so J3-0..J3-4 to
  J3-16/J2-17..J2-20 would now feed the chip-output inputs from controller outputs, and
  J2-20 (b1_dft) is now an *output*: the old J3-4 to J2-20 jumper would short two drivers
  (clk_sipo and b1_dft).
- **PC**: lab PC, Git Bash, from `tools/`.
- **Instrument**: Keysight MSO-X 2002A digital channels D0-D7 (logic cable), threshold
  **0.9 V** (half of 1.8 V), logic ground to board ground (SMA jack shell). 8 channels, so
  three passes (§2). Optional: analog CH1 on one pin for the level.
- **Config**: the mode must be complete. The example INFERENCE has `sipo_in` data `"0x"`,
  which `run-mode` refuses; set the frame in the editor first (e.g.
  `0x5AA55A0FF0123456789ABCDEF0C3C3E7E7`, the C4 simulation frame).

## 2. Pins, by pass (from `pin_map`; header position = LA index, J3 = LA00-16, J2 = LA17-33)

| Pass | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 |
|---|---|---|---|---|---|---|---|---|
| 1 SIPO/PISO | clk J3-0 | sipo_in J3-3 | clk_sipo J3-4 | cs J3-5 | rst_sipo J3-6 | clk_piso J3-7 | shift J3-8 | rst_piso J3-9 |
| 2 control/array | reset J3-1 | set J3-2 | s0_p J3-10 | s1_p J3-11 | s2_p J3-12 | pulse J3-13 | rst_dsa J3-14 | b0_dft J3-15 |
| 3 DFT | b1_dft J2-20 | b2_dft J2-21 | s0_dft J2-22 | s1_dft J2-23 | s2_dft J2-24 | s3_dft J2-25 | (free) | (free) |

Chip outputs read by the FPGA (nothing connected, PULLDOWN, so `run-mode` should print
level 0 / edges 0 for all four): sipo_out J3-16, piso_out J2-17, dft0_buff J2-18,
dft1_buff J2-19.

## 3. What the board should do (INFERENCE as in the example config)

`run-mode` makes two steps: **idle** for 10 µs (every pin at its idle level: `rst_sipo`,
`rst_piso` HIGH; the rest LOW, because their idle level is still TBD in `pin_db`), then
**INFERENCE** for 350 µs (its last event + 10 %). When the sequence ends, `seq_engine`
re-applies step 0, so the pins go back to the idle levels (`seq_engine.sv`, "Ending"). Before
START they also sit at step 0 (preload). Times below are from the start of the INFERENCE step.

| Pin | Expected (from the config) |
|---|---|
| clk | 1 MHz, 50 %, for the whole step |
| reset | PULSE active_low 1 µs at 0: LOW 1 µs, then HIGH (it was LOW during idle too, so the board shows LOW until 1 µs) |
| set, s0_p, s1_p, s2_p, shift | LOW |
| pulse | HIGH 1 µs at 0 |
| rst_dsa | HIGH 100 ns at 0 |
| rst_sipo, rst_piso | LOW 100 ns at 0, then HIGH |
| clk_sipo | 136 cycles of 1 MHz from 2 µs (ends at 138 µs) |
| sipo_in | the 136-bit frame, MSB first, changing on clk_sipo's falling edge (+2 ticks) |
| cs | HIGH 1 µs at 140 µs |
| clk_piso | 168 cycles of 1 MHz from 150 µs (ends at 318 µs) |
| b0..b2_dft / s0..s3_dft | DFT helper "adc 3, phi1" (UNCONFIRMED mapping): b0 1, b1 1, b2 0; s0 1, s1 0, s2 0, s3 0 |

The Signals panel draws a pin's own idle level before t = 0 (e.g. `reset` HIGH for an
active_low pulse); the board shows step 0's idle level there. That difference is expected
and is the TBD idle levels, not a fault.

## 4. Procedure

1. Person confirms the board setup (§1): J18 1V8, **no loopback jumpers**, J17 cable.
2. Program: `vivado -mode batch -source scripts/program_board.tcl -tclargs chip_top`.
   LEDs (`chip_top.sv`): LD0-LD2 step, LD3 busy, LD4 done, LD5 fault, LD6 late, LD7 link error.
3. Check the conversion: `python -m nemo_ctl.cli run-mode --mode INFERENCE --dry-run`.
4. Open the editor (`python -m nemo_ctl.cli gui`) on the same mode, Signals panel.
5. For each pass of §2: wire D0-D7, single-shot trigger (e.g. rising edge of `clk_sipo`
   in pass 1, of `pulse` in pass 2, any edge on D0 in pass 3; pass 3 is static, so a
   run-mode while watching is enough), run
   `python -m nemo_ctl.cli run-mode --mode INFERENCE --jtag` (or the editor's
   **Run on board** button), save a screenshot to
   `docs/measurements/`, compare pin by pin with §3 and the panel.
6. Record `run-mode`'s printout (STATUS, the 4 capture lines).
7. Mark each checked pin in `docs/pin_verification.md` (output, logic analyser).

## 5. Pass criteria

- `run-mode` prints `STATUS: done`, no FAULT.
- Every pin in §2 matches §3 / the Signals panel: frequency, cycle count, delays and widths
  within the analyser's resolution; static pins at the right level.
- Pass 1: the 136 `sipo_in` bits read on `clk_sipo`'s rising edges equal the frame.

## 6. Results

Not run yet.
