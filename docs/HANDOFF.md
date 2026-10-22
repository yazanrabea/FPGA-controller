# Handoff — NEMO generic controller (Phases 0-7 built; Phases 4, 5 and 7 verified on the board)

> For a fresh agent picking this up with no prior context. Read this, then `CLAUDE.md`
> and `docs/WORKLOG.md` (newest entry first). Rewritten 2026-10-22, end of the lab-PC
> session (Yazan at the board, Claude on the lab PC).

## State as of 2026-10-22, `main` on `https://github.com/yazanrabea/FPGA-controller.git`

| Phase | What it is | Status |
|---|---|---|
| 0-2 | Spec, config file + Python core, CLI wizard | Done |
| 3 | RTL cells `sig_cell` / `cap_cell` / `run_ctrl` | [simulated]; used by every board test below |
| 4 | `phase4_loopback_top` (compile-time config, loopback pairs 0-4) | **EXP-01 PASS [measured on board]** |
| 5 | Runtime link to the PC (`link_frame` + `link_ctrl`) | **EXP-02 PASS over JTAG [measured on board]**: clock changed live from the PC. The UART variant has never run on hardware (no adapter) |
| 6 | SIPO load / PISO read against Dima's RTL | [simulated] 69/69 in Icarus and xsim (Dima's unmodified `sipo_wrapper.sv`). No hardware step possible yet (no chip-pin map) |
| 7 | Mode sequencer | Round 1 (compile-time table): **EXP-03 PASS**. Round 2 (table from the PC): **EXP-04 PASS over JTAG**, incl. `program_verify()` on hardware |
| — | PC link over JTAG (J17) | **J1-J5 done**: EXP-05 feasibility PASS, bridge RTL, JTAG link tops, Python transport, EXP-02 + EXP-04 |
| 8 | Chip-ready checklist | Not started: needs Dima's answers and the chip-pin -> FMC map |

### The PC link: JTAG over the J17 PROG cable (decided 2026-10-22)

The kit has no USB-UART adapter, so the link's bytes ride BSCANE2 **USER4** scans over the
programming cable (`docs/decisions.md`). The protocol and register maps are unchanged; only
the transport is different.
- **FPGA**: `fpga/src/jtag_link_bridge.sv` + `jtag_link_bscan.sv`. Same ports as
  `uart_rx`/`uart_tx`, so `link_frame` connects unchanged.
- **Tops**: `phase5_link_top` / `phase7_link_top` have `parameter string LINK = "UART"`;
  `phase5_link_jtag_top` / `phase7_link_jtag_top` set it to `"JTAG"` and have no
  `rxd`/`txd` ports. These are the ones to build and program.
- **PC**: `tools/nemo_ctl/jtag.py` (`JtagTransport`, `XsdbScanPort`, `open_jtag()`) runs
  `scripts/jtag_server.tcl` inside Vivado's **xsdb**, which holds `jtag lock`. CLI:
  `python -m nemo_ctl.cli link|seq ... --jtag` (instead of `--port`).
- **Scan format and the rules the PC must follow**: `docs/link_register_map.md`, section
  "Transport: JTAG over J17".
- **Speed**: ~1.2 ms per 128-byte scan, ~100 kB/s each way. Each CLI command spends 2-6 s
  starting xsdb; use one Python session (`open_jtag(...)`) when timing matters (EXP-04 Run 3).
- **Facts found on the board (EXP-05)**:
  - hw_server scans **USER1** on its own and overwrote data there, so the link uses USER4;
  - xsdb `-hex` strings are byte 0 first;
  - scans must be full length, because the ARM DAP's bypass bit sits in the chain ahead of
    the FPGA.

## Machines

- **Windows lab PC** (`C:\Users\LAB\Desktop\yazan_rahaf\FPGA-controller`): Vivado 2022.1 at
  `C:\Xilinx\Vivado\2022.1` (synthesis license works; xsdb in the same `bin`), the ZedBoard.
  No Icarus/yosys.
  - Run `scripts/*.sh` from Git Bash; they fall back to Vivado xsim (`scripts/sim_lib.sh`;
    `SIM=xsim` to force).
  - Vivado:
    `cmd //c "C:\\Xilinx\\Vivado\\2022.1\\bin\\vivado.bat" -mode batch -nojournal -nolog -source <tcl> -tclargs ...`.
    A full build is 5-10 min; the link tops take longer than one 10-minute tool call, so
    run them in the background.
  - `python`, not `python3` (Windows Store stub). Packages from `tools/requirements.txt` are installed.
  - **Git identity is set repo-locally**: `yazanrabea <yazan.rabea@campus.technion.ac.il>`
    (asked of Yazan 2026-10-22). Someone else committing here should set their own.
  - `git push` works (GitHub signed in via Git Credential Manager, 2026-10-22). If it stalls,
    a sign-in window is waiting on the lab screen.
  - Memory is tight: a background job idling for a long time can be killed by Claude Code.
