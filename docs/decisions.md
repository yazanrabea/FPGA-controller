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

## Phase 7 round 2: step table in block RAM with a prefetched next-step bank (2026-10-22, Yazan)
- Decision: the link-written step table lives in RAM (`seq_bank.sv`: 4 byte lanes, registered read, so it infers block RAM). While step k runs, step k+1 is copied into a register bank (4 bytes/tick, ~40 ticks for the loopback entry), and the cells take their config from that bank. If a step ends before the copy lands, the engine waits and sets a sticky LATE flag.
- Reason: chosen by Yazan from the two options presented. It scales to the real chip (22 cells, 136-bit SIPO frame, 16 steps would need tens of thousands of flip-flops as a register table), and keeps step boundaries tick-exact for every step longer than ~0.4 µs.
- Rejected: a flip-flop table read directly like round 1's package (always exact, but ~18k FFs for 5 cells and far too big for the chip).
- Consequence: very short steps (fixed < ~40 ticks, or a wait whose condition is already true) delay the next one by the copy time. `cli seq load` warns about short fixed steps; STATUS.LATE reports the rest. The demo's `confirm` step triggers it on purpose.

## Phase 7 round 2: shared frame engine, Phase 5 refactored onto it (2026-10-22, Yazan)
- Decision: `link_ctrl.sv`'s parser/responder moved to `fpga/src/link_frame.sv` (byte-wide register bus, 1-tick read latency, input FIFO). Phase 5's register file stays in `link_ctrl.sv`, its map unchanged, with packed 2-D ports. The three Phase 5 testbenches were made Icarus-12-compatible (behaviour-preserving) and pass unchanged checks.
- Reason: chosen by Yazan; one parser for both link tops, a bus a block RAM can sit behind, and Phase 5 testable on the Windows laptop.
- Rejected: a second, copied parser for round 2.
- Consequence: Phase 5 writes now land LEN+4 ticks after the checksum instead of 2 (invisible over UART); `link_ctrl_tb`'s three post-write waits were lengthened accordingly (`docs/issues.md`). Needs re-checking in xsim on the lab PC.

## Link v2 command meanings (2026-10-22, Yazan)
- Decision: on `phase7_link_top` the existing commands keep their frames but mean sequence operations: RUN = start, STOP = abort, APPLY = re-apply step 0 with RUN low. No new command codes.
- Reason: the Phase 5 Python client and frame format stay usable as is; the meanings are the natural ones for a sequencer.
- Rejected: new CMD codes (protocol change for no gain); control bits in a register (one more write per operation).

## Phase 7 round 2 merged to main without partner review (2026-10-22, Yazan)
- Decision: fast-forward `main` to `feature/yazan-phase7-link-v2` at Yazan's request, as was done for Phases 6/7 round 1.
- Reason: Yazan's call; `origin/main` had not moved, so it's a clean fast-forward.
- Consequences: round 2 changes Phase 5's link code (`link_ctrl.sv` split onto `link_frame.sv`, packed ports, writes now LEN+4 ticks after the checksum, three Phase 5 testbenches edited). Rahaf should review that on `main`, and it must be re-run in xsim on the lab PC. Everything in round 2 is **[simulated] only**.

## PC link for EXP-02 / EXP-04: JTAG over J17 (option c)
- Decision (Yazan, 2026-10-22): carry the link's bytes over the J17 JTAG/USB cable (the one already used for programming) instead of a USB-UART adapter on Pmod JA.
- Reason: the kit has no 3.3 V USB-UART adapter (`docs/controller_spec.md` §9), and J17 needs no new wiring, pins or voltage decision.
- Rejected for now: (a) USB-UART adapter on Pmod JA (needs hardware we don't have; still the cheapest switch later, since `link_frame.sv` stays the same); (b) the onboard J14 USB-UART via the ARM PS (needs a block design + software, against CLAUDE.md §4's no-block-design rule).
- Status: plan J1-J5 approved by Yazan 2026-10-22, **all done 2026-10-22**: J1 feasibility (EXP-05), J2 bridge RTL, J3 JTAG link tops, J4 Python transport, J5 = EXP-02 and EXP-04 PASS over JTAG on the board.
- Sub-decision (2026-10-22, from EXP-05): use BSCANE2 **USER4** (IR `0x23`), not USER1. hw_server scans USER1 on its own and overwrote the register there. Rejected: USER1 + relying on `jtag lock` (protects only while our session holds the lock).

