# EXP-01: Phase 4 generic controller bring-up (sig_cell/cap_cell/run_ctrl on hardware)

Per `generic_controller_prompt.md` Phase 4: "hardware test of every signal type on the
verified loopback pairs." This experiment has **not been run yet** — it needs Vivado (not
available in the environment that designed it) and physical access to the ZedBoard,
jumper wires, and a multimeter/oscilloscope. Everything below through §3 is prepared and
simulated; §4 (Results) is a template to fill in while actually running it.

## 1. Setup

- **Design**: `fpga/src/phase4_loopback_top.sv` (top), `fpga/constraints/phase4_loopback_top.xdc`.
  Depends on `fpga/src/run_ctrl.sv`, `sig_cell.sv`, `cap_cell.sv`, and the generated
  `fpga/src/gen/nemo_cfg_pkg.sv` (from `config/phase4_loopback_test.yaml` via
  `tools/nemo_ctl/gen_svh.py` — regenerate with `cd tools && python3 -m nemo_ctl.gen_svh`
  if the YAML changes; `scripts/run_phase4_sim.sh` does this automatically).
- **Board**: ZedBoard, VADJ jumper (J18) on **1.8 V** (CLAUDE.md §4 — check before powering up).
- **Jumper wires** (HTG-FMC-SMA-LVDS, P column only, same header convention as every
  earlier bring-up design):
  | Pair | Signal under test | Output (drive) | Input (read back) |
  |---|---|---|---|
  | 0 | CLOCK, 100 Hz 50% duty | J3-0 (LA00_P) | J3-16 (LA16_P) |
  | 1 | PULSE, 500 ms, repeat x5 every 2 s | J3-1 (LA01_P) | J2-17 (LA17_P) |
  | 2 | SERIAL, 0xA5 (8 bits, MSB-first) | J3-2 (LA02_P) | J2-18 (LA18_P) |
  | 3 | LOW (constant 0) | J3-3 (LA03_P) | J2-19 (LA19_P) |
  | 4 | HIGH (constant 1) | J3-4 (LA04_P) | J2-20 (LA20_P) |

  All 5 jumpers can be in place at once. Pair 0 is the only one with a **prior confirmed**
  hardware loopback (`docs/pin_verification.md`); pairs 1-4 are pin-mapped via XDC (all 5
  XDC files in this repo agree) but have never carried a real signal before — this
  experiment is also the first functional test of those four pairs, extending CLAUDE.md
  §7 item 1's open "verify remaining 15 pairs" task by four.
- **Switches**: `sw[4]` = RUN (hold high to run), `sw[2:0]` = which pair's status shows on
  the LEDs (0-4; CLOCK/PULSE/SERIAL/LOW/HIGH in that order). No reset button — an internal
  power-on counter generates `rst_n`, and a single APPLY fires automatically a few cycles
  after that (compile-time config, no link to ever send a new one).
