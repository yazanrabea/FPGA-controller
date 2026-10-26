# Handoff — NEMO generic controller (Phases 0-7 built; 4, 5, 7 and first scope timing verified on the board)

> For a fresh agent picking this up with no prior context. Read this, then `CLAUDE.md`
> and `docs/WORKLOG.md` (newest entry first). Rewritten 2026-10-26, end of Rahaf's lab
> session (Rahaf at the bench, Claude on the lab PC).

## State as of 2026-10-26, `main` on `https://github.com/yazanrabea/FPGA-controller.git`

| Phase | What it is | Status |
|---|---|---|
| 0-2 | Spec, config file + Python core, CLI wizard | Done. **New (Yazan, 10-23 / 10-26):** browser config editor `python -m nemo_ctl.cli gui` with a Signals (waveform) panel; USER_MANUAL §3.5 |
| 3 | RTL cells `sig_cell` / `cap_cell` / `run_ctrl` | [simulated]; used in every board test |
| 4 | `phase4_loopback_top` | **EXP-01 PASS [measured on board]** |
| 5 | Runtime link (`link_frame` + `link_ctrl`) | **EXP-02 PASS over JTAG [measured on board]**. The UART variant has never run on hardware (no adapter) |
| 6 | SIPO load / PISO read against Dima's RTL | [simulated] 69/69, Icarus + xsim. Hardware dry run planned (chip pipeline C1-C6: pin map done, then the CHIP target, generator, `chip_top`, EXP-07/08) |
| 7 | Mode sequencer | **EXP-03 PASS** (compile-time table; rerun PASS 2026-10-26 on the `seq_engine`-fix bitstream), **EXP-04 PASS over JTAG** (table from the PC, `program_verify()` on hardware) |
| — | PC link over JTAG (J17) | J1-J5 done (EXP-05 + the above) |
| — | **Scope timing** | **EXP-06 (2026-10-26):** timing exact; ringing 0.4-0.7 V on the jumper wires; **DRIVE 4 halves it**, so it's now the rule for chip-facing outputs |
| — | **Chip pipeline** (C1-C6) | **C1, C2 done 2026-10-26**: the chip-pin -> FMC map decided (jumper wires, by block) and checked by `validate`; the CHIP sequencer target (22 + 4 cells, 136 / 168-bit serial, 1024-byte entries). Next C3 (WORKLOG has the plan) |
| 8 | Chip-ready checklist | Not started: needs Dima's answers (the pin map no longer waits on him) |

## What happened on 2026-10-26 (details: WORKLOG, `docs/experiments/EXP-06_scope_timing.md`)

- **EXP-06**, on `phase5_link_jtag_top`. Every setting was made from the PC over JTAG on one
  bitstream:
  - 1 MHz / 50 %, 100 kHz / 25 % and a 1 µs pulse every 10 µs: all exact;
  - 10 MHz measured 51 % duty (an edge-measurement effect);
  - clock and pulse started on one APPLY rise together (digital channels);
  - LOW / HIGH static.
- **Ringing** (CX3324A, 1 MΩ, DC, shortest ground clip next to the pin, mean values),
  1 MHz, max / min:

  | | DRIVE 12 | DRIVE 4 |
  |---|---|---|
  | J3-0 | 2.2 / -0.4 V | 1.97 / -0.25 V |
  | J3-16 (far end) | 2.42 / -0.7 V | 2.09 / -0.41 V |

  Edges: ~18 ns at DRIVE 12, ~20 ns at DRIVE 4. A repeat at DRIVE 12 with the short ground
  gave the same result, so the ringing is real, not the probe.
- **Correction**: Vivado's default slew for these pins is already **SLOW** (I/O reports),
  so DRIVE 12 -> 4 was the only real change.
- **Decision (Rahaf)**: every FPGA output that drives a **chip input** gets
  **`DRIVE 4` + `SLEW SLOW`**. Recorded in `docs/decisions.md`, CLAUDE.md §8 and
  `docs/controller_spec.md` §3.
  - It applies when the chip XDC is written; none exists yet, and XDCs are hand-written.
  - Not for FPGA inputs reading the chip's outputs.
  - The existing bring-up XDCs keep DRIVE 12, as verified.
  - `phase5_link_jtag_slew_top` (+ XDC) is the measured DRIVE 4 example.
- **Open**: -0.41 V below ground remains at the far end. Whether it's acceptable depends on
  the chip's input rating (unknown: datasheet / Dima). Next options: a series resistor
  (~22-33 Ω) at the driver, or shorter wires (`docs/issues.md`).
- **Pairs 5-15: not verified.** Rahaf skipped them and assumes they work; verify each pin
  before the chip uses it (`docs/pin_verification.md`).
