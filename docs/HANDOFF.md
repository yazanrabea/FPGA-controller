# Handoff — NEMO generic controller (Phases 0-7 built and simulated; nothing past Phase 2 measured on the board yet)

> For a fresh agent picking this up with no prior context. Read this, then `CLAUDE.md`
> and `docs/WORKLOG.md` (newest entry first, 2026-10-22) for full detail.

## State as of 2026-10-22, `main` on `https://github.com/yazanrabea/FPGA-controller.git`

| Phase | What it is | Status |
|---|---|---|
| 0 | Spec: 26-signal pin table, config schema, link choice | Done, approved |
| 1 | Config file + Python core | Done |
| 2 | Interactive CLI wizard | Done |
| 3 | RTL cells `sig_cell` / `cap_cell` / `run_ctrl` | Done, **simulated only** |
| 4 | `phase4_loopback_top` (compile-time config, loopback pairs 0-4) | Bitstream builds in Vivado (timing met, rebuilt 2026-10-22 with the Phase 6/7 files in the project); **EXP-01 PASS on the board 2026-10-22** (found + fixed a SERIAL checker bug) |
| 5 | `phase5_link_top` (runtime UART link) | Simulated (Icarus + xsim). Vivado route **failed timing by 6.1 ns until 2026-10-22's `link_ctrl.sv` fix**, now met (+0.238 ns). **EXP-02 blocked**: no PC-link pin/adapter yet |
| 6 | SIPO load / PISO read from generic cells, against Dima's RTL | Done **[simulated]** 69/69 in Icarus 12 *and* xsim 2022.1 (xsim with Dima's unmodified `sipo_wrapper.sv`, 2026-10-22); no hardware step (no chip-pin map) |
| 7 | Mode sequencer (step engine) | Round 1 (compile-time table) and round 2 (table over UART, `cli seq`), both on `main` (round 2 merged 2026-10-22 without Rahaf's review, at Yazan's request). All **[simulated]** in Icarus 12 and xsim 2022.1: engine 40, bank 10, round-1 top 27, link top 21 (real UART). Vivado: `phase7_seq_loopback_top` bitstream built (WNS +0.248 ns); `phase7_link_top` routes and meets timing (+0.334 ns, no bitstream: no UART pins). **EXP-03 / EXP-04 on the board not run**; EXP-04 also needs the UART pin (EXP-02) |
| 8 | Chip-ready checklist | Not started (needs Dima's answers + chip-pin map) |

Phases 6 and 7 were pushed straight to `main` on 2026-10-22 at Yazan's request, **without
Rahaf's review** (`docs/decisions.md`). PR #1 (Phase 6) describes what to check.

## 2026-10-22, at the board: EXP-01 PASS, EXP-03 PASS

- **EXP-03 PASS** (Phase 7's hardware exit criterion): full sequence, FAULT, ABORT; `rst` preloaded HIGH before START.

- Phase 4's hardware exit criterion is met: all 5 signal types on pairs 0-4 [measured on board].
- The board run found a bug no simulation reached: the SERIAL checker compared 0xA5 with 0x00.
  Fixed, with a new time-scaled `fpga/tb/phase4_serial_tb.sv`.
- Open: one unexplained LD3 transient on pair 4 (`docs/issues.md`); watch LD3 in EXP-03.
- Board setup that worked: J18 on 1V8; PROG micro-USB on J17 (a bad cable shows up as *no
  Digilent USB device in Windows*, not as a Vivado error); multimeter ground on an SMA shell.
- PC link: **JTAG over J17 chosen by Yazan** (`docs/decisions.md`); plan not yet approved, no RTL.

## 2026-10-22, lab PC session (handoff steps 1-2 done)

- Every sim script passes in **xsim 2022.1** (Phases 3-7, counts as in Icarus); pytest 194 passed, 1 skipped.
- `fpga/tb/seq_engine_tb.sv`: declarations moved above first use (xsim refused it).
- `fpga/src/link_ctrl.sv`: `read_byte()` no longer divides by 24. `phase5_link_top` failed
  timing by 6.1 ns because of it (the divide dates from the original Phase 5). Same register map.
- Vivado results table, review findings: `docs/WORKLOG.md` 2026-10-22 (lab PC) entry; bugs in `docs/issues.md`.
- Lesson: route every new top in Vivado before calling it board-ready, even without a bitstream.

## What changed before that (2026-10-19 -> 2026-10-22, Yazan's laptop)

- **Phase 6** (USER_MANUAL §7): `tools/nemo_ctl/sipo_piso.py` (136-bit frame, 168-bit
  decode, timing rules), `config/phase6_sipo_piso.yaml` -> `gen_svh.py --phase6` ->
  `fpga/src/gen/phase6_cfg_pkg.sv`, `fpga/src/phase6_sipo_piso_top.sv` (sim-only top),
  `fpga/tb/phase6_sipo_piso_tb.sv` vs Dima's blocks (`scripts/run_phase6_sim.sh`).
  - **Q1 is corrected:** after `rst_sipo`, `sel[23:8]` holds the **previous** load's slice 0.
    It isn't 0. (CLAUDE.md §5, `docs/controller_spec.md` Q1.)
  - Before the first APPLY, `sig_cell` drives every pin 0, so active-low chip resets are
    *asserted*. Open item for Phase 8. The Phase 7 engine's preload avoids it.
- **Phase 7 round 1** (USER_MANUAL §8): `tools/nemo_ctl/sequence.py` (step format, checks,
  compiler, `program_verify()`), `fpga/src/seq_engine.sv`, `fpga/src/phase7_seq_loopback_top.sv`
  + `.xdc` (same pins as Phase 4 + PULLDOWN on LA16-20_P), `config/phase7_seq_loopback.yaml`
  -> `gen_svh.py --phase7` -> `fpga/src/gen/phase7_cfg_pkg.sv`, `scripts/run_phase7_sim.sh`,
  `docs/experiments/EXP-03_phase7_sequencer_loopback.md`. Design decision: the sequencer
  runs on the FPGA (tick-exact), not in Python.
- **Phase 7 round 2** (USER_MANUAL §8.6, on `main` since 2026-10-22):
  - `fpga/src/link_frame.sv`: the frame parser, split out of `link_ctrl.sv` and shared by both link tops. It writes onto a byte bus a RAM can sit behind, with a 16-byte input FIFO.
  - Phase 5: `link_ctrl.sv` now has packed ports, and its testbenches now run under Icarus 12. Writes land LEN+4 ticks after the checksum.
  - `fpga/src/seq_bank.sv`: the step-table RAM plus the prefetched next-step bank (~40 ticks per step). `seq_engine.sv` waits for it and sets LATE when it has to.
  - `fpga/src/phase7_link_top.sv` + `.xdc` (register map v2, `docs/link_register_map.md`).
  - `gen_svh.py --phase7-link` for the layout package; `link.SeqLink`; `python -m nemo_ctl.cli seq ...`; `docs/experiments/EXP-04_*.md`.
- `docs/questions_for_dima_2026-10-22.md`: 16 questions, **drafted, not sent yet**.

## Machines

- **Windows lab PC** (`C:\Users\LAB\Desktop\yazan_rahaf\FPGA-controller`): Vivado 2022.1 at
  `C:\Xilinx\Vivado\2022.1`, the ZedBoard, no Icarus.
  - Run the `scripts/*.sh` from Git Bash; they fall back to xsim (`scripts/sim_lib.sh`).
  - Call Vivado with `cmd //c "C:\\Xilinx\\Vivado\\2022.1\\bin\\vivado.bat" -mode batch -nojournal -nolog -source <tcl> -tclargs ...`.
  - Use `python`, not `python3` (the Windows Store stub).
  - Memory is tight: don't leave long jobs in the background.
  - `git push` can stall on a GitHub sign-in window: ask the person at the PC.
  - **No git identity is set**: ask for a repo-local `git config user.name/user.email` before committing (the PC is shared).
- **Yazan's laptop** (Windows 11): no Vivado.
  - **Icarus Verilog 12** (`winget install Icarus.Verilog`, at `C:\iverilog\bin`, found by `sim_lib.sh`). It rejects three things Icarus 13 and xsim accept: `return` in a task (so `uart_tb` doesn't elaborate), Dima's `sipo_wrapper.sv` (handled by `fpga/tb/sipo_wrapper_icarus_shim.sv`), and `fork/join_any`+`disable`.
  - Two Pythons: `python` (3.10) has the packages, `python3` (3.13) doesn't. `sim_python` picks the one that can import `yaml`.
  - GitHub CLI at `C:\Program Files\GitHub CLI\gh.exe`, signed in as `yazanrabea`.

## Last verified results (2026-10-22, Yazan's laptop, just before the round-2 merge to `main`)

- **[not hardware]** `python -m pytest tools/nemo_ctl/tests` (from `tools/`): 194 passed,
  1 skipped (expected skip: `test_link.py`, only runs without pyserial).
- **[simulated, Icarus 12]**:
  - Phase 3 `sig_cell_tb` 28, `cap_cell_tb` 16, `run_ctrl_tb` 9, `integration_tb` 16
  - Phase 4 `phase4_loopback_top_tb` 21
  - Phase 5 `uart_tb` 12, `link_ctrl_tb` 22, `phase5_link_top_tb` 7 (refactored link)
  - Phase 6 `phase6_sipo_piso_tb` 69 (with the `sipo_wrapper` stand-in)
  - Phase 7 `seq_engine_tb` 40, `seq_bank_tb` 10, `phase7_seq_loopback_top_tb` 27,
    `phase7_link_top_tb` 21 (time-scaled ×1e-4 tables)
- **[simulated, xsim 2022.1, 2026-10-22 on the lab PC]** all of Phases 3-7, same counts as
  Icarus (Phase 6 with Dima's unmodified `sipo_wrapper.sv`).
- Generated packages (`nemo_cfg_pkg.sv`, `phase6_cfg_pkg.sv`, `phase7_cfg_pkg.sv`,
  `phase7_link_pkg.sv`) regenerate byte-identical.

## What to do next (in order)

0. **Rahaf reviews round 2 on `main`**, above all the Phase 5 refactor (`link_frame.sv`,
   `link_ctrl.sv`, the three Phase 5 testbenches): it went in without a review.
1. ~~Lab PC, xsim runs of Phases 5-7~~ **done 2026-10-22**, all pass (see above).
2. ~~Lab PC, Vivado rebuild~~ **done 2026-10-22**: `phase4_loopback_top` and
   `phase7_seq_loopback_top` bitstreams build (in `build/`, git-ignored: rebuild with
   `create_project.tcl -tclargs <top> build` if missing).
3. ~~**EXP-01**~~ **done 2026-10-22, PASS** (`docs/experiments/EXP-01_*.md`). Kept for reference: `docs/experiments/EXP-01_*.md`. VADJ J18 on **1V8**
   (it was last seen on **2V5**, 2026-10-22: move it with SW8 off),
   jumpers J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20 (P column), switches down,
   PROG USB J17. Program with `scripts/program_board.tcl -tclargs phase4_loopback_top`. The
   person at the board reads the LEDs and meters; you record exactly what they report, tagged
   [measured on board]. Never fill a results table yourself.
4. ~~**EXP-03**~~ **done 2026-10-22, PASS**. Kept for reference: program `phase7_seq_loopback_top` (built), then the
   3 runs in `docs/experiments/EXP-03_*.md`: full sequence, J2-20 pulled → FAULT, abort.
   That's Phase 7's hardware exit criterion.
5. **Send Dima the questions** (`docs/questions_for_dima_2026-10-22.md`) after the team
   reads them. The answers unblock Phase 8 and the real INFERENCE/WRITE sequences.
6. **Unblock EXP-02 / EXP-04 (the PC link):** facts now confirmed in `docs/controller_spec.md`
   §9 (Avnet HW guide v1.1): Pmod JA = PL Bank 13 at **3.3 V**, JA1 = Y11, JA2 = AA11; the
   onboard J14 USB-UART goes to the **PS** (MIO bank 501, 1.8 V), so PL logic can't use it
   without ARM software. **The kit has no PMOD USB-UART adapter.** Options, being discussed
   with the mentor (no decision yet):
   - (a) get a 3.3 V USB-UART adapter for JA (Claude's recommendation: only XDC lines
     needed, everything else is built). The RX/TX direction depends on the adapter model.
   - (c) JTAG over J17 as a second byte transport into `link_frame` (new RTL + a Vivado
     bridge; switching to (a) later is cheap).
   - (b) J14 through the ARM (block design + software; breaks CLAUDE.md §4).
   Until then EXP-02/EXP-04 stay blocked. EXP-01 and EXP-03 need **no** PC link.
   **Do not invent a pin or an adapter pinout.**
7. Bring-up backlog (CLAUDE.md §7): verify LA pairs 5-15, scope/ILA measurements.

## Working rules

- **Rahaf (2026-10-19):** push directly to `main` after each passing step (commit →
  `git pull --rebase origin main` → push); stop for her approval after each phase.
- **Yazan (2026-10-22):** works on `feature/yazan-<topic>` branches; Phases 6/7 went to
  `main` at his request without review. Ask him before pushing to `main` or opening PRs.
- Both: document every step per CLAUDE.md §9, docs committed with the code; keep the
  "Currently working on" table in `docs/WORKLOG.md` current; don't edit a file the partner
  has listed there.

## Things a new agent should NOT do

- Don't invent a PMOD pin number, bank voltage, or chip behaviour.
- Don't mark a hardware exit criterion met from simulation or a Vivado report.
  `[simulated]` and `[measured on board]` are never interchangeable.
- Don't program the board until the person there confirms VADJ is on 1V8 and the
  jumpers/switches match the experiment.
- Don't edit Dima's files in `fpga/reference/dima_blocks/`; stub around them.
- Don't build a bitstream from a time-scaled Phase 7 package. `gen_svh.py --phase7 --time-scale`
  refuses to write one without `--out`, and the sim script keeps it in a temp folder.
- Don't treat the Phase 6 "resets asserted before APPLY" behaviour as fixed for tops that
  don't use `seq_engine`.

## Key files

| Thing | Path |
|---|---|
| Shared project context (read first) | `CLAUDE.md` |
| Chronological log, newest first | `docs/WORKLOG.md` |
| Lab-user manual (Phase 6 = §7, Phase 7 = §8) | `docs/USER_MANUAL.md` |
| Phase 0 spec, pin table, open questions Q1-Q10 | `docs/controller_spec.md` |
| Questions for Dima (draft) | `docs/questions_for_dima_2026-10-22.md` |
| Link register maps (Phase 5 and v2) | `docs/link_register_map.md` |
| Hardware procedures | `docs/experiments/EXP-01_*.md` ... `EXP-04_*.md` |
| Bugs and fixes / decisions | `docs/issues.md`, `docs/decisions.md` |
| Build / program | `scripts/create_project.tcl`, `scripts/program_board.tcl` |
| Sims | `scripts/run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh`, `run_phase6_sim.sh`, `run_phase7_sim.sh` (`sim_lib.sh`) |
| Python tool (module list) | `tools/nemo_ctl/README.md` |
| The task brief (phases, exit criteria) | `generic_controller_prompt.md` |
| Dima's SIPO/PISO model (reference, never edited) | `fpga/reference/dima_blocks/` |
| Frozen September bring-up report | `docs/NEMO_FPGA_bringup_log.tex` |

## Who's who

- **Yazan**: owns the GitHub repo; did Phases 6-7 on his laptop.
- **Rahaf**: partner, usually at the lab PC with the board; did Phases 0-5 and step 6.0.
- **Dima**: provided the SIPO/PISO RTL and the chip details; the open questions go to him.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
