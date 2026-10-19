# Handoff — NEMO generic controller (Phases 0-5 built, Phase 6 started, EXP-01 ready to run)

> For a fresh agent picking this up with no prior context. Read this, then `CLAUDE.md`
> and `docs/WORKLOG.md` (newest entry first, 2026-10-19) for full detail.

## State as of 2026-10-19, `main` on `https://github.com/yazanrabea/FPGA-controller.git`

| Phase | What it is | Status |
|---|---|---|
| 0 | Spec: 26-signal pin table, config schema, link choice | Done, approved |
| 1 | Config file + Python core | Done |
| 2 | Interactive CLI wizard | Done |
| 3 | RTL cells (`sig_cell`/`cap_cell`/`run_ctrl`) | Done, **simulated only** |
| 4 | `phase4_loopback_top` (compile-time config) | **Bitstream now builds in Vivado** (timing met); hardware run EXP-01 **not started** — board wasn't connected yet |
| 5 | `phase5_link_top` (runtime UART link) | Simulated only; EXP-02 blocked on PMOD pin/voltage (see below) |
| 6 | SIPO/PISO against Dima's model | **Plan approved; step 6.0 done; 6.1-6.5 not started** |
| 7-8 | Mode sequencer, chip-ready checklist | Not started |

## Big change since the last handoff: the Windows lab PC

Work now happens on the **Windows 11 lab PC** (`C:\Users\LAB\Desktop\yazan_rahaf\FPGA-controller`),
which has **Vivado 2022.1** (`C:\Xilinx\Vivado\2022.1`, synthesis license OK) and the
**ZedBoard physically in the lab**. No Icarus/yosys there.

- Shell: use Git Bash for the `.sh` scripts. Call Vivado as
  `cmd //c "C:\\Xilinx\\Vivado\\2022.1\\bin\\vivado.bat" -mode batch -nojournal -nolog -source <tcl> -tclargs ...`.
- Python: use `python`, not `python3` (`python3` is the Windows Store stub).
  `pip install -r tools/requirements.txt` has been done.
- Sims: `scripts/run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh` pick
  Icarus if installed, else Vivado xsim (`scripts/sim_lib.sh`; force with `SIM=xsim`).
- `.gitattributes` keeps `*.sh` LF (this PC has `core.autocrlf=true`).
- **Memory is tight on this PC**: a background `git push` was killed by Claude Code for
  low memory. Don't leave long jobs idling in the background.
- **`git push` may stall on Git Credential Manager** (GitHub sign-in window on the lab
  screen). If a push hangs, ask Rahaf to sign in; don't retry blindly.

## Last verified results (2026-10-19)

- **[simulated, xsim 2022.1]** all 8 testbenches pass via the repo scripts: `sig_cell_tb`
  28, `cap_cell_tb` 16, `run_ctrl_tb` 9, `integration_tb` 16, `phase4_loopback_top_tb` 21,
  `uart_tb` 12, `link_ctrl_tb` 22, `phase5_link_top_tb` 7.
- **[not hardware]** `python -m pytest tools/nemo_ctl/tests`: 101 passed, 1 skipped
  (expected skip: `test_link.py:382` only runs without pyserial).
- **[Vivado implementation report, not a measurement]** `phase4_loopback_top`: no errors,
  no critical warnings, WNS +3.702 ns / WHS +0.117 ns, 440 LUTs / 415 FFs / 24 IOBs.
- yosys utilization estimate not re-run (not installed on the lab PC).

Fixed this session (detail in `docs/issues.md`): two testbench constructs Icarus accepted
but xsim rejects; generated package renamed `fpga/src/gen/nemo_cfg_pkg.svh` -> **`.sv`**
because Vivado synthesis never compiles `.svh` (the first real Vivado build failed on it).

## What to do next (in order)

1. **EXP-01 (Phase 4 hardware run)** — `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`.
   Rahaf was asked to: put J18 (VADJ) on **1V8**; wire J3-0↔J3-16, J3-1↔J2-17,
   J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20 (P column); all switches down; connect PROG
   micro-USB **J17**; power on. Then:
   - Build if `build/` is missing (git-ignored): `create_project.tcl -tclargs phase4_loopback_top build`.
   - Program: `scripts/program_board.tcl -tclargs phase4_loopback_top` (prints
     `no JTAG target found` if the board isn't connected — that's what it printed last time).
   - Walk Rahaf through EXP-01 §3 pair by pair. **She** reads LEDs/multimeter; you record
     exactly what she reports in §4 tagged [measured on board]. Never fill §4 yourself.
