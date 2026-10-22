# EXP-03: Phase 7 mode sequencer on the loopback pairs

Per `generic_controller_prompt.md` Phase 7, exit "[simulated], then [measured on board]
with loopback". The step engine runs a 6-step sequence on the same 5 loopback pairs as
EXP-01 and shows its progress on the LEDs. **Not run yet**: it needs the lab PC (Vivado)
and the ZedBoard. §1–§3 are prepared and simulated; §4 is filled in only with real
readings.

## 1. Setup

- **Design**: `fpga/src/phase7_seq_loopback_top.sv` (top), `fpga/constraints/phase7_seq_loopback_top.xdc`.
  Uses `seq_engine.sv`, `sig_cell.sv`, `cap_cell.sv` and the generated
  `fpga/src/gen/phase7_cfg_pkg.sv` (from `config/phase7_seq_loopback.yaml`; regenerate with
  `cd tools && python -m nemo_ctl.gen_svh --phase7`, `scripts/run_phase7_sim.sh` also does it).
  **Build from the hardware package only.** The time-scaled simulation copy is written to a
  temp folder, never to `fpga/src/gen`; its header says `SIMULATION ONLY`.
- **Board**: ZedBoard, **VADJ jumper J18 on 1.8 V** (check before powering up).
- **Jumpers**: the same 5 as EXP-01, P column only:

  | Pair | Cell (drive -> read back) | Output | Input |
  |---|---|---|---|
  | 0 | `clk` -> `clk_in` | J3-0 (LA00_P) | J3-16 (LA16_P) |
  | 1 | `rst` -> `rst_in` | J3-1 (LA01_P) | J2-17 (LA17_P) |
  | 2 | `data` -> `data_in` | J3-2 (LA02_P) | J2-18 (LA18_P) |
  | 3 | `cs` -> `cs_in` | J3-3 (LA03_P) | J2-19 (LA19_P) |
  | 4 | `en` -> `en_in` | J3-4 (LA04_P) | J2-20 (LA20_P) |

  Pin numbers are unchanged from EXP-01 (the XDC `PACKAGE_PIN`/`IOSTANDARD` lines are
  identical, checked with `diff`). New in this XDC only: **PULLDOWN on LA16–LA20_P**, so a
  pulled jumper reads 0 instead of floating.
- **Switch**: `sw[4]` up = START, down = ABORT (if still running). Debounced, 20 ms. Other
  switches unused.
- **LEDs**: LD0–LD2 = step number (current step while running, the step it ended on
  afterwards), LD3 = busy, LD4 = done, LD5 = FAULT, LD6 = `data_in` captured 0xA5,
  LD7 = aborted.
- **Instruments**: Fluke 115 multimeter for static levels; oscilloscope (1 MΩ input,
  CLAUDE.md §5) for the pulses and the 4 Hz clock (too short for a multimeter).

## 2. The sequence (`config/phase7_seq_loopback.yaml`)

| Step | Name | What changes | Ends | Expected length |
|---|---|---|---|---|
| 0 | idle | every cell: `rst` HIGH, others LOW; captures armed | after 1 s | 1 s |
| 1 | reset | `rst` pulses low 500 ms | after 1 s | 1 s |
| 2 | load | `clk` 4 Hz × 8 cycles (from 10 ms), `data` = 0xA5 MSB-first on clk's falling edge, `data_in` captures 8 bits on clk's rising edge | `data_in` captured | ≈1.76 s (8th rising edge) |
| 3 | latch | `cs` pulse 500 ms from 250 ms, `en` HIGH | `cs_in` saw 1 rising edge | ≈0.25 s |
| 4 | confirm | nothing | `en_in` == 1 (timeout 100 ms) | 30 ns with the jumper in |
| 5 | hold | nothing | after 2 s | 2 s |

Total ≈ 6 s. After the last step every pin returns to step 0 (`rst` 1.8 V, others 0 V),
and the capture results are kept.

## 3. What's already done (not this experiment's result)

- **[simulated, Icarus 12]** `scripts/run_phase7_sim.sh`:
  - `seq_engine_tb` 31/31: every step boundary exact to the tick, using real cells; an unlisted cell keeps running; fault, abort, start-while-busy and a 1-step table all behave.
  - `phase7_seq_loopback_top_tb` 27/27 on the ×1e-4 copy of this sequence: the whole table above, including a pulled jumper → FAULT at step 4 and an abort at step 2.
- Not done: Vivado synthesis/implementation of this top, xsim.

## 4. Procedure

