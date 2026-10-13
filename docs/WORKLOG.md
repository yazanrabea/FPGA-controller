# Work log

Chronological, one entry per session. Format: see CLAUDE.md section 9.
Tag every result **[simulated]** or **[measured on board]**.

## Currently working on
| Person | Task | Branch | Files touched |
|---|---|---|---|
| Rahaf | Generic chip controller — Phase 4, software side only (`generic_controller_prompt.md`) | `feature/rahaf-generic-controller-spec` | `fpga/src/phase4_loopback_top.sv`, `tools/nemo_ctl/gen_svh.py`, `docs/experiments/EXP-01_*.md`, this file |

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
