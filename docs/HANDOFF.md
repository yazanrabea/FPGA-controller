# Handoff — NEMO generic controller (Phases 4, 5, 7 verified on the board; chip pipeline C1-C6 done: EXP-07 + EXP-08 PASS)

> For a fresh agent picking this up with no prior context. Read this, then `CLAUDE.md`
> and `docs/WORKLOG.md` (newest entry first). Updated 2026-10-26, late evening, end of
> Rahaf's lab session (Rahaf at the bench, Claude on the lab PC): C5 + EXP-07, then C6 + EXP-08.

## Short version (2026-10-26, late evening)

- **The whole chip path works on the board without the chip (C1-C6 done).** EXP-08: a
  136-bit frame from the PC goes through the controller, 10 jumper wires and Dima's
  **unmodified** SIPO, and comes back through his PISO, bit-exact
  (`0x5AA5…E7E7` + sel `0000E7` + `C6`) in **309 of 310 runs**. The first run was
  corrupted once and could not be reproduced (`docs/issues.md`, OPEN).
- **Board right now:** **`vchip_top`** programmed, **10 jumper wires on** (J3-3..9 → J2-20..26,
  J3-13 → J2-27, J2-28 → J3-16, J2-29 → J2-17). **Take them off before programming any other
  top**: in `chip_top`, J2-20..25 are outputs, so J3-3..8 ↔ J2-20..25 would join two outputs.
- **Next:** Rahaf's choice of the optional C6 follow-ups (phirst stepping, sel after a reset,
  scope on J2-25/26), Dima's questions, a review of the C5/C6 code.

### Earlier the same evening (C5)

- **The chip pipeline works end to end on the board, without the chip.** A mode set in the
  editor (`config/nemo_config.yaml`) is converted (`tools/nemo_ctl/mode_seq.py`), loaded into
  `chip_top` over J17 and driven on the pins exactly as configured: **EXP-07 PASS**, all 22
  chip-input pins seen on the logic analyser (frequencies 1.000 MHz, first SIPO byte 0x5A, cs
  1.000 µs, the static pins switching, everything back to idle at the end).
- How to run a mode: `cd tools`, `python -m nemo_ctl.cli run-mode --mode INFERENCE --jtag`
  (`--dry-run` without the board), or the editor's **Run on board** card
  (`python -m nemo_ctl.cli gui`). USER_MANUAL §8.7.
- **Board right now:** `chip_top` programmed; loopback jumpers **off** (they must stay off
  for chip_top: J2-20 is an output there); logic clips on the PINTEST pins.
- **Next:** C6 / EXP-08 (virtual chip) after Rahaf's OK; Dima's questions.

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
| — | **Chip pipeline** (C1-C6) | **All done 2026-10-26.** **C6 + EXP-08 PASS** (`vchip_top`: controller + Dima's SIPO/PISO as a virtual chip over jumpers, 309/310 readbacks exact). **C5 done + EXP-07 PASS 2026-10-26** (mode -> sequence, `run-mode`, Run on board button; all 22 outputs right on the logic analyser). **C1-C4 done 2026-10-26** (C4: `fpga/src/chip_top.sv`, sim 11/11 incl. a 136-bit SIPO load and 168-bit PISO read over JTAG, bitstream built with DRIVE 4 / PULLDOWN confirmed in the I/O report; C3: `gen_svh.py --chip` -> `fpga/src/gen/chip_pkg.sv` + `fpga/constraints/chip_top.xdc`, generated from the pin map with the DRIVE 4 rule): the chip-pin -> FMC map decided (jumper wires, by block) and checked by `validate`; the CHIP sequencer target (22 + 4 cells, 136 / 168-bit serial, 1024-byte entries). Next: C6 |
| 8 | Chip-ready checklist | Not started: needs Dima's answers (the pin map no longer waits on him) |

## Chip pipeline (C1-C6): prove the whole flow before the chip arrives

Rahaf's idea (2026-10-26): map the chip pins now (the map is **our** choice, the chip is
wired with **jumper wires**) and prove config -> generated files -> FPGA -> pins end to end
on the board. Plan approved; full detail in the WORKLOG entries "chip pipeline step C1..C4".

