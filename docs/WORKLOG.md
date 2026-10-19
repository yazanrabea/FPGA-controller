# Work log

Chronological, one entry per session. Format: see CLAUDE.md section 9.
Tag every result **[simulated]** or **[measured on board]**.

## Currently working on
| Person | Task | Branch | Files touched |
|---|---|---|---|
| Rahaf | EXP-01 (Phase 4 hardware run, board not yet connected) + Phase 6 SIPO/PISO (6.0 done, 6.1-6.5 next) | `main` (direct pushes, per Rahaf) | `scripts/*`, `tools/nemo_ctl/gen_svh.py`, `fpga/src/gen/`, `docs/experiments/EXP-01*`; next: `tools/nemo_ctl/sipo_piso.py`, `config/phase6_sipo_piso.yaml`, `fpga/src/phase6_sipo_piso_top.sv`, `fpga/tb/phase6_sipo_piso_tb.sv` |

---

## 2026-10-19, Rahaf, branch main
- Goal: re-run every Phase 3-5 simulation and the Python test suite on the lab PC before
  starting Phase 6 (SIPO/PISO); propose the Phase 6 plan; then Phase 6 step 6.0 (make the
  sim flow run on the lab PC).
- Done:
  - Lab PC is Windows 11 with **Vivado 2022.1 installed** (`C:\Xilinx\Vivado\2022.1`)
    but no Icarus Verilog/yosys, so the `scripts/run_phase*.sh` scripts (Homebrew paths)
    couldn't run here. First run: same file lists, same order, with Vivado's simulator
    (`xvlog -sv` / `xelab` / `xsim -R`) from a throwaway script outside the repo.
    Installed `tools/requirements.txt` with pip (`python`, not `python3`: on this PC
    `python3` is the Windows Store stub).
  - Step 6.0 (approved by Rahaf), fixes for everything that run turned up:
    - `scripts/sim_lib.sh` (new): picks Icarus if installed, otherwise Vivado xsim
      (Git Bash on Windows, native paths via `cygpath`); `SIM=icarus|xsim` forces one.
      `run_phase3_sims.sh`, `run_phase4_sim.sh`, `run_phase5_link_sim.sh` now use it;
      Phase 3 skips the yosys estimate with a message if yosys is missing; Phase 4 uses
      `python3` only if it really works, else `python`. Also fixed `run_phase4_sim.sh`'s
      header comment, which pointed at a nonexistent "EXP-05" (it's EXP-01).
    - `fpga/tb/link_ctrl_tb.sv`: mock uart_tx `always_ff` -> `always` (see issues.md).
    - `tools/nemo_ctl/gen_svh.py`: emits `` `timescale 1ns / 1ps `` in
      `nemo_cfg_pkg.svh`, and writes the `// Source:` path with `/` on every OS.
      `fpga/src/gen/nemo_cfg_pkg.svh` regenerated (only change: the timescale line).
    - `.gitattributes` (new): `*.sh text eol=lf`. This PC has `core.autocrlf=true`,
      which would check the scripts out with CRLF and break them in Git Bash.
    - `docs/USER_MANUAL.md` §1 + troubleshooting, `docs/issues.md`, `CLAUDE.md` §4:
      the xsim fallback and the Windows notes.
- Hardware setup: none.
- Results:
  - **[not hardware]** `python -m pytest tools/nemo_ctl/tests`: 101 passed, 1 skipped
    (`test_link.py:382`, only meaningful when pyserial is *not* installed; expected).
    Same after step 6.0.
  - **[simulated, xsim 2022.1]** before 6.0: `sig_cell_tb` 28/28, `cap_cell_tb` 16/16,
    `run_ctrl_tb` 9/9, `integration_tb` 16/16, `uart_tb` 12/12, `phase5_link_top_tb` 7/7;
    `phase4_loopback_top_tb` and `link_ctrl_tb` failed to *elaborate* (they pass under
    Icarus).
  - **[simulated, xsim 2022.1]** after 6.0, through the repo scripts themselves: all 8
    pass -- the 6 above plus `phase4_loopback_top_tb` 21/21 and `link_ctrl_tb` 22/22.
  - yosys utilization estimate not run (yosys not installed here).
- Problems / fixes: see `docs/issues.md`, "Testbenches passed in Icarus but failed to
  elaborate in Vivado xsim".
- Decisions:
  - Rahaf asked for direct pushes to `main` after each passing step (commit,
    `git pull --rebase origin main`, push), in place of the CLAUDE.md §10 PR flow, and a
    stop for approval after each phase. That covers the shared files touched here
    (`CLAUDE.md`, scripts, `gen_svh.py`) too; she approved that explicitly.
  - Phase 6 plan approved: express SIPO load / PISO read with the existing generic cells
    (no dedicated engines), compile-time config like Phase 4, testbench against Dima's
    unmodified blocks. Widening the Phase 5 link's 16-bit DATA/CAPTURE registers for
    136/168-bit frames is deferred to Phase 7.
  - ZedBoard is available in the lab, so EXP-01 (Phase 4 hardware run) goes next, built
    with the Vivado on this PC.
- EXP-01 preparation (Phase 4 hardware run, first Vivado build of this top):
  - First `create_project.tcl -tclargs phase4_loopback_top build` failed synthesis:
    `nemo_cfg_pkg` not declared (Vivado never compiles `.svh` files). Fixed by generating
    `fpga/src/gen/nemo_cfg_pkg.sv` instead (`git mv`, `gen_svh.py`, `create_project.tcl`,
    `run_phase4_sim.sh`, CLAUDE.md §6, USER_MANUAL, EXP-01, controller_spec,
    `config/phase4_loopback_test.yaml` comment). Details in `docs/issues.md`.
  - Rebuilt: bitstream `build/phase4_loopback_top/phase4_loopback_top.runs/impl_1/phase4_loopback_top.bit`.
    **[Vivado implementation report, not a measurement]**: all timing constraints met,
    WNS +3.702 ns / WHS +0.117 ns; 440 LUTs, 415 FFs, 24 bonded IOBs. Warnings reviewed,
    all expected (unused `cfg_msb_first` in 1-bit cells, `led[7:5]` tied 0, PS7 DRC
    ZPS7-1 normal for a PL-only design).
  - Cross-checked `fpga/constraints/phase4_loopback_top.xdc`: `clk`, `sw[4:0]`,
    `led[7:0]` and `fmc_pins[0..4,16..20]` are identical to `fmc_clock_loopback.xdc`
    (the XDC behind the measured pair 0 result).
  - Added `scripts/program_board.tcl` (programs the PL over JTAG with a top's built
    bitstream). Ran it: `no JTAG target found` -- board not powered/connected yet. EXP-01
    measurements not started.
- Next steps: Rahaf powers the board (VADJ 1V8, jumpers per EXP-01 §1, `sw` all 0) and
  connects PROG J17; program with `program_board.tcl`; run EXP-01 §3; then Phase 6
  steps 6.1-6.5.
- Session end: a background `git push` was killed by Claude Code (PC low on memory)
  while it waited on Git Credential Manager. Rahaf then asked to push everything and
  write a handoff for another agent: `docs/HANDOFF.md` rewritten for the current state
  (lab PC setup, EXP-01 steps, approved Phase 6 plan with the timing analysis).

---

## 2026-10-16, Rahaf, branch feature/rahaf-user-manual
- Goal: Phase 5 of `generic_controller_prompt.md` — the runtime link ("implement the
  link chosen in Phase 0 [USB-UART on a PMOD]... Python: `nemo_ctl.link` with
  `send_config(mode)`, `apply()`, `run()`, `stop()`, `read_captures()`... exit: change a
  clock frequency from the PC without re-synthesis and see it on the multimeter/scope").
  Started before Phase 4's own hardware exit criterion was met, on Rahaf's explicit
  instruction to deviate from the normal phase-gate rule and proceed anyway.
- Done:
  - `docs/link_register_map.md`: the concrete byte-level register map (superseding
    `controller_spec.md` §7-8's draft sketch) — global SCRATCH/RUN_CTRL/APPLY_CTRL/
    STATUS at 0x0000-0x0003, 5 `sig_cell` regions at 0x0010 (24 B stride: CTRL/DELAY/
    PARAM_A/PARAM_B/CYCLES/DATA/BITS), 5 `cap_cell` regions at 0x0100 (24 B stride:
    writable CTRL/BITS + read-only STATUS_FLAGS/EDGE_COUNT/PERIOD_TICKS/HIGH_TICKS/
    CAPTURE_REG), and the frame format (SOF/CMD/ADDR/LEN/DATA/CHECKSUM). Documented
    limitation: DATA/CAPTURE_REG fixed at 16 bits — fine for the 5 debug cells, not
    enough for the real chip's 136-bit SIPO data (flagged as later-phase work).
  - `fpga/src/uart_tx.sv` + `uart_rx.sv`: parameterized 8-N-1 UART, `fpga/tb/uart_tb.sv`
    **[simulated]**, 12/12 checks (round trip, busy-flag timing, back-to-back bytes,
    send-while-busy ignored, bad-stop-bit -> frame_error).
  - `fpga/src/link_ctrl.sv`: frame parser + flat register file + all 8 commands
    (WRITE_REG/READ_REG/APPLY/RUN/STOP/STATUS/READ_CAPTURE, LOAD_MODE permanently
    NACKed as unimplemented) + NACK on bad checksum or unknown CMD.
    `fpga/tb/link_ctrl_tb.sv` **[simulated]**, 22/22 checks, byte-level (bypasses real
    UART timing — that's `uart_tb.sv`'s job).
  - `fpga/src/phase5_link_top.sv` + `fpga/constraints/phase5_link_top.xdc`: reuses
    Phase 4's exact 5 debug cells (test_clock/pulse/serial/low/high) and clk/sw/led/
    fmc_pins pin assignments, but RUN/STOP/APPLY and every cfg_* field now come from
    `link_ctrl.sv`'s register file instead of compile-time constants. `rxd`/`txd`
    deliberately left unconstrained in the XDC — PMOD bank voltage still unconfirmed
    from Phase 0, see Decisions below. `fpga/tb/phase5_link_top_tb.sv` **[simulated]**,
    7/7 checks, a mock PC with its own real UART pair (not the byte-level shortcut) —
    centerpiece test directly exercises the exit criterion: configure test_clock to a
    20-tick period, RUN, measure period=20 on the loopback pin, then *while still
    RUNning, no STOP* write a new 40-tick period and APPLY again, re-measure period=40.
  - `scripts/run_phase5_link_sim.sh`: runs all three testbenches above in order.
  - `tools/nemo_ctl/link.py`: Python client for the protocol — `build_frame`/
    `parse_frame`/checksum, `Transport` protocol + `SerialTransport`/`open_serial`
    (pyserial imported lazily, so nothing else needs it installed), `SigCellConfig`/
    `CapCellConfig`/`CapCellStatus` encode/decode, and `Link` with
    `write_reg`/`read_reg`/`apply`/`run`/`stop`/`status`/`read_capture_raw` plus the
    debug-harness helpers `send_cell_config`/`send_cap_config`/`send_config`/
    `read_captures`. Explicitly scoped to the 5 fixed debug cells
    (`DEBUG_CELL_NAMES`), not the full generic per-pin config — that RTL doesn't exist
    on hardware yet.
  - `tools/nemo_ctl/tests/test_link.py`: 27 tests against an in-memory model of
    `link_ctrl.sv`'s own parsing/dispatch rules (`_FakeDevice`/`_FakeTransport`), not
    real hardware — frame encode/decode, config encode/decode, every `Link` method,
    NACK handling, timeouts, and a protocol-level mirror of the live-frequency-change
    exit criterion. Added `pyserial>=3.5` to `tools/requirements.txt`.
  - `tools/nemo_ctl/cli.py`: added a `link` subcommand group (`status`/`run`/`stop`/
    `apply`/`set-clock`/`read-captures`), each with `--help` text cross-referencing
    `docs/USER_MANUAL.md` §6, per the standing CLI-text rule. `set-clock` reuses
    `units.quantize_clock()` (same quantization the wizard uses) so a requested
    frequency/duty gets the same achieved-value-and-error treatment everywhere in this
    tool. 3 new subprocess tests in `tools/nemo_ctl/tests/test_cli.py` (help text,
    missing `--port`, clean failure on an unreachable port).
  - `docs/USER_MANUAL.md`: new §6 "Phase 5 — the runtime link" (scope note, the PMOD
    blocker, simulate-first instructions, the `nemo_ctl.cli link` walkthrough), updated
    §0 status table, §1 setup note for `pyserial`, §7 troubleshooting rows, §8 quick
    reference rows. Old §6/§7 renumbered to §7/§8.
  - `docs/controller_spec.md`: marked §7 (register map draft) and §8 (link protocol
    draft) superseded by `docs/link_register_map.md`, with the real implementation's
    two deltas from the original sketch noted (LOAD_MODE is an explicit NACK, not
    silently ignored; read requests still carry LEN dummy payload bytes).
  - `docs/experiments/EXP-02_phase5_link_bringup.md`: full hardware procedure and exit-
    criterion checklist, results table left PENDING (same pattern as EXP-01).
- Hardware setup: **none — no Vivado, no board access in this environment.** Everything
  above is `pytest`/Icarus Verilog only.
- Results:
  - **[simulated]**: `scripts/run_phase5_link_sim.sh` — `uart_tb` 12/12,
    `link_ctrl_tb` 22/22, `phase5_link_top_tb` 7/7 (including the live frequency-change
    exit criterion, period 20 ticks -> 40 ticks while RUNning).
  - **[not hardware]**: `python3 -m pytest tools/nemo_ctl/tests`: 102/102 (72 pre-
    existing + 27 new `test_link.py` + 3 new `test_cli.py`).
  - **[measured on board]**: none yet — see `docs/experiments/EXP-02...md` §4, PENDING.
- Problems / fixes:
  - `phase5_link_top_tb.sv` compile errors (declaration-before-use for a reset signal
    used before its `logic` declaration; a task's 3rd argument silently inheriting the
    `output` direction from the preceding `output int period_ticks` argument because it
    had no explicit `input` keyword — classic SV ANSI-port-list gotcha, not an Icarus
    bug) — fixed by reordering the declaration and adding the explicit `input` keyword.
  - Real testbench timing bug, not an RTL bug: the mock PC's `pc_send_frame` task
    returned right after queuing the checksum byte's send pulse, before that byte
    actually finished transmitting (~8680 cycles at 100 MHz/115200 baud) — margins
    after RUN/APPLY/STOP were far too short, and worse, the first fix attempt (a blind
    extra-cycle margin added unconditionally inside `pc_send_frame`) broke the READ_REG
    test by eating the response's own leading byte(s) during that margin, before
    `pc_wait_for_response` ever started listening. Fixed by having `pc_send_frame` wait
    for the transport to actually go idle (no blind margin baked in), and adding an
    explicit one-byte-period margin only at call sites checking a side effect of a
    response-less command (RUN/STOP/APPLY), not before commands that get a response.
- Decisions:
  - Proceeding into Phase 5 despite Phase 4's own hardware exit criterion
    (`docs/experiments/EXP-01...md`) being unmeasured — explicit, informed call by
    Rahaf, deviating from `generic_controller_prompt.md`'s normal "wait for approval
    between phases" rule. Both Phase 4 and Phase 5 hardware bring-up remain open.
  - `send_config()`/the debug-harness helpers in `link.py` are scoped to exactly the 5
    fixed cells `phase5_link_top.sv` wires up, not the full generic per-pin
    `config.py`/`nemo_config.yaml` model — that generic RTL hasn't been built. Keeping
    this explicit (via `DEBUG_CELL_NAMES` and docstrings) rather than pretending the
    Python API already covers the real chip's pin set.
  - Per Rahaf's standing rule, **Phase 5 is not marked done** — RTL/software are ready
    and simulated, but the PMOD UART adapter's pin/voltage is still unconfirmed
    (blocking even wiring it up), and nobody has run `docs/experiments/EXP-02...md` on
    real hardware yet.
- Next steps: confirm the PMOD bank voltage for the USB-UART adapter against the actual
  ZedBoard reference manual (the single blocker on starting EXP-02 at all), update
  `fpga/constraints/phase5_link_top.xdc` with the real `rxd`/`txd` pin assignment, then
  run EXP-01 and EXP-02 on real hardware. Still open from earlier: the real "4. User
  manual" section of `generic_controller_prompt.md` was never delivered by Rahaf despite
  being asked three times — still needed if that reorganization is wanted.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 0 of `generic_controller_prompt.md` — a spec for one generic, user-configurable
  controller that replaces the hard-coded bring-up designs, so the user picks what every
  chip input does per mode without editing HDL. No code this phase.
- Done:
  - Located the brief's source files (none of the stated paths were trusted blindly; verified
    each): `docs/reference/nemo_chip/Blocks.xlsx` sheet "Blocks Interface - Digital";
    `docs/reference/nemo_chip/IO_pinout.xlsx` sheet "IO-Pins-Dima" (the brief's named
    `IO_pinout2.xlsx` does not exist as a filename in the repo — same content lives in
    `IO_pinout.xlsx`, per that folder's own README); `docs/session1/NEMO chip SIPO, PISO and
    Y-Flash modes explained.pdf` (read in full, 13 pages); `fpga/reference/dima_blocks/`
    (`sipo.sv`, `sipo_wrapper.sv`, `piso.sv`, read in full).
  - Installed `openpyxl` and `pypdf` locally (not present in the environment) to read the
    `.xlsx`/`.pdf` sources programmatically rather than by eye.
  - Wrote `docs/controller_spec.md`: reconciled 26-signal pin table (22 in + 4 out, matching
    the session1 explainer's own count), config schema shape, FPGA register-map sketch, a
    link-protocol frame draft, a link-options comparison with a recommendation, a rough
    (unmeasured) resource estimate, and every disagreement found between the source sheets.
- Hardware setup: none this session (spec only).
- Results: none measured. The 26-signal list, the register-map sizes and the resource
  estimate are **[simulated/estimated]** at best — nothing synthesized or run yet.
- Problems / fixes: n/a (research/documentation session).
- Decisions: none made — this phase produces a spec for approval, not a decision. One
  recommendation given (link option (a), USB-UART on a PMOD) but explicitly left open
  pending the user's sign-off per the task brief's phase-gate rule.
- Disagreements / open questions found while cross-checking the sheets (full detail in
  `docs/controller_spec.md` §2 and §5):
  - Neither "Blocks Interface - Digital" nor "IO-Pins-Dima" alone lists all 22 inputs + 4
    outputs the session1 explainer says exist; the correct 26 only appears by taking the
    union of both sheets.
  - `rst_sipo`: absent from "Blocks Interface - Digital" (pad 39 there is "Unused"); pin 37
    in "IO-Pins-Dima"'s numbered list. The task brief's own note says pad 39 — neither number
    is confirmed as the true physical pad.
  - DFT-per-ADC select width disagrees: 4 bits (`s0-3_dft`) on "Blocks Interface - Digital"
    vs. 2 bits (`s0-1_dft` only) on "IO-Pins-Dima" — neither cleanly selects the 8-way DFT
    mux the brief describes.
  - `s0_p/s1_p/s2_p` (newer sheet) vs. `s0/s1/s2` (older sheet) — same signals, renamed; the
    explainer confirms this is a known rename, not two different pins.
  - `Pinout_TO1`, `Pinout`, `Pinout_Dima` describe an unrelated, SPI-based digital interface
    (`SCLK/SDI/SDO/CS/DATA<0:7>/...`) that matches none of the current chip's RTL signal
    names — treated as describing an earlier/different chip generation, not this one.
  - The unnumbered `PISO_WR` row and the "stand-alone test structure" pins are both flagged
    as possibly not applicable to the current chip (one looks like a leftover from the SPI
    scheme above; the other is explicitly stated in session1 to be off the latest pad ring).
  - No chip-pin → FMC LA_P assignment exists anywhere in the repo yet — every signal's FMC
    pin is TBD in `docs/controller_spec.md` §3, to be decided in Phase 1/4, constrained to
    the 32 verified LA_P pins (only pair 0 has a hardware-confirmed loopback so far, per
    `docs/pin_verification.md`).
  - PMOD bank voltage (needed to judge link option (a)) is not documented anywhere in this
    repo; not assumed in the spec, flagged as TBD pending a check against the actual
    ZedBoard reference manual.
- Next steps: get the spec in `docs/controller_spec.md` approved (or redirected) and the
  link choice made — these are the Phase 0 exit criteria in `generic_controller_prompt.md`.
  Phase 1 (config format + Python core) does not start before that.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 0 exit + Phase 1 of `generic_controller_prompt.md` — config format + Python
  core, no hardware. Phase 0 spec approved; link choice = option (a), USB-UART on a PMOD
  (PMOD voltage still needs checking against the real ZedBoard manual before any wiring).
- Done:
  - Updated `docs/controller_spec.md` §9/§11 to record the approval and link decision.
  - Added `tools/nemo_ctl/`, a Python package (no FPGA code):
    - `gen_pin_db.py` — regenerates `data/pin_db.yaml` straight from
      `docs/reference/nemo_chip/Blocks.xlsx` / `IO_pinout.xlsx`, applying the Phase 0
      reconciliation (both sheets' disagreeing pad numbers kept side by side, not
      resolved); raises if a workbook changes in a way the reconciliation doesn't expect.
    - `pins.py`, `types.py`, `groups.py`, `dft_helper.py` — pin database, the 7 setting
      types, BUS pin groupings (`s_p`, `b_dft`, `s_dft`), and the DFT "pick ADC k, signal
      X" helper (kept explicitly `confirmed=False`, per spec §4).
    - `units.py` — ns/us/ms/Hz/kHz/MHz/% <-> 100 MHz-tick integers, always reporting
      achieved value + error (checked against the brief's own worked example: 3 MHz ->
      N=33 -> 3.0303 MHz, +1.0%, matches exactly).
    - `config.py` — loads/saves `config/nemo_config.yaml`.
    - `validate.py` — the four required checks: allowed types per pin, safe limits
      (generic 10 MHz warn / 50 MHz hard clock ceiling + any pin-specific limit), SERIAL
      must reference a configured CLOCK pin, no pin configured twice.
    - `timing.py` — per-mode timing summary table.
    - `preview.py` — WaveDrom JSON waveform preview per mode.
    - `excel_io.py` — Excel import/export, one sheet per mode, same columns as the YAML,
      plus a blank template generator.
  - Added `config/nemo_config.yaml`: the example from the brief, filled out for
    INFERENCE (Clock Generator, Array with Muxes, DSA, SIPO, PISO, DFT - All), with READ
    and WRITE left empty (TBD, per spec §1/§6). `pin_map` present with every chip pin ->
    `null` (TBD, nothing assigned yet, per spec §3).
  - Added `tools/nemo_ctl/tests/` (pytest, 55 tests) covering every module above,
    including a regression test that re-running `gen_pin_db.py` against the live
    workbooks reproduces the checked-in `pin_db.yaml` exactly.
  - Fixed a real bug this testing turned up: `validate.py`'s clock hard-limit check
    compared against the *achieved* frequency, but `quantize_clock` already clamps
    `period_ticks` to a minimum of 2 ticks, so achieved frequency can never exceed 50 MHz
    on the 100 MHz timebase — the check was dead code. Fixed to check the *requested*
    frequency instead, so asking for e.g. 60 MHz is now correctly flagged as an error
    (not silently clamped to 50 MHz with no warning).
  - Fixed an unrelated pre-existing bug found while editing `.gitignore`: it had
    unresolved git merge-conflict markers (`<<<<<<<`/`=======`/`>>>>>>>`) committed on
    `main` since `0b26dd4` ("merge: fold Rahaf's initial upload into the repo layout") —
    cleaned up by merging both halves' content, deduplicated, and added the new Python
    tooling ignores (`__pycache__/`, `.pytest_cache/`, etc.).
  - Added `pytest.ini` (repo root, points at `tools/nemo_ctl/tests`) and
    `tools/requirements.txt` (openpyxl, pyyaml, pytest).
- Hardware setup: none — Phase 1 is explicitly software-only.
- Results: **[simulated/software only]**. `python3 -m pytest` from the repo root: 55
  passed, 0 failed. The example INFERENCE config validates with 4 warnings (all TBD/
  UNCONFIRMED items already flagged in the spec, zero errors) and produces a correct
  timing table and WaveDrom preview — this is the Phase 1 exit criterion.
- Problems / fixes: the two bugs above (dead hard-limit check; broken `.gitignore`).
- Decisions: Excel export/import round-trips through a flat, fixed column set
  (`Block, Pin, Type` + every param key any type uses) rather than a different column
  set per type, so "same columns" (brief's own requirement) holds exactly across modes
  and sheets.
- Next steps: Phase 2, the interactive CLI wizard — needs my approval/redirection first
  per the brief's phase-gate rule, same as Phase 0 -> Phase 1 was.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 2 of `generic_controller_prompt.md` — interactive CLI wizard. Approved to
  proceed straight after Phase 1 in the same session, no redirection needed.
- Done:
  - Added `tools/nemo_ctl/wizard.py`: a headless engine (functions take `ask`/`tell`
    callables instead of calling `input()`/`print()` directly, so the whole flow is
    scriptable in tests — not just usable from a real terminal). Implements the brief's
    flow exactly: pick mode -> each block -> each input pin, current setting + a menu
    built from exactly the types `pin_db.yaml` allows for that pin (no dead options like
    offering "pulse" on a CLOCK-only pin). Per-block extras: copy the block from another
    mode, reset it to defaults (clear it), and — for the two DFT groups — a "DFT helper
    (pick ADC + signal)" shortcut that resolves both `b_dft` and `s_dft` from one pick
    (still `confirmed=False`, per spec §4) with a "materialize" step so later overriding
    just one of the two groups doesn't silently lose the other's value.
  - BUS groups (`s_p`, `b_dft`, `s_dft`) are walked once, not once per member pin, with
    a "set individually" escape hatch back to the raw per-pin menu — raw bit control
    stays possible, per the brief's own requirement.
  - Added `tools/nemo_ctl/cli.py`: the one file that actually calls `input()`/`print()`.
    `python3 -m nemo_ctl.cli wizard --mode INFERENCE` (plus `validate`, `preview`,
    `export-excel`, `import-excel`, `gen-template`). Saves back to
    `config/nemo_config.yaml` by default; `--excel` also exports afterward.
  - Added `tools/nemo_ctl/tests/test_wizard.py` (7 tests: full scripted INFERENCE build,
    copy-block, reset-to-defaults, invalid-choice retry, DFT-helper-then-override, bad
    width error) and `tests/test_cli.py` (6 tests driving the actual `python3 -m
    nemo_ctl.cli` subprocess, including the wizard over piped stdin — not just the
    in-process engine).
  - Exercised the exit criterion for real: scripted the full INFERENCE profile (every
    block, every pin) through both the headless engine and the piped-stdin CLI, checked
    it validates with zero errors (same TBD/UNCONFIRMED warnings as Phase 1, nothing
    new), and round-trips through Excel export/import byte-for-byte on the parsed config.
- Hardware setup: none — Phase 2 is software-only, same as Phase 1.
- Results: **[simulated/software only]**. `python3 -m pytest`: 68 passed, 0 failed
  (55 from Phase 1 + 13 new). Manual full-profile run via both the engine and the real
  CLI (piped stdin) confirmed clean.
- Problems / fixes: found and fixed a real round-trip bug in `config.py`'s
  `config_to_dict` while building the scripted full-build test — a block that ends up
  with zero settings (e.g. `dft per ADC` once the DFT helper absorbs it into `DFT - All`)
  wrote no rows to its Excel sheet, so re-importing lost that block key entirely even
  though every other consumer (`iter_settings`, `validate_config`, `timing`, `preview`)
  already treats "block absent" and "block present but empty" identically. Fixed by
  dropping empty blocks consistently in `config_to_dict`, so both directions agree.
  (First caught this with a manual script, not a test — then wrote
  `test_full_inference_build_validates_and_round_trips_through_excel` to pin it down.)
- Decisions: the DFT helper writes/reads a single `dft_select` entry under the
  `DFT - All` block (matching the brief's own schema example) rather than two separate
  per-group entries; overriding one of the two groups it covers "materializes" both
  into explicit `b_dft`/`s_dft` BUS settings first, so the un-overridden group's value
  survives instead of disappearing along with `dft_select`.
- Next steps: Phase 3 (RTL cells + testbenches) is the first phase that touches
  `fpga/src`/`fpga/tb` — needs my approval/redirection first, same phase-gate rule as
  before. Everything through Phase 2 remains software/config only, no hardware claims.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 3 of `generic_controller_prompt.md` — RTL cells + testbenches:
  `sig_cell.sv`, `cap_cell.sv`, `run_ctrl.sv`, each with a self-checking testbench
  covering the brief's required edge cases (N=2, odd N, width=1 tick, delay=0, cycles=1,
  config change while running), plus a utilization estimate for the 26 cells.
- Done:
  - No Vivado/license-server in this environment, so installed **Icarus Verilog**
    (`iverilog`/`vvp` 13.0) to actually run the testbenches, and **yosys** (0.69) to get a
    real synthesized utilization number instead of a hand count — both via
    `/opt/homebrew/bin/brew` (this machine also has a broken Intel Homebrew at
    `/usr/local` whose bundled compiler can't build anything; the arm64 one works via
    prebuilt bottles, no compile needed). Documented in CLAUDE.md §4 as secondary,
    local-only tools — Vivado remains the real target toolchain, nothing here produces a
    bitstream.
  - Added `fpga/src/sig_cell.sv`: one generic cell per driven chip pin, modes
    LOW/HIGH/PULSE/CLOCK/SERIAL. **Deliberately did not give it a 6th "BUS" hardware
    mode** — a BUS setting (`tools/nemo_ctl/groups.py`) is already decomposed into plain
    LOW/HIGH per pin by the Python tool before it reaches a register, so a BUS mode in
    hardware would be a dead, untestable state identical to LOW/HIGH. Flagged per
    CLAUDE.md §2's "if you find a concrete reason to deviate, explain first" — explained
    in the module's header comment. Also dropped a separate "polarity" config field: the
    pin_db/wizard layer already resolves polarity into `idle_level` (confirmed against
    `tools/nemo_ctl/data/pin_db.yaml`'s own `rst_sipo`/`rst_piso` entries), so carrying
    both would just be redundant, conflicting information reaching the same cell.
  - Added `fpga/src/cap_cell.sv`: one generic capture cell per chip output pin, modes
    LEVEL/EDGE_COUNT/PERIOD/SERIAL. Assumes `sync_in` is already 2-FF-synchronized
    upstream (per the architecture diagram), consistent with CLAUDE.md §8.
  - Added `fpga/src/run_ctrl.sv`: global RUN/STOP + one-cycle APPLY strobe, with 2-FF
    synchronizers + edge detection on all three command inputs (CLAUDE.md §8: every
    asynchronous input gets a 2-FF synchronizer) so a command held high for many cycles
    (e.g. a switch, not a one-shot pulse) still only fires once.
  - Added self-checking testbenches: `fpga/tb/sig_cell_tb.sv` (24 checks),
    `fpga/tb/cap_cell_tb.sv` (13 checks), `fpga/tb/run_ctrl_tb.sv` (9 checks), and
    `fpga/tb/integration_tb.sv` (16 checks, a small sanity wiring of one `sig_cell` CLOCK
    through `run_ctrl` into one `cap_cell` PERIOD measurement — not required by the
    brief's module list on its own, but cheap given the unit tests already existed, and
    it catches wiring mistakes before Phase 4's real top level). 62 checks total, all
    passing. Added `scripts/run_phase3_sims.sh` to re-run all four plus the yosys
    estimate in one command.
  - Added `fpga/tb/utilization_estimate_top.sv`: synthesis-only scaffolding (not built by
    `scripts/create_project.tcl`, not simulated) that instantiates the real 26 cells —
    `TICK_W=20` (realistic for this project: the largest delay in
    `config/nemo_config.yaml` today is 150 us = 15,000 ticks = 14 bits; 20 gives headroom
    to ~10.5 ms), `SERIAL_W=136` for `sipo_in`, `CAP_W=168` for `piso_out`, 1 for every
    other pin (which never uses SERIAL/serial-capture) — and ran it through
    `yosys synth_xilinx -family xc7`.
- Hardware setup: none — still simulation/synthesis-estimate only, no FPGA involved.
- Results: **[simulated]** — `scripts/run_phase3_sims.sh`: 62/62 checks pass across the
  four testbenches (real Icarus Verilog 13.0 runs, not claimed without execution).
  **Utilization — [measured, real synthesis output, not estimated]** (yosys 0.69,
  `synth_xilinx -family xc7`, not Vivado — no P&R, no timing closure):
  FF (`FDCE`+`FDPE`) 4,923 / 106,400 (4.6%); LUT (`LUT2`-`LUT6`) 6,449 / 53,200 (12.1%);
  1,254 `CARRY4` chains; yosys "Estimated LCs" 5,244 / 53,200 (9.9%). Higher LUT usage
  than Phase 0's hand-counted guess (~3%), mainly from the two wide shift registers
  (136+168=304 bits) and the `CARRY4`-chain comparators every 20-bit tick counter needs —
  still comfortably inside the chip's budget. `docs/controller_spec.md` §10/§10a updated
  (old guess kept for history, marked superseded).
- Problems / fixes (several real bugs found via the testbenches, not just test-script
  typos — each confirmed with a VCD/print trace before deciding which side the bug was
  really on):
  - **Testbench race** (the big one): driving `apply`/`run`/`shift_strobe` right after
    `@(posedge clk)` races the DUT's own `always_ff` evaluating that identical edge — both
    are separate processes woken by the same event with no defined relative order.
    Icarus resolved it by running the testbench's post-wait code before the DUT saw the
    edge, making every config appear to load one full cycle early and costing 7 failing
    checks the first run. Fixed by driving all stimulus at `@(negedge clk)` instead (a
    distinct event, half a cycle from either neighbouring posedge — removes the ambiguity
    entirely), and documented as a comment in every testbench's `tick()`/drive tasks so
    it isn't rediscovered next phase.
  - **Second, related race**: reading DUT outputs with a bare `@(posedge clk)` (no delay)
    sees their pre-edge (one-cycle-stale) value, since those outputs update via
    nonblocking assignment in the NBA region, which runs strictly after the Active region
    that resumes right after the wait. Edge-counting checks (counting occurrences over
    many ticks) didn't care and passed even with this bug present, which is exactly why
    it wasn't caught until point-in-time checks (exact pulse timing, SERIAL bit values)
    started failing. Fixed by adding a 1ns settle (`#1`) after every `@(posedge clk)` used
    for sampling.
  - `sig_cell.sv`'s combinational `next_pin_out` block originally used `unique case` plus
    a same-block override `if` statement after the case; Icarus 13.0 only partially
    supports that pattern for this toolchain (own "sorry" warnings nearby). Simplified to
    a single `if (!run) ... else case (...)` with no `unique` qualifier and no
    post-case override — cleaner regardless of the tool quirk, and the actual fix (the
    bug above was the real cause; this was a secondary, real but not symptom-causing
    cleanup done at the same time).
  - PULSE test expectation bug (not an RTL bug): `delay=20` was assumed to mean the
    action starts on tick 20; the RTL actually (and sensibly) starts it on tick 21 — 20
    full idle ticks (1..20), action on the 21st — consistent with how delay=0 already
    behaved (0 idle ticks, action immediately on tick 1). Fixed the test's expectation,
    not the RTL.
  - `cap_cell.sv` SERIAL capture alignment: confirmed (not a bug) that `msb_first`
    (shifts left, new bit at LSB) and `!msb_first` (shifts right, new bit at the top)
    land a *partial* capture (`cfg_bits < CAP_W`) in different halves of the register —
    bottom `[cfg_bits-1:0]` for msb_first, top `[CAP_W-1:CAP_W-cfg_bits]` for !msb_first.
    Only matters when `CAP_W != cfg_bits`; documented in the module header so Phase 4
    sizes `CAP_W` to the real frame width (as `utilization_estimate_top.sv` already does)
    and never has to care.
- Decisions: `sig_cell` gets no hardware BUS mode and no separate polarity field (both
  explained above); atomic `apply` resets every internal counter/shift-register to zero
  (not just the config fields), so a config change while running cleanly restarts the
  cell's sequence under the new config rather than trying to splice old phase into new
  timing. `TICK_W` widened from the Phase 0 register-map sketch's implied 16 bits to a
  parameter (20 used for the utilization estimate, 32 as the modules' own default) —
  Phase 0 §7 called that sketch "sizing only," so this is a refinement, not a conflict.
- Next steps: Phase 4 (top level with compile-time config, hardware bring-up on the
  verified loopback pairs) — needs my approval/redirection first, same phase-gate rule.
  This is the first phase that touches real hardware; everything through Phase 3 is
  simulation/synthesis-estimate only.

---

## 2026-10-13, Rahaf, branch feature/rahaf-generic-controller-spec
- Goal: Phase 4 of `generic_controller_prompt.md` — top level with compile-time config,
  hardware bring-up on the verified/pin-mapped loopback pairs. **Important limitation
  hit immediately: this phase's own exit criterion needs [measured on board] results,
  which needs Vivado (not installed/licensed here) and physical access to the ZedBoard,
  jumper wires, and a multimeter/scope (none available in this environment).** Did
  everything achievable without those — the compile-time config generator, the top-level
  RTL + XDC, and pre-validating all of it in simulation — and stopped at the hardware
  boundary rather than fabricate a "ran fine" result. `docs/experiments/EXP-01_*.md` is
  the handoff: fully written setup/procedure, results table marked PENDING.
- Done:
  - Added `config/phase4_loopback_test.yaml` + `tools/nemo_ctl/gen_svh.py` ->
    `fpga/src/gen/nemo_cfg_pkg.svh`: one `sig_cell`+`cap_cell` pair per signal TYPE
    (CLOCK/PULSE/SERIAL/LOW/HIGH), each on one loopback pair (0-4) from
    `docs/pin_verification.md` — **not** the real chip config (`config/nemo_config.yaml`,
    whose `pin_map` is still all `null`; there's no chip-pin -> FMC assignment to build a
    real top level from yet). This matches the brief's own suggested Phase 4 activity:
    "hardware test of every signal type on the verified loopback pairs." CLOCK uses
    100 Hz (the already-proven `fmc_clock_loopback_slow` approach, read 0.899 V on the
    multimeter previously); PULSE/SERIAL use human/multimeter/scope-scale timing (500 ms,
    10 Hz) deliberately, so a person — or an oscilloscope — can actually observe them.
  - Added `fpga/src/phase4_loopback_top.sv` + `fpga/constraints/phase4_loopback_top.xdc`:
    `run_ctrl` + 5 driven test pairs + 5 capture pairs + an internal helper clock (not
    tied to any pin) generating the SERIAL pair's shift/capture strobe. `sw[4]`=RUN,
    `sw[2:0]`=which pair's status shows on the LEDs, no reset button (internal power-on
    counter + a single auto-APPLY, since this is compile-time config with no link). XDC
    reuses the exact same confirmed pin assignments as every earlier bring-up design
    (clk/sw/led/fmc_pins all copied from `fmc_clock_loopback.xdc`, which agrees with the
    other 4 XDC files already in the repo).
  - Added `fpga/tb/phase4_loopback_top_tb.sv` (21 checks) + `scripts/run_phase4_sim.sh`:
    pre-validates the whole top level with Icarus Verilog before it ever touches Vivado.
    Models the 5 **external** jumper wires directly (shorting `fmc_pins[i]` to
    `fmc_pins[i+16]`) since the real jumpers don't exist in simulation — the DUT itself
    never connects them, same as on the real board. Deliberately checks only what's
    reachable in a short simulated window (first edges, immediate levels, the LED mux,
    the fault latch staying clear) since the real timings (500 ms pulse, 10 Hz strobe)
    are far too slow to simulate to completion in reasonable wall-clock time — a
    documented scope limit, not a shortcut: the brief's real validation is the hardware
    step this testbench cannot replace.
  - Fixed `scripts/create_project.tcl`: it only globbed `fpga/src/*.v`/`*.sv`, which would
    have silently missed the generated `fpga/src/gen/*.svh` package — added that glob.
  - Added a note to `docs/pin_verification.md` pointing at EXP-01 as pending additional
    coverage for pairs 1-4, without touching that table's own PASS/FAIL columns (those
    are T2-T4 results specifically, not this).
- Hardware setup: **none — this is the limitation, see above.**
- Results: **[simulated]** only. `scripts/run_phase3_sims.sh`: 69/69 (sig_cell grew to 28
  checks, +4 for a new `SERIAL_W=1`/width-edge-case regression; cap_cell grew to 16, +3
  for the matching `CAP_W=1` case). `scripts/run_phase4_sim.sh`: 21/21.
  `python3 -m pytest`: 72/72 (added `gen_svh` tests). **No [measured on board] result
  exists for this phase** — `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`
  §4 is a template, not a result.
- Problems / fixes (several real bugs, each confirmed with a minimal repro before
  deciding which side the bug was on — same discipline as Phase 3):
  - **Real RTL bug in `sig_cell.sv`/`cap_cell.sv`**: `{shift_reg[SERIAL_W-2:0], ...}` /
    `{capture_reg[CAP_W-2:0], ...}` becomes an invalid `[-1:0]` part-select whenever
    `SERIAL_W`/`CAP_W` == 1 — exactly the width every non-SERIAL pin in
    `phase4_loopback_top.sv` actually uses (cheapest possible shift register for a mode a
    cell will never run). Neither Phase 3 unit testbench happened to exercise width==1,
    so this sat undetected until the first real multi-cell top level. Fixed with a
    `generate if (WIDTH > 1) / else` producing a same-named "next value" signal, used by
    the main `always_ff` either way (`sig_cell`: the width==1 "next" value is an unused
    placeholder, since `bits_exhausted` gates off any shift beyond the first bit anyway;
    `cap_cell`: it's `sync_in` directly, since capturing straight into the one bit a
    1-bit register has *is* the meaningful behavior there, not a placeholder). Added a
    dedicated `SERIAL_W=1`/`CAP_W=1` regression test to each Phase 3 testbench.
  - **Icarus-specific width-resolution bug, not an RTL bug**: wildcard-importing a
    package (`import nemo_cfg_pkg::*;`) and then using an imported localparam as a module
    port connection got silently truncated to 1 bit before zero-padding back — confirmed
    with a minimal repro completely outside this project's files, and confirmed it
    disappears with explicit `pkg::NAME` scoping instead of a wildcard import
    (`$bits()` on the same identifier correctly reports 32 either way, so this is purely
    about the *connection*, not the declaration). This one mattered: it would have fed
    `cfg_param_a`/`cfg_param_b` almost-always-wrong values (e.g. the 100 Hz clock's
    1,000,000-tick period truncated to its LSB, 0, then zero-extended) if shipped as a
    "just a warning, probably fine" — rewrote every reference in
    `phase4_loopback_top.sv` to explicit `nemo_cfg_pkg::` scoping.
  - **Generator bug** (`tools/nemo_ctl/gen_svh.py`): MSB-first SERIAL data was emitted
    right-justified (`0x00A5` for an 8-bit `0xA5` in a 16-bit field), but `sig_cell.sv`'s
    own header comment already specifies MSB-first data must be left-justified (shifts
    left from the top bit) — confirmed against the already-passing `sig_cell_tb.sv`,
    which used the correct left-justified form. Fixed to shift left by
    `(DATA_FIELD_W - bits)` for `msb_first`, left as-is for `!msb_first` (already
    naturally right-justified, which is what shifting right from the bottom needs).
  - **Design fix, not exactly a bug**: the SERIAL pair's helper clock drove its
    `shift_strobe` from `rising_edge`, which fires immediately on the very first tick of
    RUN (the idle -> first-high-phase transition) — shifting the first bit away before it
    was ever presented. Switched to `falling_edge` (can't occur before at least a
    half-period has elapsed), matching the real SIPO/PISO convention noted in
    `docs/session1` (data changes on `clk_sipo`'s falling edge, not rising).
- Decisions: built the bring-up top level against a dedicated test config
  (`config/phase4_loopback_test.yaml`), not the real chip config — there is no FMC pin
  assignment for the real 26 signals yet (`config/nemo_config.yaml`'s `pin_map` is still
  all `null`), so generating a "real" top level now would mean inventing pin assignments.
  This dedicated-config approach still satisfies the brief's own Phase 4 activity
  ("hardware test of every signal type on the verified loopback pairs") without that.
- Next steps: **run EXP-01 on real hardware** — needs Vivado + a physical ZedBoard with
  VADJ on 1.8 V, 5 jumper wires per the experiment doc, and a multimeter/scope. I cannot
  do this part; it needs you (or Yazan) to actually run it and fill in EXP-01 §4. Once
  that's done [measured on board], Phase 5 (runtime link) is next and needs
  approval/redirection first, same phase-gate rule as every prior phase.

---

## 2026-10-16, Rahaf, branch feature/rahaf-user-manual
- Goal: new standing requirement from Rahaf, on top of `generic_controller_prompt.md`:
  maintain `docs/USER_MANUAL.md` for a lab user who did not build the system; catch up
  the manual for every completed phase before continuing the current one; a phase isn't
  "done" until its manual section is written AND Rahaf has followed it successfully;
  every CLI command gets `--help` text matching the manual; the wizard shows a one-line
  hint per field.
- **Process note, not a technical result, but worth recording**: the actual trigger for
  this was Rahaf asking me to replace `docs/prompts/generic_controller.md` with "the new
  version I'm giving you," adding a "4. User manual" section. That new version was never
  actually delivered — three separate pastes, each a different file already in this
  repo (an old/different draft found in `~/Downloads`, then `docs/controller_spec.md`,
  then the current `generic_controller_prompt.md` itself, byte-for-byte). I asked each
  time rather than guess at a spec I didn't have. When Rahaf said "continue" without
  providing it a fourth time, I went ahead using my own judgment for the manual's
  structure instead of continuing to block on it — flagged clearly in the manual's own
  header so it's not mistaken for an agreed outline. `docs/prompts/generic_controller.md`
  itself was never created; the task file is still `generic_controller_prompt.md` at the
  repo root, unchanged.
- Done:
  - Added `docs/USER_MANUAL.md`: status table (which phases are usable today), setup,
    then one section per completed phase (Phase 1 config/validate/preview/Excel, Phase 2
    wizard walkthrough, Phase 3 RTL simulation, Phase 4 build+simulate with a clear "the
    hardware step is not done yet" callout matching `docs/WORKLOG.md`'s own Phase 4
    entry), a troubleshooting table, and a file-location quick reference.
  - Verified every command block in the manual by actually running it (not written from
    memory and assumed correct) — `validate`, `preview` (both formats), `export-excel`,
    `import-excel`, `gen-template`, a full scripted `wizard` session, both
    `scripts/run_phase3_sims.sh` and `scripts/run_phase4_sim.sh`, and the two
    troubleshooting-table claims that were checkable (`ModuleNotFoundError` without `-m`;
    `validate` printing nothing on a clean config). Fixed one real mistake this caught in
    my own first draft of the verification script (wrong block order for a scripted
    wizard run) before it ever reached the manual itself.
  - Added `--help` text to every `nemo_ctl.cli` subcommand (`wizard`, `validate`,
    `preview`, `export-excel`, `import-excel`, `gen-template`): a `description` matching
    the manual's wording (cross-referenced by section number) for each, an `epilog` with
    a runnable example where it mattered (`wizard`'s overwrite warning + safe-copy
    example), and `help=` text on every individual argument that was missing one.
  - Added a one-line hint to every wizard sub-prompt that was missing one or had only a
    bare unit example (`pulse`'s delay/polarity, `clock`'s cycles/delay, `serial`'s data/
    bits/msb_first) — what the field controls, not just an example value.
- Hardware setup: none — this is documentation + CLI/wizard text only.
- Results: **[not applicable — no hardware, no simulation changed]**. `python3 -m
  pytest`: 72/72 still passing (prompt-text changes don't affect the tests, which drive
  by scripted answers, not by matching prompt wording).
- Problems / fixes:
  - Real (small) bug found while adding hints, not just wording: the SERIAL type's
    "which edge does data change on" prompt hardcoded the literal text `clk_sipo`
    regardless of which clock pin the user had actually just named in the previous
    answer. Fixed to interpolate the real `clock` variable.
  - Not a bug, but worth recording: `wizard.py`'s existing prompts already had decent
    inline hints (e.g. `width (e.g. 1us, 100ns):`) before this session; the gap was
    mainly missing units on the two `delay` prompts and no "what does this control"
    framing, not a total absence of hints.
- Decisions: per Rahaf's new rule, **this phase (user manual, Phases 0-4 catch-up) is not
  marked done** — it needs Rahaf to actually follow the manual successfully, which I
  cannot do on their behalf. Everything above is a draft for that review, same spirit as
  `docs/experiments/EXP-01`'s results table being left PENDING rather than filled in from
  simulation.
- Next steps: Rahaf follows `docs/USER_MANUAL.md` end to end (§2-§5) and reports back
  anything confusing, wrong, or missing. Once that's clean, maintaining this file going
  forward means: every future phase gets its manual section written before being called
  done, matching the new standing rule. Separately, still open from the prior entry:
  `docs/prompts/generic_controller.md` / the "4. User manual" section of the task brief
  itself is still needed from Rahaf if that reorganization is still wanted.

---

## 2026-10-12, Yazan, branch feature/repo-setup
- Goal: put the project under git so both team members (and their Claude sessions) share one source of truth.
- Done:
  - Imported bring-up sources from the lab PC folder `FPGA_PROJECT_YR` (14/09 meeting): 7 HDL files to `fpga/src/`, 5 XDC files to `fpga/constraints/`. No code changes.
  - Added `CLAUDE.md` (shared context), `.gitignore` (Vivado output), `README.md`, `scripts/create_project.tcl` (rebuilds a project per top module into `build/`).
  - Added docs: this log, `pin_verification.md`, `decisions.md`, `issues.md`, the LaTeX bring-up log, the measurement PDFs and the FMC pin-mapping spreadsheet.
  - Added the project spec + presentation + NEMO tracking sheet (`docs/project/`), the 14/09 meeting material (`docs/meetings/2026-09-14/`), the Y-Flash papers (`docs/reference/papers/`), and Dima's SIPO/PISO code as reference only (`fpga/reference/dima_blocks/`, not built).
  - Cross-checked: all 5 XDC files assign the same package pins to the 32 FMC LA_P ports.
- Hardware setup: none this session.
- Results: none new. Earlier results are summarized in `pin_verification.md`.
- Problems / fixes: CLAUDE.md listed `PINS layout.xdc`; the actual file is `PINS_layout.xdc` (fixed). `single_pin_tester.v` was missing from the file table (added).
- Merge with Rahaf's first push (`22ce4bb`, raw copy of the lab folder on `main`): every file was byte-identical to the organized copy here (`PINS_layout.xdc` differed only in line endings), so the raw copies were removed. Dropped generated `IO_DEFINE.xpr`, `fmc_loopback_test.dcp` and the Office lock file `~$NEMO_Tracking.xlsx`. Rahaf's top-level `NEMO_Tracking.xlsx` differs from the lab-PC copy, so both are kept: `docs/project/NEMO_Tracking.xlsx` (lab PC, 14/09) and `docs/project/NEMO_Tracking_rahaf_2026-10-12.xlsx`. **Resolved 2026-10-13: kept Rahaf's version.** Merged both `.gitignore` files.
- Decisions: Vivado project files are not committed; they are regenerated by `scripts/create_project.tcl`.
- Next steps: `create_project.tcl` has not been run in Vivado yet; run it once and fix any issues. Then verify pairs 1-15 (CLAUDE.md section 7).

## 2026-10-13, Yazan, branch main
- Goal: add NEMO chip reference workbooks.
- Done: added `docs/reference/nemo_chip/Blocks.xlsx` and `IO_pinout.xlsx` (from `IO_pinout(2).xlsx`) with a README describing the sheets. No code changes.
- Results: none.
- Next steps: use the Pinout sheets to plan the chip-pin to FMC LA-pin mapping for the SIPO/PISO and phase signals.
- Moved Rahaf's `session1/` (SIPO/PISO/Y-Flash explanation PDF + 6 diagrams) to `docs/session1/` to match the repo layout; contents unchanged. CLAUDE.md layout and SIPO/PISO task now point there.
- Deleted the old lab-PC `NEMO_Tracking.xlsx`; Rahaf's version renamed to `docs/project/NEMO_Tracking.xlsx` (the only copy now; the old one remains in git history).