- **LEDs**: LD0 = driven output (selected pair), LD1 = captured input (after the 2-FF
  sync), LD2 = live match (or, for the SERIAL pair, a sticky "last capture matched the
  known pattern" bit), LD3 = sticky fault latch (same debounce + consecutive-mismatch
  pattern as `fmc_clock_loopback.sv`'s LD3), LD4 = RUN status.
- **Instruments**: Fluke 115 multimeter; Keysight oscilloscope if available (CLAUDE.md §4).

## 2. What's already done (not part of this experiment's result)

- RTL + generator **[simulated]**, `scripts/run_phase3_sims.sh` (sig_cell/cap_cell/run_ctrl
  unit + integration tests, 69 checks) and `scripts/run_phase4_sim.sh`
  (`phase4_loopback_top_tb.sv`, 21 checks) — both currently pass. The testbench models the
  5 external jumpers directly (shorting `fmc_pins[i]` to `fmc_pins[i+16]`) since the real
  jumpers don't exist in simulation, and only checks what's reachable in a short simulated
  window — the CLOCK/PULSE/SERIAL test timings are deliberately human/multimeter-scale
  (100 Hz, 500 ms, 10 Hz), too slow to simulate to completion in reasonable wall-clock time.
  That's exactly why this hardware experiment still needs to happen: simulation proved the
  *logic*, not the real timing, voltage levels, or signal integrity.
- Two real RTL bugs found and fixed while building this (see `docs/WORKLOG.md`'s Phase 4
  entry for detail): a `{shift_reg[-1:0], ...}` / `{capture_reg[-1:0], ...}` invalid
  part-select at `SERIAL_W`/`CAP_W`==1 (the width every non-SERIAL pin here actually uses),
  and a data-alignment bug in the Python generator for MSB-first SERIAL data.
- One design fix: the SERIAL pair's shift/capture strobe is taken from the helper clock's
  **falling** edge, not rising — a freshly-started CLOCK's first `rising_edge` fires
  immediately (the idle -> first-high transition), which would shift the first bit away
  before it's ever presented.

## 3. Procedure (to run on hardware)

1. Make sure `fpga/src/gen/nemo_cfg_pkg.sv` is up to date (`scripts/run_phase4_sim.sh`
   regenerates it automatically; standalone: `cd tools && python3 -m nemo_ctl.gen_svh`).
   Then `vivado -mode batch -source scripts/create_project.tcl -tclargs phase4_loopback_top`
   — the script globs `fpga/src/gen/*.sv` alongside the other sources automatically.
2. Confirm VADJ (J18) is on 1.8 V before connecting anything.
3. Wire the 5 jumpers per the table in §1.
4. Set `sw[4:0] = 00000` (RUN off), program the board:
   `vivado -mode batch -source scripts/program_board.tcl -tclargs phase4_loopback_top`
   (PROG micro-USB J17 connected, board powered).
5. Internal check first, pair by pair (`sw[2:0] = 0..4`, `sw[4]` stays low): confirm LD3
   (fault) is off and LD0/LD1 read sensible idle levels for each pair before ever running.
6. Set `sw[4] = 1` (RUN). For each pair in turn (`sw[2:0] = 0..4`):
   - **Pair 0 (CLOCK)**: multimeter on DC volts across J3-0 (or J3-16) to ground — expect
     ~0.9 V average for a 1.8 V 50%-duty 100 Hz square wave (matches the already-proven
     `fmc_clock_loopback_slow` reading of 0.899 V). Scope if available: 100 Hz, 50% duty,
     ~1.8 V swing.
   - **Pair 1 (PULSE)**: watch LD0/LD1 blink (500 ms high, long low gaps, repeating 5
     times then stopping) or scope-capture one pulse.
   - **Pair 2 (SERIAL)**: watch LD2's sticky "serial_ok" bit after ~1 s (8 bits at 10 Hz =
     0.8 s to complete one frame) — should turn on and stay on if the capture matched 0xA5.
   - **Pairs 3 (LOW) / 4 (HIGH)**: LD0/LD1 should read 0/0 and 1/1 respectively,
     immediately, LD2 on for both.
   - For every pair: confirm LD3 (fault latch) stays off throughout.
7. Record the actual readings in §4 below, tagged **[measured on board]**. If anything
   disagrees with the expected result, record that too (symptom, not a guess at the cause)
   and add it to `docs/issues.md` per CLAUDE.md §9.

### Build record (2026-10-19, Windows lab PC, Vivado 2022.1)

Bitstream built with `create_project.tcl -tclargs phase4_loopback_top build` after the
`.svh` -> `.sv` fix (`docs/issues.md`). Implementation report, **not a measurement**: all
timing constraints met (WNS +3.702 ns, WHS +0.117 ns), 440 LUTs, 415 FFs, 24 IOBs.

## 4. Results — 2026-10-22, lab PC: PASS (all 5 pairs)

### Run record

- 2026-10-22, Yazan at the board, Claude on the lab PC (Vivado 2022.1). Before programming,
  Yazan confirmed: J18 (VADJ) on **1V8**, the 5 jumpers of §1 in place, all switches down.
  First attempt found no JTAG target: Windows showed no Digilent USB device at all (cable
  problem on J17, fixed by Yazan, then the board appeared).
