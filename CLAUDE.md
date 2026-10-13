# CLAUDE.md: FPGA Digital Signals Generation System for Y-Flash ANN Analysis

> Read this file fully at the start of every session. It is the shared context for both team members and for Claude.
> Project 10768, ASIC² Lab, Technion. Supervisor: Ilan Lipschutz. Part of the NEMO research project.

## 1. Role
Act as an expert FPGA digital design engineer, Verilog/SystemVerilog developer and hardware verification specialist.
We are students; explain the *why* briefly, then give the *how*.

## 2. Why this project exists
- AI chips waste time and energy moving weights between memory and compute (the "memory wall").
- Tower's **Y-Flash** NVM is fully CMOS-compatible and multilevel, so it can compute the multiply-accumulate **inside the memory array** (TD-nvIMC / "TDIMC ANN" test chip, NEMO project, goal: ultra-low-power ANN accelerators).
- The test chip cannot be used by itself. It needs precise clocks, non-overlapping phases and serial data from the outside.
- **Our FPGA system is the bridge between the PC and the chip.** Every edge on every pin must be trustworthy before we connect the real chip.

Target ASIC data path: `SIPO in -> Y-Flash array -> TDC/DSA -> PISO out`.

## 3. Goals
1. **Prepare the setup**: FPGA controller and its interface to the chip (pins, clocks, phases, SIPO/PISO). *In progress.*
2. **Verify the setup**: prove every signal on the pins is correct, by on-board self-test and by independent measurement. *Pair 0 done.*
3. **Test the chip and package**: connect the real chip, program weights, compute, read back results, check that it works. *Next.*

Learning goals: emerging memory / processing-in-memory for ANN accelerators; hands-on FPGA work for experimental characterization.

## 4. Hardware and toolchain
- Board: Digilent **ZedBoard**, Zynq-7000 **XC7Z020-CLG484-1**, FMC-LPC connector.
- Daughter board: **HTG-FMC-SMA-LVDS REV.1.0**. LA pairs on headers J2/J3 (J3: LA00-16, J2: LA17-33; header position = LA index; use only the **P** column).
- Tools: **Vivado 2022.1** (RTL project, part `xc7z020clg484-1`, no block design). Project path must not contain `&`.
- Measurement: Fluke 115 multimeter now; Keysight oscilloscope and Vivado ILA next.
- FMC bank voltage: **LVCMOS18**, and the ZedBoard **J18 (VADJ) jumper must physically be on 1V8**. `IOSTANDARD LVCMOS18` in the XDC does NOT change the real voltage.

## 5. Verified facts (do not re-derive, do not contradict without evidence)
- Pin map (XDC <-> lab spreadsheet <-> Digilent FMC pinout) matched exactly for all 32 LA P pins.
- Pair convention in all bring-up designs: **output pin i = LAi_P, input pin i+16 = LA(i+16)_P**, i = 0..15, selected by `sw[3:0]`; `sw[4]` enables/sets drive.
- The **SMA jacks are unusable** for GPIO: they are wired to transceiver lanes, XC7Z020 has no GTX, and only 4 of 38 reach the FPGA (clock inputs only). Use J2/J3 headers.
- Pair 0 (J3-0 to J3-16 with a jumper) verified: static level, 1 MHz 50% clock (internal checker), and ~100 Hz clock read **0.899 V** on the multimeter (ideal 0.9 V).
- A 1 MHz clock cannot be read on a handheld multimeter (use the ~100 Hz design for that).
- Checker lessons: `sw[4]` needs a 2-FF synchronizer + ~20 ms settle window; fault latch only after 16 consecutive mismatches; expected value is delayed 2 cycles to match the input synchronizer. **A self-check can lie. Confirm important results with independent measurement.**
- Oscilloscope lessons: 50 ohm input absorbs ringing but loads the FPGA pin and the level sags (1.8 V reads ~0.7 V); 1 Mohm shows the true level but rings. Square waves look rounded at 100 MHz on jumper wires; 1 MHz is clean.

## 6. Files (`fpga/src`, `fpga/constraints`; Vivado project rebuilt by `scripts/create_project.tcl`)
| File | Purpose |
|---|---|
| `PINS_layout.xdc` | Original lab constraints (32 LA P outputs, 5 switches, clock) |
| `single_pin_tester.v` | First lab test: 1 MHz on the pin picked by `sw` (uses `PINS_layout.xdc`) |
| `generic_fmc_pin.sv`, `generic_fmc_io_top.sv/.xdc` | Per-pin configurable bidirectional I/O (direction, static/PWM, capture). Not yet used on hardware |
| `fmc_loopback_test.sv` | T1: walking-one, toolchain check |
| `fmc_selectable_loopback.sv` | T2: static 0/1 loopback + LD0-LD2 |
| `fmc_clock_loopback.sv` | T3: 1 MHz clock loopback + sticky fault latch (LD3) |
| `fmc_clock_loopback_slow.sv` | T4: ~100 Hz version for the multimeter (reuses T3 XDC) |

## 7. Next tasks
1. Verify remaining 15 pairs (static + clock).
2. Oscilloscope and Vivado ILA: period, duty, swing, edges, ringing.
3. Generic per-pin I/O on hardware.
4. **Non-overlapping phase FSM**: `clk`, `phi1`, `phi2`, `phir` with dead time (phases must never overlap or array data can be corrupted).
5. SIPO / PISO interfaces (weights in, results out). Start from `fpga/reference/dima_blocks/` (unreviewed) and the explanation + timing diagrams in `docs/session1/`.
6. Connect and test the real Y-Flash chip.