1. On the lab PC: `scripts/run_phase7_sim.sh` (expect two `ALL TESTS PASSED`; use
   `SIM=xsim` there). Then build:
   `vivado -mode batch -source scripts/create_project.tcl -tclargs phase7_seq_loopback_top build`.
   Record WNS/WHS and LUT/FF/IOB counts in §5 (a report, not a measurement).
2. VADJ J18 on 1.8 V. Wire the 5 jumpers (§1). `sw[4:0] = 00000`.
3. Program: `vivado -mode batch -source scripts/program_board.tcl -tclargs phase7_seq_loopback_top`.
4. **Before START**, multimeter DC volts to GND: J3-1 (`rst`) should be ≈1.8 V (step 0 preloaded:
   HIGH), J3-0/J3-2/J3-3/J3-4 ≈0 V. All LEDs off.
5. **Run 1**: `sw[4]` up. Watch LD0–LD2 count 0 → 1 → 2 → 3 → 5 (step 4 is too short to
   see), LD3 on while running. After ≈6 s: LD3 off, **LD4 on, LD6 on**, LD0–LD2 = 101 (5),
   LD5/LD7 off. Scope, if available, single-shot on J3-0 (`clk`): 8 pulses, 250 ms
   period, 50 % duty, ≈1.8 V; on J3-1 (`rst`): one 500 ms low pulse; on J3-3 (`cs`): one
   500 ms high pulse. Multimeter on J3-4 (`en`) during the 2 s hold step: ≈1.8 V.
6. **Run 2 (fault)**: `sw[4]` down. **Pull the J2-20 jumper** (`en` read-back). `sw[4]` up.
   Expect: steps 0–3 as before, then **LD5 on** ~100 ms into step 4, LD0–LD2 = 100 (4),
   LD4 off. J3-4 back to ≈0 V. Put the jumper back.
7. **Run 3 (abort)**: `sw[4]` down, then up; during step 2 (LD0–LD2 = 010, the 4 Hz clock
   running) put `sw[4]` down. Expect **LD7 on**, LD0–LD2 = 010, LD3 off, J3-0 ≈0 V.
8. Record everything in §5, tagged [measured on board]. If anything disagrees, record the
   symptom (not a guessed cause) in `docs/issues.md`.

### Build record (2026-10-22, Windows lab PC, Vivado 2022.1)

`create_project.tcl -tclargs phase7_seq_loopback_top build` completes, no errors or critical
warnings. Implementation report, **not a measurement**: all timing constraints met,
WNS +0.248 ns / WHS +0.167 ns (worst path `u_engine/step_reg` -> `step_reg`, 9 levels),
1061 LUTs, 755 FFs, 19 IOBs. Same pins as EXP-01 (`phase7_seq_loopback_top.xdc` has the same
PACKAGE_PIN/IOSTANDARD lines as `phase4_loopback_top.xdc`), plus PULLDOWN on LA16-20_P.
The testbenches pass in xsim 2022.1 too (`run_phase7_sim.sh`), [simulated].

## 5. Results — 2026-10-22, lab PC: PASS, [measured on board]

### Run record

- Yazan at the board, Claude on the lab PC. Same wiring as EXP-01 (run just before, PASS):
  J18 on 1V8, jumpers J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20, PROG on J17.
  Switches all down before programming (confirmed by Yazan).
- Programmed `phase7_seq_loopback_top.bit` (built 2026-10-22, see the build record above):
  `PROGRAMMED: xc7z020_1 ... (DONE=1)`.
- Multimeter: Fluke 115, DC V, black probe on an SMA jack's outer shell (as in EXP-01).

### Step 4: before START (`sw[4]` down)

| Point | Signal | Reading | Expected | Pass |
|---|---|---|---|---|
| J3-1 | `rst` | 1.8 V | ≈1.8 V (step 0 preloaded, HIGH) | PASS |
| J3-0 | `clk` | 0 V | ≈0 V | PASS |
| J3-2 | `data` | 0 V | ≈0 V | PASS |
| J3-3 | `cs` | 0 V | ≈0 V | PASS |
| J3-4 | `en` | 0 V | ≈0 V | PASS |
| LD0-LD7 | | all off | all off | PASS |

### Run 1: full sequence (`sw[4]` up)

Final LEDs reported by Yazan: **on LD0, LD2, LD4, LD6; off LD1, LD3, LD5, LD7**.

| LED | Meaning | Reading | Expected | Pass |
|---|---|---|---|---|
| LD2-LD0 | last step | 1 0 1 = step 5 | 101 (5) | PASS |
| LD3 | busy | off | off | PASS |
| LD4 | done | on | on | PASS |
| LD5 | FAULT | off | off | PASS |
| LD6 | `data_in` captured 0xA5 | on | on | PASS |
| LD7 | aborted | off | off | PASS |