| Step | What | Status |
|---|---|---|
| C1 | Pin map in `config/nemo_config.yaml` (`pin_map`), by block: `clk` LA00 ... `rst_dsa` LA14, DFT LA15 / LA20-25, chip outputs LA16-19 (`docs/controller_spec.md` §3 table, `docs/decisions.md`). `tools/nemo_ctl/fmc_pins.py` (the 32 LA_P pins, from the verified XDC) + `validate` pin_map checks | **Done** |
| C2 | `sequence.chip_target()`: 22 sig + 4 cap cells named as the chip signals; `sipo_in` 136-bit on `clk_sipo`, `piso_out` 168-bit on `clk_piso` (edges UNCONFIRMED, parameters); 1024-byte step entries (534 used); `SeqLink.load` sends 128-byte chunks | **Done** |
| C3 | `python -m nemo_ctl.gen_svh --chip` -> `fpga/src/gen/chip_pkg.sv` + **`fpga/constraints/chip_top.xdc`**, generated from `pin_map` (never edit by hand). DRIVE 4 + SLEW SLOW on `chip_out[*]`, PULLDOWN on `chip_in[*]` | **Done** |
| C4 | **`fpga/src/chip_top.sv`**; `fpga/tb/chip_top_tb.sv` (`scripts/run_chip_sim.sh`, table `config/chip_sim_test.yaml`) **11/11 [simulated]**: exact 136-bit SIPO frame, setup / hold 480 / 520 ns, 168-bit PISO read back over JTAG. **Bitstream builds**, timing met (+0.112 ns); I/O report confirms DRIVE 4 / SLOW / PULLDOWN on the right pins | **Done**; on the board in EXP-07 (C5) |
| C5 | **Rahaf's request**: what she sets in the editor must be what comes out of the pins. (1) converter: an editor *mode* (`nemo_config.yaml` modes) -> a *sequence* for `chip_top` (step 0 = idle, step 1 = the mode's settings); (2) `python -m nemo_ctl.cli run-mode --mode <M> --jtag` (convert, load over J17, run); (3) **EXP-07**: program `chip_top`, run a mode, compare the **logic analyser** (MSO-X 2002A, D0-D7, threshold 0.9 V) with the editor's **Signals panel**, pin by pin. This also does the first check of the 17 unverified output pins (LA05-15, LA20-25) | **PC side done 2026-10-26**: `tools/nemo_ctl/mode_seq.py`, `cli run-mode` (USER_MANUAL §8.7), tests `test_mode_seq.py` 15/15. **EXP-07 PASS 2026-10-26** (`docs/experiments/EXP-07_chip_top_mode_vs_editor.md`): all 22 chip-input pins as configured on the logic analyser. **Run on board** button added to the editor (Rahaf's OK, 2026-10-26; `gui.py` `/api/run`, card under Signals) |
| C6 | **EXP-08 "virtual chip"**: `vchip_top` = `chip_top` (unchanged; its 7 DFT outputs unpinned for the pin budget) + `virtual_chip` = Dima's **unmodified** `sipo_wrapper` + a standalone `sipo` (to pass the frame on) + 4 x `piso2`, Tower cells stubbed. PISO data `{frame, sel, 8'hC6}`; phirst jumpered from `pulse` (Rahaf's choices). The synthesis risk didn't happen: `sipo_wrapper`'s async load became 16 latches, no rewrite needed. Pins: `config/exp08_vchip.yaml` → `gen_svh.py --vchip` → `gen/vchip_pkg.sv` + `vchip_top.xdc`. Sim `vchip_top_tb` 9/9 (+ a mutant that fails); built (WNS +0.183 ns) | **Done; EXP-08 PASS** (309/310) |

Rule kept throughout: stop for Rahaf's OK before each board step.

## What happened on 2026-10-26, late evening: C6 and EXP-08 (details: WORKLOG, `docs/experiments/EXP-08_virtual_chip.md`)

- **V1:** a scratch out-of-context synthesis of Dima's RTL. 0 errors, 0 critical warnings.
  `sipo_wrapper`'s `sel[23:8]` load inside the async reset → **16 latches** gated by `rst_n`.
- **V2:** `fpga/src/virtual_chip.sv`, `fpga/src/vchip_top.sv`, `config/exp08_vchip.yaml`,
  `gen_svh.py --vchip`, `create_project.tcl` (adds Dima's files + the Tower stubs for
  `vchip_top` only). `cli seq` now takes `--target chip_top`; `seq load` reads the file's
  `target:`. Before, `config/chip_sim_test.yaml` couldn't be loaded from the CLI at all.
- **V3:** `fpga/tb/vchip_top_tb.sv` + `scripts/run_vchip_sim.sh`, xsim 9/9. The jumpers are
  wires. The testbench adds one reset pulse, because the simulation starts at X and the
  board at 0. A mutant with `shift` held at 0 fails, all zeros.
- **V4:** bitstream: WNS +0.183 ns, 12.2k LUT / 19.5k FF / 38 IOB / 6 BUFG. The two SIPO copies
  merge in synthesis (equivalent flip-flops); that's fine. The first build failed on `lmap`
  (Vivado's Tcl is 8.5), fixed.
- **V5 = EXP-08 on the board:**
  - Run 1 was corrupted: bits 0-11 right, then 41 zeros, then the stream restarted. This fits
    a glitch on `rst_piso`, then on `shift` (J2-26 / J2-25, next to `clk_piso`). The jumpers
    had just been put on.
  - Then 309 exact: 5 + 300 in a row, 3 with a fresh CLI load, 1 right after re-programming.
  - Rahaf was asked whether a wire was touched; no answer yet.
- New tests: `test_gen_vchip.py` (13). pytest 288 passed, 1 skipped.
- Files to repeat it: `config/chip_sim_test.yaml`, `scripts/repeat_seq.py`,
  EXP-08 §3 for the commands.

## What happened on 2026-10-26, evening: C5 and EXP-07 (details: WORKLOG, `docs/experiments/EXP-07_chip_top_mode_vs_editor.md`)

- **C5, PC side:**
  - `tools/nemo_ctl/mode_seq.py`: mode -> 2 steps for chip_top. Step 0 = idle, 10 µs: pin_db
    idle levels, TBD = LOW, listed in a note. Step 1 = the mode as configured; BUS / DFT
    helper -> per-pin levels; CAPTURE -> capture modes. The step lasts until the last event
    + 10 %, or `--duration`. Refuses what it would have to guess: an empty SERIAL frame, a
    capture edge chip_top isn't wired for, a pin set twice, a mode with no finite end.
  - `cli run-mode`; `mode_seq.run_table()` (shared); `SeqLink.read_cap_timing()`.
  - `waves.mode_waves()` returns `"finite"`.
  - The editor's **Run on board** card (`gui.py` `POST /api/run`, `config_gui.html`):
    *Check* = convert only; *Run on board* = confirm, then run the page's (unsaved) mode
    over J17. One run at a time; errors are shown, the server keeps running.
  - Tests: `tools/nemo_ctl/tests/test_mode_seq.py` 19 (fake SeqLink for the board).
- **Bug found on the board:** `--duration 20s` was written as `2e+07us` and refused.
  Fixed (whole ns), with a test (`docs/issues.md`).
- **EXP-07** (`chip_top`, MSO-X 2002A D0-D7 at 0.9 V):
  - Pass 1, SIPO/PISO: clocks 1.000 MHz, the first byte 0x5A, cs 1.000 µs, resets 90 ns
    (100 ns at 40 ns resolution). Photo: `docs/measurements/EXP-07_pass1_overview.png`.
  - Pass 2 (control / array) and pass 3 (DFT): all match, by eye.
  - PINTEST: the 8 static-LOW pins went HIGH for 20 s and back.
  - 30,200 runs, 0 faults.
  - 17 pins (LA05-15, LA20-25) were checked as outputs for the first time.
  - Not checked: analog levels, 128 of the 136 SIPO bits, the 4 inputs with a real signal.
    Run on board was not pressed against the board (`run-mode` uses the same code).
- **Scope lessons** (for the next person at the bench):
  - Trigger on a pin that toggles in that pass.
  - Normal / Single / Stop keep showing the last picture, which made "the pins didn't drop"
    look real: use Auto + Run to see live levels.
  - For a 360 µs burst, use `scripts/repeat_mode.py` (7500 runs ≈ 60 s) and Auto.
  - For static pins, use a long `--duration`.
- Files to repeat it: `config/exp07_test.yaml` (frame filled in + PINTEST mode),
  `scripts/repeat_mode.py`.

## What happened on 2026-10-26, day (details: WORKLOG, `docs/experiments/EXP-06_scope_timing.md`)

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
- Jumpers depend on the top (HTG-FMC P column), and the wrong set can join two outputs:
  - bring-up tops (phase4/5/7): J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20;
  - `chip_top`: none;
  - `vchip_top`: the 10 of `fpga/constraints/vchip_top.xdc`'s header (J3-3..9 → J2-20..26,
    J3-13 → J2-27, J2-28 → J3-16, J2-29 → J2-17).
- Program: `scripts/program_board.tcl -tclargs <top>`. Bitstreams live in `build/`
  (git-ignored); rebuild with `scripts/create_project.tcl -tclargs <top> build`.
- Currently on the board: **`vchip_top`** (EXP-08) with its **10 jumpers on**. Take them off
  before programming `chip_top` (J2-20..25 are outputs there) or a bring-up top.
- Settings from the PC: `nemo_ctl.jtag.open_jtag()` + `send_cell_config(...)` / `apply()` /
  `run()` / `stop()` in one Python session, or `python -m nemo_ctl.cli link ... --jtag`.
- The person at the bench reads the instruments; you record exactly what they report. Ask
  when a report is ambiguous (missing units or signs, e.g. "~700mv" meant -0.7 V).

## Last verified results

- pytest (from `tools/`): 288 passed, 1 skipped.
- [simulated, xsim]:
  - Phase 3: 28 / 16 / 9 / 16.
  - Phase 4: 21 + `phase4_serial_tb` 2.
  - Phase 5: 12 / 22 / 7.
  - Phase 6: 69.
  - Phase 7: 40 / 10 / 27 / 21.
  - JTAG: 9 / 19 / 11.
  - Chip: `chip_top_tb` 11 (`scripts/run_chip_sim.sh`); virtual chip: `vchip_top_tb` 9 (`scripts/run_vchip_sim.sh`).
- [Vivado reports], all met:
  - `phase4_loopback_top` +4.001 ns;
  - `phase7_seq_loopback_top` +0.100 ns (tight);
  - `phase5_link_jtag_top` and `phase5_link_jtag_slew_top` +0.206 ns;
  - `phase7_link_jtag_top` +0.427 ns;
  - `chip_top` +0.112 ns (12.5k LUT, 19.4k FF, 4.5 BRAM, 35 IOB);
  - `vchip_top` +0.183 ns (12.2k LUT, 19.5k FF, 4.5 BRAM, 38 IOB, 6 BUFG).
- [measured on board]: EXP-01..08, all PASS (EXP-08: 309/310, one transient open) (EXP-03 also rerun 2026-10-26). EXP-06's ringing is
  an open issue, not a fail. EXP-07: `chip_top`, all 22 chip-input pins at the logic level.

## What to do next

0. **Optional C6 follow-ups** (EXP-08 §5), each with Rahaf's OK and a simulation first:
   - **phirst stepping**: one `pulse` after the load should give `sel = F0C3E7`;
   - **`sel` after a reset**: the FPGA's latches may give `0000` where the simulation of
     Dima's RTL gives the previous slice `C3E7`. That's a real behaviour difference worth
     telling Dima;
   - **scope on J2-25 / J2-26** while `clk_piso` runs, for the run-1 glitch (`docs/issues.md`).
1. **Dima's questions** (`docs/questions_for_dima_2026-10-22.md`, drafted, still not sent).
   Rahaf postponed it on 2026-10-26, but it is the critical path for the pins' *meaning*
   (polarities, edges, widths, rates; the map itself is decided, C1), the chip's **input rating below ground** (needed to judge the -0.41 V), the real
   INFERENCE/WRITE sequences and Phase 8 all wait on it. Add the input-rating question if
   it's missing.
2. Optional: a human review. All code on `main` has been reviewed by Claude, with **no open
   findings** (round-2 RTL 2026-10-22; GUI, JTAG PC side, JTAG RTL and the 2026-10-22 fixes
   on 2026-10-26, WORKLOG). Not yet reviewed: the C5 code (`mode_seq.py`, `cli run-mode`,
   the Run on board additions to `gui.py` / `config_gui.html`) and the C6 code
   (`virtual_chip.sv`, `vchip_top.sv`, `gen_svh.generate_vchip`, `cli seq --target`,
   `create_project.tcl`). **Yazan, FYI:** your files
   changed 2026-10-26: `waves.py` (two review fixes, plus the new `"finite"` key),
   `gui.py` / `config_gui.html` (the Run on board card, Rahaf's request).
3. Optional, at the bench:
   - repeat A1/A2 with a ground spring and record the probe model;
   - a series resistor test if the chip's rating requires it;
   - verify pairs 5-15 as loopbacks when the chip needs them (their outputs were checked
     in EXP-07, the inputs LA21-31 were not);
   - press the editor's **Run on board** once with the board connected (only Check was
     tried on the board);
   - ~~PISO capture with a real signal~~: done in EXP-08 (J2-17 and J3-16).
4. If the pin map changes: edit `pin_map` in `config/nemo_config.yaml`, then run
   `python -m nemo_ctl.gen_svh --chip` (regenerates the package + XDC with the DRIVE 4 rule),
   `scripts/run_chip_sim.sh`, and rebuild `chip_top`. `test_gen_chip.py` fails if the
   committed generated files are stale.

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
- Don't edit `fpga/constraints/chip_top.xdc` or `fpga/src/gen/chip_pkg.sv` by hand: edit the
  config's `pin_map` and regenerate (`gen_svh.py --chip`). Same for `vchip_top.xdc` /
  `vchip_pkg.sv` (`config/exp08_vchip.yaml`, `gen_svh.py --vchip`).
- Don't program a top with another top's jumpers on (see "Board setup").
- Don't call the virtual chip "the chip": no array, no ADC/TDC, and phirst comes from `pulse`.

## Key files

| Thing | Path |
|---|---|
| Shared project context (read first) | `CLAUDE.md` |
| Chronological log, newest first | `docs/WORKLOG.md` |
| Lab-user manual (GUI §3.5, JTAG link §6.4, Phase 7 §8) | `docs/USER_MANUAL.md` |
| Spec, pin table (+ the DRIVE 4 note), open questions | `docs/controller_spec.md` |
| Questions for Dima (draft) | `docs/questions_for_dima_2026-10-22.md` |
| Link register maps + JTAG scan format | `docs/link_register_map.md` |
| Experiments | `docs/experiments/EXP-01_*.md` ... `EXP-08_virtual_chip.md` |
| Pin verification per pair | `docs/pin_verification.md` |
| Bugs / decisions | `docs/issues.md`, `docs/decisions.md` |
| Build / program | `scripts/create_project.tcl`, `scripts/program_board.tcl` |
| Sims | `scripts/run_phase{3_sims,4_sim,5_link_sim,6_sim,7_sim}.sh`, `scripts/run_jtag_sim.sh` |
| JTAG PC side | `tools/nemo_ctl/jtag.py`, `scripts/jtag_server.tcl` |
| Chip pipeline | `config/nemo_config.yaml` (`pin_map`), `tools/nemo_ctl/{fmc_pins,sequence,gen_svh}.py`, generated `fpga/src/gen/chip_pkg.sv` + `fpga/constraints/chip_top.xdc`, `fpga/src/chip_top.sv`, `fpga/tb/chip_top_tb.sv`, `config/chip_sim_test.yaml`, `scripts/run_chip_sim.sh`; C5: `tools/nemo_ctl/mode_seq.py`, `cli run-mode`, `gui.py` Run on board, `config/exp07_test.yaml`, `scripts/repeat_mode.py`; C6: `fpga/src/{virtual_chip,vchip_top}.sv`, `config/exp08_vchip.yaml`, generated `fpga/src/gen/vchip_pkg.sv` + `fpga/constraints/vchip_top.xdc`, `fpga/tb/vchip_top_tb.sv`, `scripts/run_vchip_sim.sh`, `scripts/repeat_seq.py` |
| Python tool (module list, incl. `gui.py`, `waves.py`) | `tools/nemo_ctl/README.md` |
| The task brief | `generic_controller_prompt.md` |

## Who's who

- **Rahaf**: at the bench 2026-10-26 (EXP-06, the DRIVE 4 decision, the EXP-03 rerun, the
  review decisions); did Phases 0-5.
- **Yazan**: owns the repo; did Phases 6-7, the JTAG bring-up runs (10-22) and the GUI.
- **Dima**: SIPO/PISO RTL and chip details; the open questions go to him.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
