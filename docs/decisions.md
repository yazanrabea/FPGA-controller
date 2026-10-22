# Decisions

Each entry: date, decision, reason, rejected options.

## Use J2/J3 headers, not the SMA jacks
- Decision: all FPGA <-> chip signals go through the J2/J3 0.1" headers (P column).
- Reason: the HTG-FMC-SMA-LVDS SMA jacks are wired to transceiver lanes; the XC7Z020 has no GTX transceivers and only 4 of the 38 SMA signals reach the FPGA (clock inputs only).
- Rejected: SMA jacks for GPIO.

## Pair convention for bring-up
- Decision: output pin i = LAi_P, input pin i+16 = LA(i+16)_P, i = 0..15, selected by `sw[3:0]`; `sw[4]` enables/sets drive.
- Reason: lets one jumper wire per pair test the full out -> board -> in path with a self-checking design.

## Low-frequency clock for multimeter checks
- Decision: use `fmc_clock_loopback_slow` (~100 Hz) for multimeter readings.
- Reason: a handheld multimeter cannot average a 1 MHz square wave; readings were unstable.

## Vivado projects are generated, not committed
- Decision: commit only sources, XDC, testbenches, Tcl and docs; rebuild projects with `scripts/create_project.tcl`.
- Reason: generated files are large, machine-specific and cause merge conflicts between two people.

## Phase 6: SIPO/PISO as profiles of the generic cells, in their own config package (2026-10-22, Yazan)
- Decision: SIPO_LOAD / PISO_READ live in `config/phase6_sipo_piso.yaml` as ordinary per-pin settings (PULSE/CLOCK/SERIAL/HIGH/CAPTURE), generated into a separate `fpga/src/gen/phase6_cfg_pkg.sv` by `gen_svh.py --phase6`. The generator runs `sipo_piso.check_sipo_load` / `check_piso_read` first and writes nothing if a check fails.
- Reason: the timing analysis (2026-10-19) showed the generic cells meet Dima's RTL timing, so no dedicated engine is needed. A separate package leaves `nemo_cfg_pkg.sv` and Phase 4 byte-identical. Checking before generating means a profile that would load or read a corrupted frame can't reach the RTL.
- UNCONFIRMED choices are config fields, not hard-coded: `sipo_in.data_edge`, `piso_out.edge`, `piso_out.chip_delay`, and the rst/cs/shift polarities. A polarity different from Dima's RTL only warns, because the pad might invert (Q6). `piso_out.edge: rising` is an error, not a warning: with 168 clk_piso cycles, rising edge 1 is the load, so bit 1 can only be read on falling edge 1.
- Rejected: dedicated SIPO/PISO engines; extending `nemo_cfg_pkg.sv`'s Phase 4 `pairs` schema to 136/168-bit SERIAL (would touch the Phase 4 build that EXP-01 is about to test on hardware); computing the delays inside the generator from a frequency alone (hides the per-pin timing the config is supposed to show).

## Phase 6 sims on Yazan's laptop: Icarus 12 from winget, with a one-change sipo_wrapper stand-in (2026-10-22, Yazan)
- Decision: installed Icarus Verilog 12 (`winget install Icarus.Verilog`, hash verified by winget) to simulate 6.3/6.4 off the lab PC. Because it can't elaborate Dima's `sipo_wrapper.sv`, Icarus runs use `fpga/tb/sipo_wrapper_icarus_shim.sv` (his module, only the `sel` driver split); xsim runs use his original file.
- Reason: lets Phase 6 be simulated now instead of waiting for lab time; the stand-in changes how `sel` is driven, not what it holds, and the original is still the reference.
- Rejected: editing `fpga/reference/dima_blocks/` (rule: stub around Dima's files, never edit them); waiting for the lab PC; installing full Vivado (tens of GB) just for xsim.
- Consequence: Phase 6 isn't "done" until `run_phase6_sim.sh` also passes in xsim with the unmodified `sipo_wrapper.sv`.

## Phase 7: the step sequencer runs on the FPGA, not in Python (2026-10-22, Yazan)
- Decision: `fpga/src/seq_engine.sv` walks the step table in hardware. At each boundary it APPLYs only that step's cells (unlisted cells keep running); a step ends after an exact tick count or on a cell event (done / captured / edge count / level) with a timeout that FAULTs to idle. Python builds and checks the table (`tools/nemo_ctl/sequence.py`) and runs the program-verify loop on top (`program_verify`).
- Reason: step boundaries are tick-exact and repeatable, and a sequence can be tested on the board now with a compile-time table, without waiting for the UART link (EXP-02 is blocked on the PMOD pin/voltage). Chosen by Yazan from the two options presented.
- Rejected: a Python-only sequencer over the link (millisecond, jittery gaps between steps; untestable on hardware until EXP-02).
- Details decided with it: step 0 must set every cell and is also the idle state (preloaded after reset with RUN low, which fixes Phase 6's "resets asserted before APPLY" for any top using the engine); the end/fault/abort re-apply touches sig cells only so captures survive (`docs/issues.md`); every wait step must have a timeout; waits are ignored for a step's first 2 ticks.

## Phase 7 round 1 scope: engine + loopback top; link v2 later (2026-10-22, Yazan)
- Decision: this round is 7.1 Python + 7.2 engine + 7.3 loopback top/XDC/EXP-03 + docs. Writing the step table over the link and widening DATA/CAPTURE to 136/168 bits (deferred from Phase 6) is the next round.
- Reason: link v2 can't be tested on hardware until EXP-02 is unblocked, and it touches the Phase 5 files.
- Also: Yazan started Phase 7 before PR #1 (Phase 6) was reviewed, overriding Rahaf's "stop for approval after each phase" rule for this phase. Branch `feature/yazan-phase7-sequencer` is cut from the Phase 6 branch, so it carries Phase 6 until #1 merges. Outcome: both were pushed to `main` the same day without a review (next entry).

## PULLDOWN on the Phase 7 loopback inputs (2026-10-22, Yazan)
- Decision: `phase7_seq_loopback_top.xdc` adds `PULLDOWN true` on LA16–LA20_P; pin numbers and IOSTANDARD lines are identical to Phase 4's (diffed).
- Reason: EXP-03's fault test pulls a jumper; without a pull the input floats and the test is not deterministic.
- Rejected: changing the other designs' XDCs (not needed there; one XDC per top, no physical pin moved).

## Phases 6 and 7 pushed to main without partner review (2026-10-22, Yazan)
- Decision: fast-forward `main` to the Phase 7 branch (which contains Phase 6) at Yazan's request, instead of waiting for Rahaf to review PR #1 and a Phase 7 PR.
- Reason: Yazan's call, so both partners work from one up-to-date `main`. `origin/main` had not moved, so it's a clean fast-forward. Rahaf's own working rule (2026-10-19) is also direct pushes to `main` after each passing step.
- Consequences: this skips CLAUDE.md §10's PR review. Rahaf should still review the Phase 6/7 changes on `main` (PR #1's description lists what to check). As with Phases 3-5 already on `main`, Phases 6 and 7 are **[simulated] only**: not built in Vivado, not run on the board. `main` is "builds in simulation", not "tested on the board", for everything after Phase 2.
- Rejected: waiting for the reviews (Yazan chose not to); a merge commit (nothing to merge, fast-forward keeps history linear).