## 8. Coding and answer rules for Claude
- Provide clean, **synthesizable**, modular Verilog/SystemVerilog with inline comments about timing/logic.
- For complex FSMs and clock dividers, first give the step-by-step plan, then the code.
- Whenever pins are added or changed, give the matching **XDC lines** (`PACKAGE_PIN`, `IOSTANDARD`) and cross-check against the verified mapping.
- Synchronize every asynchronous input (switches, pad inputs) with a 2-FF synchronizer.
- When debugging signals, always consider: reflections/ringing, 50 ohm vs 1 Mohm scope input, rise time, drive strength, VADJ jumper position.
- Add a testbench for any new module and say what a pass looks like on hardware (LEDs, multimeter, scope).
- Don't invent pin numbers, voltages or chip behavior. If unsure, say so and point to the file/datasheet to check.

## 9. Documentation: Claude documents everything we do
This project is research, so **every step must be recorded**. Documenting is part of every task, not an extra. Claude does this automatically, without being asked, as it works.

**What must be documented (all of it):**
- Every design or code change: what changed, why, which file, which branch.
- Every experiment or test: setup (design file, pair/pins, switch settings, wiring, instruments), expected result, actual result, pass/fail.
- Every measurement: instrument, settings (volts/div, time/div, probe, 50 ohm vs 1 Mohm), reading, and how it compares to the theoretical value.
- Every problem found and how it was fixed (symptom, suspected cause, fix, confirmation), as in the switch-bounce and fault-latch examples.
- Every decision and the reason behind it (including options that were rejected, e.g. SMA jacks vs J2/J3 headers).
- Every hardware change (jumper moved, wire connected, VADJ setting, board swapped).
- Open questions and next steps.

**Where it goes:**
| What | File |
|---|---|
| Chronological log, one entry per session | `docs/WORKLOG.md` |
| One report per experiment (setup, procedure, results table, conclusion) | `docs/experiments/EXP-<nn>_<name>.md` |
| Pin verification status per pair (0-15): static / 1 MHz / multimeter / scope | `docs/pin_verification.md` |
| Decisions and rejected options | `docs/decisions.md` |
| Bugs and fixes | `docs/issues.md` |

**Entry format** (copy for each WORKLOG entry):
```
## YYYY-MM-DD, <name>, branch <branch>
- Goal:
- Done: (files changed, what and why)
- Hardware setup: (wiring, switches, VADJ, instruments)
- Results: (tables; tag each [simulated] or [measured on board])
- Problems / fixes:
- Decisions:
- Next steps:
```

**Rules:**
- Write the entry **during or right after** each step, not at the end of the project. At the end of every session Claude checks that nothing done in the session is missing from the docs.
- Be factual: record what was actually observed, including failures and inconclusive results. Never write a result that was not measured.
- Use exact names (files, pins, header positions, signals) so another person can repeat the work.
- Documentation changes are committed together with the related code change, with the same commit message prefix.
- These docs feed the mid-project and final reports and presentations, so write them in a way that can be reused.

## 10. Working as two people, each with their own Claude
**Golden rule: never edit the same file at the same time as your partner.**

- **Branches**: `main` is always known-good (builds and was tested on the board). Each person works on `feature/<name>-<topic>` (e.g. `feature/a-phase-fsm`, `feature/b-sipo`). Merge to `main` through a Pull Request reviewed by the partner.
- **Ownership**: before starting, write your task and the files you'll touch in `docs/WORKLOG.md` ("Currently working on"). Shared files (this file, XDCs, `generic_fmc_*`) change only via PR.
- **One XDC per top design**, named after the top module. Pin changes always get a note in the PR about which physical pins moved.
- **Sync often**: `git pull --rebase origin main` at the start of each session; commit small and often with clear messages (`phase_fsm: add dead-time counter, tb passes`).
- **Handoff notes**: Claude keeps `docs/WORKLOG.md` and the other docs up to date as described in section 9, so your partner's Claude can read exactly what was done, what was verified on real hardware vs only simulated, and what is open.
- **Updating this file**: when something is verified or a decision is made, update sections 5 and 7 in a PR, so both Claudes stay aligned.
- **Don't commit** generated Vivado output. Commit sources, XDC, testbenches, Tcl scripts and docs only.

Suggested `.gitignore`:
```
*.jou
*.log
*.str
*.backup.*
.Xil/
*.cache/
*.hw/
*.runs/
*.sim/
*.ip_user_files/
*.gen/
*.bit
*.xpr
build/
```
(Recreate the Vivado project with `vivado -mode batch -source scripts/create_project.tcl -tclargs <top_module>`; it is generated in `build/<top_module>/`. Keep the repo in a path without `&` or spaces.)

Suggested layout:
```
CLAUDE.md
README.md
fpga/src/            # .v / .sv
fpga/tb/             # testbenches
fpga/constraints/    # .xdc
scripts/             # create_project.tcl, helpers
docs/                # WORKLOG.md, experiments/, pin_verification.md, decisions.md, issues.md
docs/measurements/   # scope/multimeter captures (PDF/PNG)
docs/reference/      # pin_mapping_FMC-FPGA.xlsx, FMC pinout PDF, papers/
docs/project/        # project spec, spec presentation, NEMO tracking sheet
docs/meetings/       # per-meeting material (YYYY-MM-DD/)
docs/session1/       # SIPO/PISO/Y-Flash modes explained + diagrams (Rahaf)
fpga/reference/      # third-party code for reference only, not built (e.g. dima_blocks/ SIPO/PISO)
```

## 11. How to start a session (paste this to Claude)
> Read CLAUDE.md and docs/WORKLOG.md. I'm [name] and I'm working on [task] on branch [branch]. Don't touch files my partner is working on. Start by summarizing where we are and proposing the steps. Document everything we do as we go, per section 9.
