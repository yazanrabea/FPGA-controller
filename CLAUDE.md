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
2. **Verify the setup**: prove every signal on the pins is correct, by on-board self-test and by independent measurement. *Pair 0 done; pairs 0-4 done with the generic controller (EXP-01, 2026-10-22).*
3. **Test the chip and package**: connect the real chip, program weights, compute, read back results, check that it works. *Next.*

Learning goals: emerging memory / processing-in-memory for ANN accelerators; hands-on FPGA work for experimental characterization.

## 4. Hardware and toolchain
- Board: Digilent **ZedBoard**, Zynq-7000 **XC7Z020-CLG484-1**, FMC-LPC connector.
- Daughter board: **HTG-FMC-SMA-LVDS REV.1.0**. LA pairs on headers J2/J3 (J3: LA00-16, J2: LA17-33; header position = LA index; use only the **P** column).
- Tools: **Vivado 2022.1** (RTL project, part `xc7z020clg484-1`, no block design). Project path must not contain `&`.
- Secondary, local-only tools (not a replacement for Vivado, no bitstream capability): **Icarus Verilog** (`iverilog`/`vvp`) for simulating self-checking testbenches without a Vivado license/license-server, and **yosys** (`synth_xilinx -family xc7`) for a real (synthesized, not hand-counted) LUT/FF/CARRY4 utilization estimate. Installed via `brew` under `/opt/homebrew` — on an Intel-Homebrew (`/usr/local`) machine, use the arm64 `/opt/homebrew/bin/brew` explicitly if both are present and the Intel one's compiler is broken.
- **Windows lab PC**: has Vivado 2022.1 (`C:\Xilinx\Vivado\2022.1`) and the ZedBoard, but no Icarus/yosys. The `scripts/run_phase*.sh` scripts fall back to Vivado xsim automatically (`scripts/sim_lib.sh`); run them from Git Bash, and use `python`, not `python3` (Windows Store stub). xsim is stricter than Icarus (single driver per `always_ff` variable, no timescale mixing), so a testbench that passes in Icarus should also be run in xsim before it's called done.
- **Windows laptop without Vivado**: `winget install Icarus.Verilog` (Icarus **12**, to `C:\iverilog\bin`, found by `sim_lib.sh`). Older than the macOS Icarus 13: rejects `return` in tasks (`fpga/tb/uart_tb.sv`), a variable driven by both `assign` and `always_ff` on disjoint bits (Dima's `sipo_wrapper.sv` -> `fpga/tb/sipo_wrapper_icarus_shim.sv`), and `vvp` crashes on `fork ... join_any` + `disable`.
- Measurement: Fluke 115 multimeter now; Keysight oscilloscope and Vivado ILA next.
- FMC bank voltage: **LVCMOS18**, and the ZedBoard **J18 (VADJ) jumper must physically be on 1V8**. `IOSTANDARD LVCMOS18` in the XDC does NOT change the real voltage.

## 5. Verified facts (do not re-derive, do not contradict without evidence)
- Pin map (XDC <-> lab spreadsheet <-> Digilent FMC pinout) matched exactly for all 32 LA P pins.
- Pair convention in all bring-up designs: **output pin i = LAi_P, input pin i+16 = LA(i+16)_P**, i = 0..15, selected by `sw[3:0]`; `sw[4]` enables/sets drive.
- The **SMA jacks are unusable** for GPIO: they are wired to transceiver lanes, XC7Z020 has no GTX, and only 4 of 38 reach the FPGA (clock inputs only). Use J2/J3 headers.
- Pair 0 (J3-0 to J3-16 with a jumper) verified: static level, 1 MHz 50% clock (internal checker), and ~100 Hz clock read **0.899 V** on the multimeter (ideal 0.9 V).
- Pairs 0-4 verified with the generic controller (`phase4_loopback_top`, EXP-01, 2026-10-22): CLOCK 100 Hz read **0.9 V** at both J3-0 and J3-16; PULSE x5 counted; SERIAL 0xA5 captured; LOW **0 V** at J3-3; HIGH **1.8 V** at J3-4 (so VADJ really is 1.8 V). Multimeter ground: the outer shell of an SMA jack on the HTG board. Frequency/duty/width not yet measured (needs the scope).
- PC link verified over **JTAG on J17** (EXP-02, 2026-10-22, `phase5_link_jtag_top`, `nemo_ctl.cli link ... --jtag`): test clock configured, started and changed while running from the PC with no re-synthesis: J3-0 **0.9 V -> 0.45 V** (duty 50% -> 25%), 100 Hz -> 1 Hz (LEDs), STOP -> 0 V. Phase 5's exit criterion is met. The link runs at ~1.2 ms per 128-byte scan.
- Phase 7 sequencer verified on the same 5 pairs (`phase7_seq_loopback_top`, EXP-03, 2026-10-22): full 6-step sequence, FAULT on a missing response (J2-20 pulled), ABORT mid-sequence; before START `rst` sits at **1.8 V** (step 0 preloaded), the others at 0 V.
- A 1 MHz clock cannot be read on a handheld multimeter (use the ~100 Hz design for that).
- Checker lessons: `sw[4]` needs a 2-FF synchronizer + ~20 ms settle window; fault latch only after 16 consecutive mismatches; expected value is delayed 2 cycles to match the input synchronizer. **A self-check can lie. Confirm important results with independent measurement.**
- Dima's `sipo_wrapper.sv` Q1, [simulated] 2026-10-22: right after `rst_sipo`, `sel[23:8]` holds the **previous** load's slice 0 (0 on the first load), because the nonblocking reset branch reads `parallel_out` before `sipo.sv`'s reset clears it. The frame being loaded never shows its slice 0. (Earlier reading "always loads zeros" was wrong; `docs/issues.md`.)
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
| `sig_cell.sv` | Generic config-driven signal cell (LOW/HIGH/PULSE/CLOCK/SERIAL) for the controller in `generic_controller_prompt.md`/`docs/controller_spec.md`. One instance per driven chip pin. [simulated] only, `fpga/tb/sig_cell_tb.sv` |
| `cap_cell.sv` | Generic config-driven capture cell (LEVEL/EDGE_COUNT/PERIOD/SERIAL) for the same controller. One instance per captured chip pin. [simulated] only, `fpga/tb/cap_cell_tb.sv` |
| `run_ctrl.sv` | Global RUN/STOP + one-cycle APPLY strobe, synchronized command inputs. [simulated] only, `fpga/tb/run_ctrl_tb.sv` |
| `jtag_echo_core.sv`, `jtag_echo_top.sv` / `.xdc` | JTAG link step J1: BSCANE2 USER4 echo register over the J17 cable (`scripts/jtag_echo_test.tcl`, xsdb). [simulated] `fpga/tb/jtag_echo_core_tb.sv` + **[measured on board] EXP-05 PASS** 2026-10-22 |
| `jtag_link_bridge.sv`, `jtag_link_bscan.sv` | JTAG link step J2: link bytes over BSCANE2 USER4 scans, same ports as `uart_rx`/`uart_tx` for `link_frame`. Scan format in `docs/link_register_map.md`. [simulated] `fpga/tb/jtag_link_bridge_tb.sv` 19/19; not on hardware yet (J3/J5) |
| `phase5_link_jtag_top.sv`, `phase7_link_jtag_top.sv` / `.xdc` | JTAG link step J3: the Phase 5 / Phase 7 link tops with `LINK("JTAG")` (new parameter in `phase5_link_top` / `phase7_link_top`, default `"UART"`), no `rxd`/`txd`. **Bitstreams build**, timing met. [simulated] `fpga/tb/jtag_link_e2e_tb.sv` 11/11 (BSCANE2 replaced by `fpga/tb/bscane2_sim_stub.sv`); not on the board yet (J5) |
| `phase4_loopback_top.sv` / `.xdc` | Phase 4 bring-up top: one `sig_cell`+`cap_cell` pair per TYPE (CLOCK/PULSE/SERIAL/LOW/HIGH) on loopback pairs 0-4, config from generated `fpga/src/gen/nemo_cfg_pkg.sv` (`tools/nemo_ctl/gen_svh.py` + `config/phase4_loopback_test.yaml`). [simulated] (`fpga/tb/phase4_loopback_top_tb.sv`, `phase4_serial_tb.sv`, `scripts/run_phase4_sim.sh`) and **[measured on board]: EXP-01 PASS 2026-10-22** (`docs/experiments/EXP-01_*.md`) |
| `phase6_sipo_piso_top.sv` | Phase 6: SIPO_LOAD / PISO_READ from generic cells only (`run_ctrl` + 7 `sig_cell`s + 2-FF sync + `cap_cell` CAP_W=168), config from generated `fpga/src/gen/phase6_cfg_pkg.sv` (`gen_svh.py --phase6` + `config/phase6_sipo_piso.yaml`, timing-checked by `tools/nemo_ctl/sipo_piso.py`). **Sim top, no XDC** (no chip-pin map). [simulated] Icarus 12, 69/69, against Dima's RTL (`fpga/tb/phase6_sipo_piso_tb.sv`, `scripts/run_phase6_sim.sh`); xsim run with Dima's unmodified `sipo_wrapper.sv` pending |
| `seq_engine.sv` | Phase 7 step sequencer: walks a step table (from outside: package or RAM), APPLYs only each step's cells, ends a step after N ticks or on done/captured/edges/level with timeout -> FAULT; preloads step 0 after reset. [simulated] `fpga/tb/seq_engine_tb.sv` 31/31 |
| `link_frame.sv` | Framed UART protocol engine (parser/responder, byte register bus with 1-tick read latency, 16-byte input FIFO), shared by `link_ctrl.sv` (Phase 5 register file, packed ports) and `phase7_link_top.sv`. [simulated] Phase 5 tbs 12/22/7 under Icarus 12 |
| `seq_bank.sv` | Phase 7 round 2: link-written step-table RAM (block RAM, 4 byte lanes) + prefetched next-step bank (~40 ticks per step); `seq_engine` waits and sets LATE if a step ends sooner. [simulated] `fpga/tb/seq_bank_tb.sv` 10/10 |
| `phase7_link_top.sv` / `.xdc` | Phase 7 round 2: the sequencer with its table loaded over UART (link v2 map, `docs/link_register_map.md`), RUN=start, STOP=abort, APPLY=idle state; same 5 loopback cells/pins as `phase7_seq_loopback_top`; rxd/txd unconstrained (EXP-02). Layout from `gen_svh.py --phase7-link`. PC side: `link.SeqLink`, `cli seq`. [simulated] `phase7_link_top_tb` 21/21 over real UART, **not on hardware**: `docs/experiments/EXP-04_*.md` |
| `phase7_seq_loopback_top.sv` / `.xdc` | Phase 7 bring-up: `seq_engine` + 5 sig/5 cap cells on loopback pairs 0-4, compile-time table `fpga/src/gen/phase7_cfg_pkg.sv` (`gen_svh.py --phase7` + `config/phase7_seq_loopback.yaml`); `sw[4]` start/abort, LEDs step/busy/done/fault/match/aborted. Same pins as Phase 4 + PULLDOWN on LA16-20_P. [simulated] 27/27 (`scripts/run_phase7_sim.sh`), **not yet on hardware**: `docs/experiments/EXP-03_*.md` |

## 7. Next tasks
1. Verify remaining 15 pairs (static + clock).
2. Oscilloscope and Vivado ILA: period, duty, swing, edges, ringing.
3. Generic per-pin I/O on hardware.
4. **Non-overlapping phase FSM**: `clk`, `phi1`, `phi2`, `phir` with dead time (phases must never overlap or array data can be corrupted). Per `docs/controller_spec.md` Q4, phases are generated on-chip from `clk`/`reset`/`set` — do not build this in the FPGA unless that's answered otherwise.
5. SIPO / PISO: done in simulation as generic-controller Phase 6 (`phase6_sipo_piso_top.sv`, USER_MANUAL §7). Open: run `SIM=xsim scripts/run_phase6_sim.sh` on the lab PC (Dima's unmodified `sipo_wrapper.sv`), Dima's answers on edges/polarities/chip delay (Q1-Q7), the chip-pin -> FMC map, and a link top that carries the 136/168-bit frames (link v2 sizes fields per cell, but no top wires the SIPO/PISO cells to it yet).
6. Connect and test the real Y-Flash chip.
7. ~~Generic controller Phase 4 hardware run~~ **done 2026-10-22**: EXP-01 PASS on the
   board (`docs/experiments/EXP-01_phase4_generic_controller_bringup.md`). It found and
   fixed a SERIAL checker bug; one LD3 transient on pair 4 is still unexplained (`docs/issues.md`).
8. Generic controller Phase 7 (mode sequencer): round 1 (compile-time table) and round 2
   (table over UART, `cli seq`, program-verify over the link) done [simulated]; open:
   ~~EXP-03 on the board~~ (**PASS 2026-10-22**), EXP-04 (needs the PC link: JTAG over J17 chosen 2026-10-22, `docs/decisions.md`), and
   real chip sequences (INFERENCE/WRITE) once the chip-pin map and Dima's answers exist.

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