2. **Phase 6, steps 6.1-6.5** (plan approved by Rahaf 2026-10-19, recorded in WORKLOG):
   - **Key finding**: the generic cells meet Dima's timing — no dedicated engines.
     SIPO load = `rst_sipo` low PULSE; `clk_sipo` CLOCK cycles=136 (starts high -> exactly
     136 rising edges, ends low); `sipo_in` SERIAL MSB-first, `shift_strobe` = `clk_sipo`
     `falling_edge`, delay a few ticks *before* `clk_sipo`'s so bit 135 is stable at edge 1;
     `cs` PULSE after the 136th edge. PISO read = `clk_piso` CLOCK cycles=168 (edge 1 =
     load, 167 shifts); `shift` PULSE rising inside clk_piso's first low phase, width
     >= 167 periods; `cap_cell` SERIAL 168 bits, `capture_strobe` = `clk_piso`
     `falling_edge` (first falling edge samples bit 1 before any shift). Validator rule:
     clk_piso high time >= 3 ticks + chip/wire delay (2-FF sync latency).
   - 6.1 `tools/nemo_ctl/sipo_piso.py`: 136-bit frame packer (raw + `sel` slice view per
     Dima's RTL), 168-bit decoder -> 4 stages x {out1[13:0], tdc_out1[6:0], out0[13:0],
     tdc_out0[6:0]}, PISO0 first; profile builders; validator rules; pytest.
   - 6.2 `config/phase6_sipo_piso.yaml` (SIPO_LOAD, PISO_READ) + `gen_svh.py` support;
     data-change/sampling edges and polarities are config fields marked UNCONFIRMED.
   - 6.3 `fpga/src/phase6_sipo_piso_top.sv`: `run_ctrl` + `sig_cell` (SERIAL_W=136) +
     `cap_cell` (CAP_W=168), strobe source/edge selected by config parameters. Sim only,
     no XDC (no chip-pin -> LA_P map yet).
   - 6.4 `fpga/tb/phase6_sipo_piso_tb.sv`: our controller + Dima's **unmodified**
     `fpga/reference/dima_blocks/` (`sipo_wrapper`, `sipo`, `piso2`); stub
     `ANTENNA_18_SVT_WTN` and `DLY3_X4_18_SVT_WTN` as buffers; drive `phirst` from the TB;
     chain 4x `piso2` in the TB (PISO3.prev=0, PISOk.prev=PISO(k+1).serial_out, read
     PISO0). Exit: known frame -> correct `sel[7:0]` + each `sel[23:8]` slice;
     known out/tdc values -> correct 168-bit decode. Run in **xsim** (and Icarus if present).
   - 6.5 docs: WORKLOG, issues/decisions, USER_MANUAL section, CLAUDE.md §6/§7.
   - Known quirks of Dima's model to *document, not fix* (`docs/controller_spec.md` Q1/Q2):
     `sipo_wrapper`'s reset loads `sel[23:8]` while `parallel_out` is also reset (slice
     [23:8] never reaches `sel`); `index` overruns after the 7th `phirst`; `sipo_out` is
     `shift_reg[0]` (echo of `sipo_in`), not a chain output.
   - Out of scope (deferred to Phase 7, approved): widening the Phase 5 link's 16-bit
     DATA/CAPTURE registers for 136/168-bit frames.
3. **EXP-02 (Phase 5 hardware)** — still blocked: the USB-UART adapter's PMOD pin and bank
   voltage were never confirmed against the ZedBoard reference manual
   (`docs/controller_spec.md` §9). `phase5_link_top.xdc` leaves `rxd`/`txd` unconstrained
   on purpose. **Do not invent a pin or voltage.**

## Working rules Rahaf set (2026-10-19)

- **Push directly to `main` after each passing step**: commit -> `git pull --rebase origin main`
  -> `git push origin main`. This replaces the CLAUDE.md §10 PR flow for her work, shared
  files included (she approved editing scripts, `gen_svh.py`, `CLAUDE.md` directly).
- **Stop for her approval after each phase** (Phase 6 ends after 6.5).
- Document every step per CLAUDE.md §9; commit docs with the code change.

## Things a new agent should NOT do

- Don't invent a PMOD pin number, bank voltage, or chip behaviour.
- Don't mark a hardware exit criterion met from simulation or a Vivado report.
  `[simulated]` and `[measured on board]` are never interchangeable.
- Don't program the board until Rahaf confirms VADJ is on 1V8 and the jumpers/switches
  are set per EXP-01.
- Don't edit Dima's files in `fpga/reference/dima_blocks/`; stub around them.

## Key files

| Thing | Path |
|---|---|
| Shared project context (read first) | `CLAUDE.md` |
| Chronological log, newest first | `docs/WORKLOG.md` |
| Lab-user manual | `docs/USER_MANUAL.md` |
| Phase 0 spec, pin table, open questions Q1-Q9 | `docs/controller_spec.md` |
| Phase 5 register map | `docs/link_register_map.md` |
| Hardware procedures | `docs/experiments/EXP-01...md`, `EXP-02...md` |
| Bugs and fixes | `docs/issues.md` |
| Build / program | `scripts/create_project.tcl`, `scripts/program_board.tcl` |
| Sims | `scripts/run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh` (`sim_lib.sh`) |
| The task brief (phases, exit criteria) | `generic_controller_prompt.md` |
| Dima's SIPO/PISO model | `fpga/reference/dima_blocks/` |

## Who's who

- **Rahaf**: this session's user, at the lab PC with the board.
- **Yazan**: partner, owns the GitHub repo; works on his own `feature/<name>-<topic>` branches.
- **Supervisor**: Ilan Lipschutz, ASIC² Lab, Technion, NEMO project.
