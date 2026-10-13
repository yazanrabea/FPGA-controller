# Work log

Chronological, one entry per session. Format: see CLAUDE.md section 9.
Tag every result **[simulated]** or **[measured on board]**.

## Currently working on
| Person | Task | Branch | Files touched |
|---|---|---|---|
| Rahaf | Generic chip controller — Phase 1 (`generic_controller_prompt.md`) | `feature/rahaf-generic-controller-spec` | `tools/nemo_ctl/`, `config/nemo_config.yaml`, this file |

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
