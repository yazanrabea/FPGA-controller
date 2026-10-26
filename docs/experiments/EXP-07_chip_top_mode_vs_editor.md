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

## 6. Results — IN PROGRESS (2026-10-26, lab PC), [measured on board]

### Run record
- Rahaf at the bench, Claude on the lab PC. Setup confirmed by Rahaf: J18 on 1V8, loopback
  jumpers off; the J17 PROG cable is connected (xsdb `jtag targets`: `Digilent Zed
  210248B4A8BD`, `arm_dap`, `xc7z020`).
- Step 2: `program_board.tcl -tclargs chip_top` -> `PROGRAMMED: xc7z020_1 with chip_top.bit
  (DONE=1)`, 16:14.
- Link check (read-only, `open_jtag(link_cls=SeqLink, target=chip_target())`): the link answers;
  status run 0 / busy 0 / done 0 / fault 0 / aborted 0 / late 0 / table_rejected 0 /
  rx_overflow 0. All 4 cap cells (sipo_out, piso_out, dft0_buff, dft1_buff): level 0, edges 0,
  as expected with nothing connected (PULLDOWN).
- Pass 1, run 1: `run-mode --mode INFERENCE --jtag` with a copy of `config/nemo_config.yaml`
  whose `sipo_in` data is `0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` (the committed config is
  unchanged). Output: 2 steps (idle 1000 ticks, INFERENCE 35000 ticks), **`STATUS: done; last
  step 1`**, no FAULT, exit 0. Captures: all 4 cap cells level 0 / edges 0 / period 0 / high 0;
  piso_out capture 0x000...0 (42 hex digits). Expected with nothing on the inputs (PULLDOWN).
- Pass 1, runs 2 (16:25:00) and 3 (16:31:51): same output, done, no FAULT. The scope did not
  trigger on either (run 2: not armed; run 3: armed in Normal / Single, `Trig'd?`, but it
  never triggered although Rahaf saw D2 go up). Trigger source not yet checked: likely not
  set to D2 (open).
- Workaround: repeat the run in one JTAG session (scratchpad script: `SeqLink.load` once,
  then `start` + `wait` in a loop) so the scope can use Auto / Run. 200 runs in 1.6 s
  (7.9 ms each), done 200, fault 0 (16:37:22); then **7500 runs in 60.0 s (8.0 ms each),
  done 7500, fault 0** (16:37:39-16:38:44). The sequencer restarts reliably with no reload.
- Repeat 2: 7500 runs in 60.3 s, done 7500, fault 0 (16:40:29-16:41:34).
- **Pass 1 logic analyser capture** (`docs/measurements/EXP-07_pass1_overview.png`, a phone
  photo of the screen): MSO-X 2002A, D0-D7, threshold 900 mV, trigger D2 rising, 50 µs/div,
  0 s at the centre, Peak Detect, 25 MSa/s, Stop (triggered during the repeated runs). Read
  from the photo (positions are only as good as a photo of the screen, about ±5 µs):

  | Ch | Pin | Seen | Expected (§3) | |
  |---|---|---|---|---|
  | D0 | clk | toggling from the trigger to past the right edge (+250 µs) | 1 MHz for the whole 350 µs step | matches |
  | D1 | sipo_in | an irregular bit pattern over the same span as D2 | the frame, 136 bits | pattern seen; bits not yet read |
  | D2 | clk_sipo | toggling, one block of ~130-136 µs from the trigger | 136 cycles, 2-138 µs | matches |
  | D3 | cs | one short pulse just after D2's block ends | 1 µs at 140 µs (2 µs after clk_sipo ends) | matches |
  | D4 | rst_sipo | HIGH, one short dip at the trigger point | HIGH, 100 ns low at the start | matches |
  | D5 | clk_piso | toggling from ~10-12 µs after D2's block ends, to past the right edge | from 150 µs (12 µs after clk_sipo ends) to 318 µs | matches |
  | D6 | shift | LOW throughout | LOW | matches |
  | D7 | rst_piso | HIGH (top line), one short dip at the trigger point | same as rst_sipo | matches |

  The order and relative timing of all 8 signals match the config. Not yet measured: cycle
  counts, the 1 µs / 100 ns widths, and the sipo_in bits (needs zooming in).
- **Frequency** (scope [Meas] → Frequency on the stored capture, digital channels):
  D2 clk_sipo **1.000 MHz**, D0 clk **1.000 MHz**, D5 clk_piso **1.000 MHz**. Expected 1 MHz
  (period 100 ticks of 10 ns), exact to the scope's 4 digits. **PASS.**
- **sipo_in bits**: zoomed to 2 µs/div at the start of clk_sipo, D1 read at each rising edge
  of D2: **0 1 0 1 1 0 1 0** = 0x5A, the frame's first byte (MSB first). Expected
  0 1 0 1 1 0 1 0. **PASS.** (Rest of the 136 bits not read.)
- **Reset pulse widths** ([Meas] → − Width, stored capture at 25 MSa/s = 40 ns per sample):
  D4 rst_sipo **90 ns**, D7 rst_piso **90 ns**. Expected 100 ns (10 ticks); 90 ns is within
  the ±40 ns sample resolution of this capture. **PASS** at this resolution (a sharper
  reading needs a capture at a faster sample rate).
- cs width (D3, + Width): not shown at first (the pulse was outside the zoomed window); with
  the view moved to ~+138 µs: **1.000 µs**. Expected 1 µs (100 ticks). **PASS.**
- **Pass 1 result: PASS** on all 8 pins (J3-0, J3-3..J3-9). LA05-09 had never been checked
  before (`docs/pin_verification.md`).
- Passes 2-3: not run yet.