## Config editor as a local browser form (2026-10-23, Yazan)
- Decision: `python -m nemo_ctl.cli gui` serves a form for the config on 127.0.0.1, standard-library Python only (`http.server`, no web framework), and the page uses no external libraries or fonts. It uses the same parser (`config_from_dict`, now shared with `load_config`), checks (`validate_config`), achieved values (`timing.py`) and writer (`save_config`) as the wizard.
- Reason: Yazan found the question-by-question wizard hard to use, and chose a browser form over a friendlier terminal wizard or a better Excel template. A form shows everything at once, shows only the boxes a type needs, and puts errors next to their pin. It needs nothing installed and works offline on the lab PC.
- Rejected: Flask or another framework (one more dependency); a hosted web page (it can't read or write the local YAML file); tkinter (harder to make clear and to test).
- Safety: binds 127.0.0.1 only, checks the Host header, POSTs must be JSON; Save refuses a config with errors and keeps a `.bak`.

## FPGA outputs that drive the chip use DRIVE 4 + SLEW SLOW
- Decision (Rahaf, 2026-10-26): every FPGA pin that drives a **chip input** (the 22 inputs:
  `clk`, `reset`, `set`, `sipo_in`, `clk_sipo`, `cs`, `rst_sipo`, `clk_piso`, `shift`, ...)
  gets `DRIVE 4` and `SLEW SLOW` in its XDC.
- Reason: EXP-06 §6 [measured on board], 1 MHz on jumper wires. DRIVE 12 -> 4 about halved
  the over/undershoot (far end 2.42 / -0.7 V -> 2.09 / -0.41 V) for edges only 1-3 ns slower
  (~18 -> ~20 ns), which is negligible at the chip's expected clock rates.
- Doesn't apply to the FPGA **inputs** that read the chip's 4 outputs (`sipo_out`,
  `piso_out`, `dft0_buff`, `dft1_buff`): DRIVE exists only on outputs.
- Doesn't change the existing bring-up designs (EXP-01..06): they keep DRIVE 12, as
  verified. `phase5_link_jtag_slew_top` is the measured DRIVE 4 example.
- `SLEW SLOW` is Vivado's default already (I/O reports); it's written out so the intent is
  explicit.
- Rejected / later: a series resistor at the driver (~22-33 Ω) or shorter wires. These are
  wiring changes, kept as the next step if -0.41 V turns out to exceed the chip's input
  rating (unknown: datasheet / Dima).

## Chip-pin -> FMC pin map (jumper wires, grouped by block)
- Decision (Rahaf, 2026-10-26): the chip is connected with **jumper wires** to the HTG-FMC
  J2/J3 headers (P column), not through a fixed adapter board. So the map is ours to choose.
  Layout, agreed as proposed:
  - Clock Generator: `clk` LA00, `reset` LA01, `set` LA02;
  - SIPO: `sipo_in` LA03, `clk_sipo` LA04, `cs` LA05, `rst_sipo` LA06;
  - PISO: `clk_piso` LA07, `shift` LA08, `rst_piso` LA09;
  - Array: `s0_p` / `s1_p` / `s2_p` LA10-12, `pulse` LA13;
  - DSA: `rst_dsa` LA14;
  - DFT: `b0_dft` LA15, `b1_dft` LA20, `b2_dft` LA21, `s0..s3_dft` LA22-25;
  - chip outputs (FPGA inputs): `sipo_out` LA16, `piso_out` LA17, `dft0_buff` LA18,
    `dft1_buff` LA19.
- Reason:
  - the 4 chip outputs land on LA16-19, already verified as FPGA inputs;
  - `clk` gets LA00, the best-measured pin;
  - blocks sit on neighbouring pins;
  - only the outputs on LA05-15 / LA20-25 still need checking (the validator warns for each).
- Correction recorded: earlier docs/handoffs said the map was "waiting for Dima". It never
  was. What needs Dima is the pins' *meaning* (polarities, edges, widths, rates, `rst_sipo`'s
  pad, the input rating), which stays in config fields.
- Rejected: waiting for Dima before mapping.
- Source of truth: `config/nemo_config.yaml` `pin_map`; checked by `validate`
  (`tools/nemo_ctl/fmc_pins.py`). This is step C1 of the chip-pipeline plan (WORKLOG).

## 2026-10-26: EXP-08 virtual chip design (chip pipeline C6), Rahaf
- **Where the virtual chip lives:** in the same bitstream as the controller (`vchip_top` =
  `chip_top` + `virtual_chip`), on separate pins, connected by jumper wires. Reason: one
  board; the wires test the controller's pins and the 4 inputs the way the chip will use
  them. Rejected: connecting inside the FPGA (would skip the pins and wires).
- **Pin budget:** the controller's 7 DFT outputs are not pinned in `vchip_top`, freeing
  LA15 / LA20-25. `chip_top` itself is unchanged (same package, same PC tools).
- **PISO data = `{frame[135:0], sel[23:0], 8'hC6}`** (Rahaf). Reason: the frame comes back
  through Dima's SIPO and PISO, `sel` becomes visible, `C6` shows alignment. Rejected: a fixed
  168-bit pattern (shows neither the SIPO data nor `sel`).
- **phirst from the controller's `pulse` pin** (J3-13 → J2-27), Rahaf. Virtual chip only;
  on the chip phirst is internal (Q4). Rejected: tying it low (`sel` could never step).
- **Dima's RTL unmodified**: it synthesizes (scratch OOC run: `sipo_wrapper`'s async load
  becomes 16 latches), so no rewritten copy. A second standalone `sipo` provides the frame
  because `sipo_wrapper` has no port for it.