- Programmed with `scripts/program_board.tcl -tclargs phase4_loopback_top`: Vivado reported
  `PROGRAMMED: xc7z020_1 with phase4_loopback_top.bit (DONE=1)`, `End of startup status: HIGH`.

### Step 5: RUN off (`sw[4]` = 0), LED readout per pair — [measured on board]

Read by Yazan, by eye (1 = LED on).

| `sw[2:0]` | Pair | LD0 out | LD1 in | LD2 match | LD3 fault | LD4 RUN | Expected | Pass |
|---|---|---|---|---|---|---|---|---|
| 000 | 0 CLOCK | 0 | 0 | 1 | 0 | 0 | idle 0 / 0, match, no fault | PASS |
| 001 | 1 PULSE | 0 | 0 | 1 | 0 | 0 | idle 0 / 0, match, no fault | PASS |
| 010 | 2 SERIAL | 0 | 0 | 0 | 0 | 0 | idle 0 / 0; LD2 = sticky `serial_ok`, held cleared while `sw[4]`=0 (`phase4_loopback_top.sv:252`) | PASS |
| 011 | 3 LOW | 0 | 0 | 1 | 0 | 0 | idle 0 / 0, match, no fault | PASS |
| 100 | 4 HIGH | 0 | 0 | 1 | 0 | 0 | idle 0 / 0 (HIGH is only driven while RUN; every pair's idle level is 0 in `config/phase4_loopback_test.yaml`) | PASS |

### Step 6: RUN on (`sw[4]` = 1) — [measured on board]

Multimeter: Fluke 115, DC V, black probe on the outer metal shell of an SMA jack on the
HTG-FMC-SMA-LVDS board (SMA shell = ground). Ground reference checked first against the two
static pairs. Readings as reported by Yazan (stability not reported).

| Point | Pair / signal | Reading | Expected | Pass |
|---|---|---|---|---|
| J3-4 (LA04_P) | 4 HIGH | 1.8 V | ~1.8 V (LVCMOS18 high, VADJ 1V8) | PASS |
| J3-3 (LA03_P) | 3 LOW | 0 V | ~0 V | PASS |
| J3-0 (LA00_P) | 0 CLOCK, 100 Hz 50% | 0.9 V | ~0.9 V DC average (0.899 V with `fmc_clock_loopback_slow`, Sept.) | PASS |
| J3-16 (LA16_P) | 0 CLOCK read-back side | 0.9 V | ~0.9 V (same net through the jumper) | PASS |

LEDs, RUN on, by eye (1 = on):

| `sw[2:0]` | Pair | LD0 | LD1 | LD2 | LD3 fault | LD4 RUN | Notes | Pass |
|---|---|---|---|---|---|---|---|---|
| 000 | 0 CLOCK | 1 | 1 | 1 | 0 | 1 | No brightness difference visible by eye (50% duty at 100 Hz). A phone slow-motion video showed **both LD0 and LD1 blinking** (frequency not measured from the video). | PASS |
| 001 | 1 PULSE | blinked | blinked | 1 | 0 | 1 | Restarted with `sw[4]` down ~1 s, then up. **5 blinks** on LD0, LD1 the same; LD3 off. Pulse width / spacing not timed. Expected: 5 pulses, 500 ms, 2 s apart. | PASS (count; timing not measured) |
| 010 | 2 SERIAL | blinked | blinked | **0** | 0 | 1 | Restarted with `sw[4]` down ~1 s, then up; watched ~2 s. LD0/LD1 blinked "3 or 4 times" (0xA5 = 1010_0101 has four separated 1s = 4 blinks). **LD2 (`serial_ok`) never came on.** LD3 doesn't cover this pair. Diagnosis: checker compare bug, see `docs/issues.md`. | **FAIL** (checker bug; rerun after fix) |
| 011 | 3 LOW | 0 | 0 | 1 | 0 | 1 | | PASS |
| 100 | 4 HIGH | 1 | 1 | 1 | **1, then 0** | 1 | Yazan: LD3 was **on** when he read pair 4 (it was off at the pair 3 reading just before), and went off "after I switched the switches again" (the latch clears when `sw[4]` goes down). Cause not identified: the latch counts only the *selected* pair (16 consecutive mismatching ticks), and `sel` falls back to pair 0 for `sw[3:0]` >= 5, so a switch transition alone shouldn't set it; a brief jumper dropout (e.g. bumped while flipping switches) would. | **INCONCLUSIVE**, repeat |

Re-programmed after the pair 2 checker fix (`docs/issues.md`): new `phase4_loopback_top.bit`,
timing met (WNS +4.001 ns / WHS +0.190 ns). Rows below are on the fixed bitstream.

| `sw[2:0]` | Pair | LD0 | LD1 | LD2 | LD3 fault | LD4 RUN | Notes | Pass |
|---|---|---|---|---|---|---|---|---|
| 010 | 2 SERIAL (rerun) | — | — | **1** | 0 | — | `sw[4]` down ~1 s, then up, waited ~2 s. LD2 (`serial_ok`) on: the captured byte matched 0xA5. | **PASS** |
| 100 | 4 HIGH (rerun) | — | — | — | **0** | 1 | Set `sw[2:0]`=100 first, then `sw[4]` up, nothing touched for 30 s: LD3 off. Then `sw[2:0]` 100 -> 011 -> 100 with `sw[4]` up: LD3 still off. So a switch transition doesn't set the latch; the earlier LD3 stays unexplained (most likely a brief real dropout, e.g. a jumper bumped). | **PASS** |





### Summary [measured on board]

| Pair | Expected | Measured | Instrument | Pass/Fail |
|---|---|---|---|---|
| 0 CLOCK | ~0.9 V DC avg; 100 Hz 50% duty | 0.9 V at J3-0 and at J3-16; LD0/LD1 blinking (phone slow-motion video); LD3 off | Fluke 115 DC V; LEDs; phone slow-mo | PASS (frequency/duty not measured: no scope yet) |
| 1 PULSE | 500 ms high pulses, 2 s apart, x5 | 5 blinks on LD0, LD1 the same; LD3 off | LEDs, by eye | PASS (count; width/spacing not timed) |
| 2 SERIAL | LD2 sticky-on after ~0.8 s (0xA5 matched) | First bitstream: LD2 never on (checker compare bug). Fixed bitstream: LD2 on | LEDs | PASS after fix |
| 3 LOW | 0 V / LD0=LD1=0 | 0 V at J3-3; LD0=LD1=0, LD2 on | Fluke 115 DC V; LEDs | PASS |
| 4 HIGH | 1.8 V / LD0=LD1=1 | 1.8 V at J3-4; LD0=LD1=1, LD2 on | Fluke 115 DC V; LEDs | PASS |
| Fault latch (LD3) | off throughout, all 5 pairs | Off everywhere except **once** during the first pair 4 reading (cleared by `sw[4]`); 30 s retest + switch-flip retest: off | LEDs | PASS on retest; one transient unexplained |

Rows filled only from readings Yazan reported at the board, 2026-10-22.

## 5. Conclusion

**PASS, 2026-10-22.** All five generic-controller signal types (CLOCK, PULSE, SERIAL, LOW,
HIGH) came out of `sig_cell` on LA00-04_P and were read back through the jumpers by `cap_cell`
on LA16-20_P correctly. This is Phase 4's hardware exit criterion
(`generic_controller_prompt.md` §3), and the first time pairs 1-4 carried a signal.

What this run found:
- **A real bug the simulations couldn't reach**: the SERIAL checker compared the wrong byte
  (`docs/issues.md`), so LD2 could never confirm a correct capture, and it reported a match
  with the jumper pulled. Fixed in `phase4_loopback_top.sv`, now covered by
  `fpga/tb/phase4_serial_tb.sv` (time-scaled), and confirmed on the board.
- **One unexplained LD3 transient** on pair 4. It didn't come back in a 30 s untouched run
  or with the same switch flips. Most likely a brief real dropout (jumper bumped). Watch for
  it in EXP-03, which uses the same jumpers.

Not covered here (open): clock frequency/duty and pulse width/spacing are not measured
(needs the scope or ILA, CLAUDE.md §7 item 2); edge quality/ringing; LA pairs 5-15.