- **Yazan's laptop** (Windows 11): no Vivado.
  - Icarus Verilog 12 at `C:\iverilog\bin`. It rejects a few things xsim accepts:
    `return` in a task, Dima's `sipo_wrapper.sv` (use `fpga/tb/sipo_wrapper_icarus_shim.sv`),
    and `fork/join_any` + `disable`.
  - `python` 3.10 has the packages.
  - `gh` signed in as `yazanrabea`.

## Board setup that works (all of today's experiments)

- ZedBoard. **J18 (VADJ) on 1V8**: it was found on 2V5 earlier on 2026-10-22; move it with
  SW8 off. A reading of 1.8 V on J3-4 (HIGH pair) confirms it.
- PROG micro-USB on **J17**. Symptom of a bad cable: *no Digilent USB device in Windows at
  all* (`Get-PnpDevice`), not a Vivado error.
- Jumpers on the HTG-FMC P column: J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19,
  J3-4↔J2-20 (pairs 0-4).
- Multimeter (Fluke 115, DC V): black probe on the outer metal shell of an SMA jack on the
  HTG board. Not the Pmod pins, where GND sits next to 3.3 V.
- Program: `scripts/program_board.tcl -tclargs <top>`. It prints `no JTAG target found` if
  the board isn't reachable. Bitstreams live in `build/` (git-ignored); rebuild with
  `scripts/create_project.tcl -tclargs <top> build`.
- The person at the board reads the LEDs and the meter; you record exactly what they report,
  tagged [measured on board]. Ask again if a report is ambiguous (e.g. "000", "ld2").

## Last verified results (2026-10-22, lab PC)

- **[not hardware]** pytest (from `tools/`: `python -m pytest nemo_ctl/tests`): 213 passed,
  1 skipped (expected skip: a test that only runs without pyserial).
- **[simulated, xsim 2022.1]**, all through the repo scripts:
  - Phase 3: 28 / 16 / 9 / 16.
  - Phase 4: `phase4_loopback_top_tb` 21, `phase4_serial_tb` 2.
  - Phase 5: 12 / 22 / 7.
  - Phase 6: 69.
  - Phase 7: 40 / 10 / 27 / 21.
  - JTAG (`scripts/run_jtag_sim.sh`): `jtag_echo_core_tb` 9, `jtag_link_bridge_tb` 19,
    `jtag_link_e2e_tb` 11.
- **[Vivado reports]**, sys clk WNS, all met:
  - `phase4_loopback_top` +4.001 ns;
  - `phase7_seq_loopback_top` +0.100 ns (tight, see below);
  - `phase5_link_jtag_top` +0.206 ns;
  - `phase7_link_jtag_top` +0.427 ns;
  - `jtag_echo_top` +9.24 ns.
- **[measured on board]** EXP-01, EXP-02 (JTAG), EXP-03, EXP-04 (JTAG), EXP-05: all PASS.
  Details in each `docs/experiments/EXP-0*_*.md` §results and the WORKLOG.

## Bugs found today that a reviewer should know about (all in `docs/issues.md`)

- **`phase4_loopback_top` SERIAL checker compared 0xA5 with 0x00.** Found on the board; it
  also *passed* with the jumper pulled. Fixed, and covered by `fpga/tb/phase4_serial_tb.sv`.
- **`link_ctrl.sv` read path divided by 24**, and `phase5_link_top` failed timing by 6.1 ns.
  Replaced with range compares. This was in the original Phase 5 code.
- **`seq_engine.sv` COND_AFTER** had a subtract on a late path, so `phase7_link_jtag_top`
  missed by 0.037 ns. Added a `step_cnt1` register; same behaviour.
- **xsim-only testbench problems**: use-before-declaration (`seq_engine_tb`), multi-driven
  `always_ff` (`link_ctrl_tb`), generated package as `.svh` (Vivado never compiles `.svh`).
- **Open: one unexplained LD3 (fault latch) transient on pair 4 in EXP-01.** Retests were
  clean; suspected a jumper bumped.

## What to do next (in order)