- Housekeeping:
  - CLAUDE.md §6/§7 status rows brought up to date;
  - pytest 5 runs: 234 passed, 1 skipped each. Yazan's one unexplained failure didn't come back.
- **Review** (handoff step 2, Rahaf's call; WORKLOG "review of unreviewed code"):
  - scope: Yazan's GUI (`gui.py`, `waves.py`) and Claude's JTAG PC side (`jtag.py`,
    `jtag_server.tcl`). The round-2 RTL was already reviewed on 2026-10-22;
  - **fixed**: `XsdbScanPort` never read xsdb's stdout after READY, so a burst of output
    would freeze the link. Now a drain thread keeps reading; regression test with a fake
    flooding server (`tools/nemo_ctl/tests/_fake_xsdb_server.py`), which reproduced the
    hang first;
  - `waves.py` drew SERIAL data 20 ns earlier than `sig_cell.sv` changes it, and the DFT
    label used `b_value` / 3-bit `s`: first left for Yazan, then **fixed** at Rahaf's request
    (lag measured in xsim);
  - `gui.py` security: fine (127.0.0.1, Host check, JSON-only POSTs, fixed save path).
- **Review part 2** (Rahaf: "you do c"): JTAG RTL, `jtag_server.tcl` and the three 2026-10-22
  fixes, read as code: **no bugs** (notes only, WORKLOG).
- **`waves.py` fixes** at Rahaf's request: SERIAL bits drawn 2 ticks (20 ns) after the clock
  edge, measured in xsim on `sig_cell.sv`; the DFT label shows the configured `adc` and `s` as
  4 bits (also in `timing.py` / `wizard.py`).
- **EXP-03 rerun** on the bitstream with the `seq_engine` `step_cnt1` fix [measured on
  board]: pre-START levels, full sequence, FAULT, abort all identical to 2026-10-22. The
  "measured on the old bitstream" caveat is closed.

## Machines

- **Windows lab PC** (`C:\Users\LAB\Desktop\yazan_rahaf\FPGA-controller`): Vivado 2022.1 at
  `C:\Xilinx\Vivado\2022.1` (xsdb in the same `bin`), the ZedBoard. No Icarus/yosys.
  - Run `scripts/*.sh` from Git Bash (xsim fallback, `SIM=xsim`).
  - Vivado:
    `cmd //c "C:\\Xilinx\\Vivado\\2022.1\\bin\\vivado.bat" -mode batch -nojournal -nolog -source <tcl> -tclargs ...`.
    A build takes 5-10 min; run the link tops in the background.
  - `python`, not `python3`.
  - **Git identity (repo-local) is now `Rahaf Aburaya <rahaf.abo.ria@gmail.com>`** (set
    2026-10-26 at her request; it was `yazanrabea` on 10-22). Whoever commits next on this PC
    should check `git config user.name` and set their own.
  - `git push` works (GitHub signed in via Git Credential Manager).
  - Memory is tight; long idle background jobs can be killed.
- **Yazan's laptop** (Windows 11): no Vivado; Icarus 12 at `C:\iverilog\bin` (a few
  limits, see CLAUDE.md §4); `python` 3.10; `gh` signed in as `yazanrabea`.

## Lab equipment (2026-10-26)

- **Keysight CX3324A** (Device Current Waveform Analyzer): used for EXP-06's analog
  readings. Coupling was AC at first, then switched to DC. The probe/sensor model was never
  recorded: ask and record it next time.
- **Agilent MSO-X 2002A** (InfiniiVision, 2 analog channels, logic cable D0-D7): used for
  EXP-06's digital channels (threshold ~0.9 V for 1.8 V logic). Its 70 MHz bandwidth is from
  memory of the datasheet; check the front label.
- **Fluke 115** multimeter: ground on an SMA jack's outer shell on the HTG board.

## Board setup that works

- J18 (VADJ) on **1V8**. PROG micro-USB on **J17**: a bad cable shows up as no Digilent
  USB device in Windows.
- Jumpers (HTG-FMC P column): J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20.
- Program: `scripts/program_board.tcl -tclargs <top>`. Bitstreams live in `build/`
  (git-ignored); rebuild with `scripts/create_project.tcl -tclargs <top> build`.
- Currently on the board: `phase7_seq_loopback_top` (EXP-03 rerun, ended in Run 3 = aborted
  at step 2, LD1 + LD7 on). Program another top to change that.
- Settings from the PC: `nemo_ctl.jtag.open_jtag()` + `send_cell_config(...)` / `apply()` /
  `run()` / `stop()` in one Python session, or `python -m nemo_ctl.cli link ... --jtag`.
- The person at the bench reads the instruments; you record exactly what they report. Ask
  when a report is ambiguous (missing units or signs, e.g. "~700mv" meant -0.7 V).

## Last verified results