Repeat of Run 1 (`sw[4]` down ~1 s, then up) with the multimeter on **J3-4 (`en`)**: went
from 0 V to **1.8 V** during the run, then **back to 0 V** when it ended (expected: HIGH in
steps 3-5, back to step 0's LOW after the last step). PASS. Timing of the change and the step
order on LD0-LD2 were not reported.

### Run 2: fault (J2-20 jumper end pulled)

`sw[4]` down, jumper end pulled out of J2-20 (J3-4 end left in), `sw[4]` up, ~5 s.
Final LEDs reported by Yazan: **on LD2, LD5, LD6; others off**.

| LED | Meaning | Reading | Expected | Pass |
|---|---|---|---|---|
| LD2-LD0 | step it ended on | 1 0 0 = step 4 | 100 (4) | PASS |
| LD5 | FAULT | on | on (step 4's 100 ms `en_in == 1` wait timed out) | PASS |
| LD4 | done | off | off | PASS |
| LD3 | busy | off | off | PASS |
| LD7 | aborted | off | off | PASS |
| LD6 | `data_in` captured 0xA5 | on | on: set in step 2, before the fault (the procedure didn't list it) | PASS |

J3-4 after the fault: not measured.

### Run 3: abort during step 2

Jumper put back into J2-20. `sw[4]` down, then up (START); `sw[4]` down during step 2
(the 4 Hz clock). Final LEDs reported by Yazan: **on LD1, LD7; others off**.

| LED | Meaning | Reading | Expected | Pass |
|---|---|---|---|---|
| LD2-LD0 | step it ended on | 0 1 0 = step 2 | 010 (2) | PASS |
| LD7 | aborted | on | on | PASS |
| LD3 | busy | off | off | PASS |
| LD4 | done | off | off | PASS |
| LD5 | FAULT | off | off | PASS |
| LD6 | `data_in` captured 0xA5 | off | off: the abort cut step 2's 8-bit capture short, and LD6 clears on START | PASS |

J3-0 after the abort: not measured.



| Check | Expected | Measured | Instrument | Pass/Fail |
|---|---|---|---|---|
| Build | timing met, no critical warnings | — | Vivado report | — |
| Before START: J3-1 `rst` | ≈1.8 V | — | multimeter | — |
| Before START: J3-0, 2, 3, 4 | ≈0 V | — | multimeter | — |
| Run 1: LED step sequence | 0,1,2,3,5; then LD4 + LD6 on, LD0–2 = 101 | — | eyes | — |
| Run 1: total time | ≈6 s | — | stopwatch | — |
| Run 1: `clk` J3-0 | 8 pulses, 250 ms period, 50 %, ≈1.8 V | — | scope | — |
| Run 1: `rst` J3-1 | one 500 ms low pulse | — | scope | — |
| Run 1: `cs` J3-3 | one 500 ms high pulse | — | scope | — |
| Run 1: `en` J3-4 in hold | ≈1.8 V | — | multimeter | — |
| Run 2: J2-20 pulled | LD5 on, LD0–2 = 100, J3-4 ≈0 V after | — | eyes, multimeter | — |
| Run 3: abort in step 2 | LD7 on, LD0–2 = 010, J3-0 ≈0 V | — | eyes, multimeter | — |

**Fill a row only with an actual reading from the board.**

## 6. Conclusion

**PASS, 2026-10-22.** `seq_engine` ran the 6-step compile-time sequence on the board end to
end (Run 1), stopped with FAULT at the right step when a chip response was missing (Run 2),
and stopped cleanly on ABORT (Run 3). Before START, every pin sat at step 0's level, `rst`
HIGH at 1.8 V, not at `sig_cell`'s reset value 0, so the preload works on hardware. This is
Phase 7's hardware exit criterion (`generic_controller_prompt.md` §3, "[measured on board]
with loopback").

Measured independently of the LEDs: the step 0 levels (multimeter, all 5 pins) and `en` on
J3-4 going 0 -> 1.8 V -> 0 V during Run 1. The LD3 transient from EXP-01 (`docs/issues.md`)
was not seen; LD3 here means busy, so the fault latch of EXP-01 isn't in this design.

Not covered (open): step durations and the 4 Hz clock / pulse widths were not timed (needs
the scope or ILA); the step order was not read during the runs; EXP-04 (the same sequence
loaded from the PC) needs the PC link (JTAG over J17, `docs/decisions.md`).
