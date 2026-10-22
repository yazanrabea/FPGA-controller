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
| 4 | `phase4_loopback_top` (compile-time config, loopback pairs 0-4) | Bitstream builds in Vivado (timing met); **EXP-01 on the board not run** |
| 5 | `phase5_link_top` (runtime UART link) | Simulated only; **EXP-02 blocked**: PMOD pin and bank voltage never confirmed |
| 6 | SIPO load / PISO read from generic cells, against Dima's RTL | Done **[simulated, Icarus 12]** 69/69; **xsim run with Dima's unmodified `sipo_wrapper.sv` not done**; no hardware step (no chip-pin map) |
| 7 | Mode sequencer (step engine), round 1 | Engine + loopback top done **[simulated, Icarus 12]** 31/31 + 27/27; **EXP-03 on the board not run, no Vivado build yet**; round 2 (link v2) not started |
| 8 | Chip-ready checklist | Not started (needs Dima's answers + chip-pin map) |

Phases 6 and 7 were pushed straight to `main` on 2026-10-22 at Yazan's request, **without
Rahaf's review** (`docs/decisions.md`). PR #1 (Phase 6) describes what to check.

## What changed since the last handoff (2026-10-19)

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

## Last verified results (2026-10-22, Yazan's laptop, before the push to `main`)

- **[not hardware]** `python -m pytest tools/nemo_ctl/tests` (from `tools/`): 176 passed,
  1 skipped (expected skip: `test_link.py`, only runs without pyserial).
- **[simulated, Icarus 12]**:
  - Phase 3 `sig_cell_tb` 28, `cap_cell_tb` 16, `run_ctrl_tb` 9, `integration_tb` 16
  - Phase 4 `phase4_loopback_top_tb` 21
  - Phase 6 `phase6_sipo_piso_tb` 69 (with the `sipo_wrapper` stand-in)
  - Phase 7 `seq_engine_tb` 31, `phase7_seq_loopback_top_tb` 27 (time-scaled ×1e-4 package)
  - Phase 5 doesn't elaborate under Icarus 12.
- **[simulated, xsim 2022.1, 2026-10-19 on the lab PC]** Phases 3-5, all 8 testbenches.
  **Phases 6 and 7 have never been run in xsim.**
- Generated packages (`nemo_cfg_pkg.sv`, `phase6_cfg_pkg.sv`, `phase7_cfg_pkg.sv`) regenerate
  byte-identical from their YAML.

## What to do next (in order)

1. **Lab PC, xsim:** `SIM=xsim scripts/run_phase6_sim.sh` and `SIM=xsim scripts/run_phase7_sim.sh`.
   These are the first runs against Dima's unmodified `sipo_wrapper.sv`, and the first xsim
   runs of Phases 6/7 (xsim is stricter). Phase 6 isn't done until this passes.
2. **Lab PC, Vivado:** rebuild `phase4_loopback_top` once
   (`create_project.tcl -tclargs phase4_loopback_top build`). `create_project.tcl` globs
   `fpga/src/*.sv` and `fpga/src/gen/*.sv`, so the Phase 6/7 tops and packages are now part
   of every project; Icarus parses them, but Vivado hasn't seen them yet. If it breaks,
   suspect those files first.
3. **EXP-01** (Phase 4 on the board): `docs/experiments/EXP-01_*.md`. VADJ J18 on **1V8**,
   jumpers J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20 (P column), switches down,
   PROG USB J17. Program with `scripts/program_board.tcl -tclargs phase4_loopback_top`. The
   person at the board reads the LEDs and meters; you record exactly what they report, tagged
   [measured on board]. Never fill a results table yourself.
4. **EXP-03** (Phase 7 on the board, same jumpers): build `phase7_seq_loopback_top`, then the
   3 runs in `docs/experiments/EXP-03_*.md`: full sequence, J2-20 pulled → FAULT, abort.
   That's Phase 7's hardware exit criterion.
5. **Send Dima the questions** (`docs/questions_for_dima_2026-10-22.md`) after the team
   reads them. The answers unblock Phase 8 and the real INFERENCE/WRITE sequences.
6. **Phase 7 round 2, link v2** (not started; can be done off the board): step table and
   136/168-bit DATA/CAPTURE over the UART link, `link_ctrl.sv` + `tools/nemo_ctl/link.py`
   + `program_verify` bound to the real link. Hardware test still needs **EXP-02 unblocked**:
   confirm the PMOD pin and bank voltage in the ZedBoard reference manual
   (`docs/controller_spec.md` §9). **Do not invent a pin or voltage.**
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
| Phase 5 register map | `docs/link_register_map.md` |
| Hardware procedures | `docs/experiments/EXP-01_*.md`, `EXP-02_*.md`, `EXP-03_*.md` |
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