- pytest (from `tools/`): 236 passed, 1 skipped.
- [simulated, xsim]:
  - Phase 3: 28 / 16 / 9 / 16.
  - Phase 4: 21 + `phase4_serial_tb` 2.
  - Phase 5: 12 / 22 / 7.
  - Phase 6: 69.
  - Phase 7: 40 / 10 / 27 / 21.
  - JTAG: 9 / 19 / 11.
- [Vivado reports], all met:
  - `phase4_loopback_top` +4.001 ns;
  - `phase7_seq_loopback_top` +0.100 ns (tight);
  - `phase5_link_jtag_top` and `phase5_link_jtag_slew_top` +0.206 ns;
  - `phase7_link_jtag_top` +0.427 ns.
- [measured on board]: EXP-01..06, all PASS (EXP-03 also rerun 2026-10-26). EXP-06's ringing is
  an open issue, not a fail.

## What to do next

1. **Dima's questions** (`docs/questions_for_dima_2026-10-22.md`, drafted, still not sent).
   Rahaf postponed it on 2026-10-26, but it is the critical path for the pins' *meaning*
   (polarities, edges, widths, rates; the map itself is decided, C1), the chip's **input rating below ground** (needed to judge the -0.41 V), the real
   INFERENCE/WRITE sequences and Phase 8 all wait on it. Add the input-rating question if
   it's missing.
2. Optional: a human review. All code on `main` has been reviewed by Claude, with **no open
   findings** (round-2 RTL 2026-10-22; GUI, JTAG PC side, JTAG RTL and the 2026-10-22 fixes
   on 2026-10-26, WORKLOG). **Yazan, FYI:** your `waves.py` / `test_waves.py` changed
   2026-10-26 (two review fixes, see "What happened").
3. Optional, at the bench:
   - repeat A1/A2 with a ground spring and record the probe model;
   - a series resistor test if the chip's rating requires it;
   - verify pairs 5-15 when the chip needs them.
4. The chip pipeline C2-C6 (WORKLOG, 2026-10-26 C1 entry). Its generated chip XDC gets **DRIVE 4 + SLEW SLOW on
   every FPGA output driving the chip** (CLAUDE.md §8), and verify those exact pins.

## Working rules

- **Rahaf (2026-10-19, used again 2026-10-26):** push directly to `main` after each passing
  step (commit -> `git pull --rebase origin main` -> push); stop for her approval after each
  phase / decision.
- **Yazan:** ask before pushing to `main`; he has pushed his own work to `main` directly.
- Both: document every step per CLAUDE.md §9, docs in the same commit as the code.

## Things a new agent should NOT do

- Don't invent pins, voltages, chip ratings or behaviour.
- Don't record an unmeasured result. "Assumed OK" (pairs 5-15) is not "verified".
- Don't program the board until the person there confirms the setup.
- Don't use JTAG USER1 or short scans (EXP-05).
- Don't edit `fpga/reference/dima_blocks/`.
- Don't build from a time-scaled package.
- Don't change the verified bring-up XDCs to DRIVE 4; the rule is for chip-facing outputs.

## Key files

| Thing | Path |
|---|---|
| Shared project context (read first) | `CLAUDE.md` |
| Chronological log, newest first | `docs/WORKLOG.md` |
| Lab-user manual (GUI §3.5, JTAG link §6.4, Phase 7 §8) | `docs/USER_MANUAL.md` |
| Spec, pin table (+ the DRIVE 4 note), open questions | `docs/controller_spec.md` |
| Questions for Dima (draft) | `docs/questions_for_dima_2026-10-22.md` |
| Link register maps + JTAG scan format | `docs/link_register_map.md` |
| Experiments | `docs/experiments/EXP-01_*.md` ... `EXP-06_scope_timing.md` |
| Pin verification per pair | `docs/pin_verification.md` |
| Bugs / decisions | `docs/issues.md`, `docs/decisions.md` |
| Build / program | `scripts/create_project.tcl`, `scripts/program_board.tcl` |
| Sims | `scripts/run_phase{3_sims,4_sim,5_link_sim,6_sim,7_sim}.sh`, `scripts/run_jtag_sim.sh` |
| JTAG PC side | `tools/nemo_ctl/jtag.py`, `scripts/jtag_server.tcl` |
| Python tool (module list, incl. `gui.py`, `waves.py`) | `tools/nemo_ctl/README.md` |
| The task brief | `generic_controller_prompt.md` |

## Who's who

- **Rahaf**: at the bench 2026-10-26 (EXP-06, the DRIVE 4 decision, the EXP-03 rerun, the
  review decisions); did Phases 0-5.
- **Yazan**: owns the repo; did Phases 6-7, the JTAG bring-up runs (10-22) and the GUI.
- **Dima**: SIPO/PISO RTL and chip details; the open questions go to him.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