1. **Rahaf reviews what went to `main` without her review:**
   - Yazan's round 2 (the `link_frame` / `link_ctrl` refactor);
   - today's fixes (`phase4_loopback_top.sv`, `link_ctrl.sv` `read_byte`, `seq_engine.sv`
     `step_cnt1`);
   - the whole JTAG link (`jtag_*`, `*_jtag_top`, `tools/nemo_ctl/jtag.py`,
     `scripts/jtag_server.tcl`).
2. **Send Dima the questions** (`docs/questions_for_dima_2026-10-22.md`, drafted, not sent).
   His answers unblock the chip-pin -> FMC map, the real INFERENCE/WRITE sequences and Phase 8.
3. **Scope / ILA measurements** (CLAUDE.md §7 item 2). Nothing today measured frequency,
   duty, pulse width or edges with a scope; only multimeter averages and LEDs.
4. **Verify LA pairs 5-15** (CLAUDE.md §7 item 1); `docs/pin_verification.md` has pairs 0-4.
5. Optional:
   - rerun EXP-03 on the current `phase7_seq_loopback_top` bitstream (the `seq_engine` fix
     came after the board run; the logic is equivalent);
   - if `phase7_seq_loopback_top`'s +0.100 ns ever goes negative, register its per-step
     table entry (as `seq_bank` does).
6. The UART link variant stays untested on hardware. Only needed if someone buys a 3.3 V
   USB-UART adapter for Pmod JA (JA1 = Y11, JA2 = AA11, Bank 13 at 3.3 V,
   `docs/controller_spec.md` §9). Don't invent an adapter pinout.

## Working rules

- **Yazan (2026-10-22, this session):** approves each step; said "push it" for each commit
  today. Ask before pushing to `main`. Approval of one push doesn't cover the next.
- **Rahaf (2026-10-19):** push directly to `main` after each passing step (commit ->
  `git pull --rebase origin main` -> push); stop for her approval after each phase.
- Both: document every step per CLAUDE.md §9, docs in the same commit as the code; keep the
  "Currently working on" table in `docs/WORKLOG.md` current.

## Things a new agent should NOT do

- Don't invent a pin number, bank voltage, adapter pinout or chip behaviour.
- Don't mark a hardware result from simulation or a Vivado report. `[simulated]` and
  `[measured on board]` are never interchangeable.
- Don't program the board until the person there confirms VADJ on 1V8 and the
  jumpers/switches match the experiment.
- Don't put a JTAG user register on USER1 (hw_server writes to it). Don't send short
  scans over JTAG.
- Don't edit Dima's files in `fpga/reference/dima_blocks/`; stub around them.
- Don't build a bitstream from a time-scaled package (Phase 4 serial test, Phase 7): the
  sim scripts keep those in temp folders.
- Don't treat "resets asserted before the first APPLY" as fixed for tops that don't use
  `seq_engine` (its preload fixes it; EXP-03 measured `rst` at 1.8 V before START).

## Key files

| Thing | Path |
|---|---|
| Shared project context (read first) | `CLAUDE.md` |
| Chronological log, newest first | `docs/WORKLOG.md` |
| Lab-user manual (JTAG link = §6.4, Phase 7 = §8) | `docs/USER_MANUAL.md` |
| Spec, pin table, open questions | `docs/controller_spec.md` |
| Questions for Dima (draft) | `docs/questions_for_dima_2026-10-22.md` |
| Link register maps + JTAG scan format | `docs/link_register_map.md` |
| Experiments (procedures + results) | `docs/experiments/EXP-01_*.md` ... `EXP-05_*.md` |
| Pin verification per pair | `docs/pin_verification.md` |
| Bugs and fixes / decisions | `docs/issues.md`, `docs/decisions.md` |
| Build / program | `scripts/create_project.tcl`, `scripts/program_board.tcl` |
| Sims | `scripts/run_phase{3_sims,4_sim,5_link_sim,6_sim,7_sim}.sh`, `scripts/run_jtag_sim.sh` |
| JTAG PC side | `tools/nemo_ctl/jtag.py`, `scripts/jtag_server.tcl`, `scripts/jtag_echo_test.tcl` (J1 test) |
| Python tool (module list) | `tools/nemo_ctl/README.md` |
| The task brief (phases, exit criteria) | `generic_controller_prompt.md` |
| Dima's SIPO/PISO model (reference, never edited) | `fpga/reference/dima_blocks/` |

## Who's who

- **Yazan**: owns the GitHub repo; did Phases 6-7; at the board for today's experiments.
- **Rahaf**: partner; did Phases 0-5 and step 6.0; reviews what's listed above.
- **Dima**: provided the SIPO/PISO RTL and the chip details; the open questions go to him.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
