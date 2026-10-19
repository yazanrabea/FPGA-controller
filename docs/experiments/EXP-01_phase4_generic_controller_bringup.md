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

## 4. Results — PENDING, not yet run

| Pair | Expected | Measured | Instrument | Pass/Fail |
|---|---|---|---|---|
| 0 CLOCK | ~0.9 V DC avg (multimeter); 100 Hz 50% duty, ~1.8 V swing (scope) | — | — | — |
| 1 PULSE | 500 ms high pulses, 2 s apart, x5 | — | — | — |
| 2 SERIAL | LD2 sticky-on after ~0.8 s (0xA5 matched) | — | — | — |
| 3 LOW | 0 V / LD0=LD1=0 | — | — | — |
| 4 HIGH | 1.8 V / LD0=LD1=1 | — | — | — |
| Fault latch (LD3) | off throughout, all 5 pairs | — | — | — |

**No row above may be filled in without an actual reading taken on real hardware.** Do
not mark PASS/FAIL from simulation or from what "should" happen — that's §2/§3, not this
table.

## 5. Conclusion

Not yet reached — depends on §4.
