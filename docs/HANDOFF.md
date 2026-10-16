# Handoff — NEMO generic controller, Phases 0-5

> For a fresh agent picking this up with no prior context. Read this, then
> `CLAUDE.md` and `docs/WORKLOG.md` (newest entry first) for full detail.

## State as of 2026-10-16, commit `5b045ef` on `main`

Phases 0-4 and Phase 5's **software side** are built, tested, documented, and pushed to
`main` on `https://github.com/yazanrabea/FPGA-controller.git`. **No phase past 3 has been
run on real hardware yet** — this environment has no Vivado license and no physical
ZedBoard. That is the only thing blocking further progress; nothing is unfinished in the
sense of "not designed yet."

| Phase | What it is | Status |
|---|---|---|
| 0 | Spec: 26-signal pin table, config schema, link choice | Done, approved |
| 1 | Config file + Python core | Done |
| 2 | Interactive CLI wizard | Done |
| 3 | RTL cells (`sig_cell`/`cap_cell`/`run_ctrl`) | Done, **simulated only** |
| 4 | `phase4_loopback_top` (compile-time config) | RTL/software done, **hardware step not run** (`docs/experiments/EXP-01...md`) |
| 5 | `phase5_link_top` (runtime UART link) | RTL/Python/CLI done, **simulated only, hardware step not run** (`docs/experiments/EXP-02...md`) |
| 6-8 | SIPO/PISO, mode sequencer, chip-ready checklist | Not started |

## The one real blocker

The USB-UART adapter's PMOD pin assignment and bank voltage (3.3V vs VADJ/1.8V) was
never confirmed against the ZedBoard reference manual, going all the way back to Phase 0
(`docs/controller_spec.md` §9). `fpga/constraints/phase5_link_top.xdc` deliberately
leaves `rxd`/`txd` unconstrained because of this. **Do not invent a pin or voltage** —
this has to be checked against the actual board/manual by someone with physical access,
then the XDC updated.

Phase 4's hardware bring-up (`EXP-01`) has no such blocker — it only needs Vivado + the
board + jumper wires + a multimeter, no new wiring decision. If whoever picks this up has
board access but hasn't resolved the PMOD question yet, **run EXP-01 first**, then
resolve the PMOD question, then run EXP-02.

## What to do next (in order)

1. **If you have Vivado + a ZedBoard**: run `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`
   end to end, filling in its results table with real readings (not simulated guesses).
2. Confirm the PMOD bank voltage (see above), update the XDC, then run
   `docs/experiments/EXP-02_phase5_link_bringup.md` the same way — its centerpiece check
   is changing `test_clock`'s frequency from the PC *while running* and seeing it change
   on the multimeter/scope, with no re-synthesis.
3. **If you do NOT have hardware access**: there is no more software work to do on
   Phases 4/5 — don't invent hardware results or mark either phase "done". Either wait,
   or move on to designing (not yet building) Phase 6 (SIPO/PISO) per
   `generic_controller_prompt.md`, clearly marked as unverified/software-only like
   everything above it.
4. Whatever you do, **document it as you go** per `CLAUDE.md` §9 — a WORKLOG entry,
   tag every result `[simulated]` or `[measured on board]`, never claim a hardware
   result that wasn't actually measured.
5. Once EXP-01 and EXP-02 both pass on real hardware, update `CLAUDE.md` §5/§7 and
   `docs/USER_MANUAL.md`'s status table, and only then are Phases 4-5 actually "done"
   per the project's own rule ("a phase is not done until ... I have followed it
   successfully myself" — Rahaf has to run it, not just an agent in simulation).

## Key files to know about

| Thing | Path |
|---|---|
| Shared project context (read first, always) | `CLAUDE.md` |
| Chronological log — read newest entry first | `docs/WORKLOG.md` |
| Lab-user-facing manual (setup + every phase's commands) | `docs/USER_MANUAL.md` |
| Phase 0 spec, pin table, open questions, link-protocol history | `docs/controller_spec.md` |
| Phase 5's concrete byte-level register map | `docs/link_register_map.md` |
| Pending hardware procedures | `docs/experiments/EXP-01...md`, `EXP-02...md` |
| RTL sources / testbenches | `fpga/src/`, `fpga/tb/` |
| Python config/wizard/link tool | `tools/nemo_ctl/` (see its own `README.md`) |
| Sim-only CI-equivalent checks | `scripts/run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh`; `python3 -m pytest tools/nemo_ctl/tests` (102 tests) |

## Things a new agent should NOT do

- Don't invent a PMOD pin number or bank voltage — flag it as TBD and point to the
  ZedBoard reference manual instead, same as this handoff does.
- Don't mark a hardware exit criterion met from simulation alone. `[simulated]` and
  `[measured on board]` are not interchangeable anywhere in this project's docs.
- Don't touch `CLAUDE.md`, XDCs, or `generic_fmc_*` files outside a PR — they're shared
  files per `CLAUDE.md` §10.
- Don't merge to `main` without being explicitly asked — Rahaf and Yazan each review
  the other's PRs per `CLAUDE.md` §10's branch-per-feature workflow.

## Who's who

- **Rahaf** — this session's user, owns `feature/rahaf-*` branches, most recently
  `feature/rahaf-user-manual` (now merged to `main` as of this handoff).
- **Yazan** — partner, owns the repo (`github.com/yazanrabea/FPGA-controller`), works on
  his own `feature/<name>-<topic>` branches per `CLAUDE.md` §10.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
