# Plan: automatic verification of the chip controller (2026-11-01, Yazan)

Closes the gaps in the mentors' three requirements:

| # | Requirement (mentors) | Status 2026-11-01 | Closed by |
|---|---|---|---|
| R1 | Read the input from a file and output the waveform | Done: `config/nemo_config.yaml` -> `cli run-mode` -> `chip_top` (EXP-07) | - |
| R2 | Sample the waveform according to a setting | Partly: `cap_cell` LEVEL / EDGE_COUNT / PERIOD / SERIAL | Step 3 (sample cell) |
| R3 | Check that the output is what we expected | Partly: `repeat_seq.py` compares SERIAL captures, `program_verify()` | Step 1 (`expect:` + `cli verify`), Step 2 (pad readback) |

**Not in this plan:** jumpering outputs back to inputs in rounds ("option B"). With
`pin_map`, 26 of the 34 LA_P pins are in use (22 outputs LA00-15 + LA20-25, 4 inputs
LA16-19), so only LA26-LA33 are free. All 22 outputs can't be looped back at once, and
the jumpers can't stay once the chip is connected (`docs/decisions.md`, 2026-11-01).

Order: 1 -> 2 -> 3. Step 4 runs in parallel. Each step: laptop part first (Icarus 12 +
pytest), then a lab part (xsim, Vivado build, board run) with its own EXP report.

---

## Step 1: `expect:` in the config + `cli verify` (Python only, no RTL)

Goal: one command that runs a mode on the board and says PASS/FAIL per captured pin.

1. **Config format.** An optional `expect` field (plus `tolerance` / `mask`) inside each
   CAPTURE setting in `config/nemo_config.yaml`; what it means follows the pin's capture mode:
   ```yaml
   sipo_out:  {type: CAPTURE, mode: level, expect: 0}           # level when read, after the run
   dft0_buff: {type: CAPTURE, mode: edge_count, expect: 136}    # rising edges; tolerance: N edges
   dft1_buff: {type: CAPTURE, mode: period, expect: 1us, tolerance: 1%}   # or 1MHz; tolerance in % or a time
   piso_out:  {type: CAPTURE, mode: serial, clock: clk_piso, bits: 168, edge: falling,
               expect: "0x...", mask: "0x..."}                  # mask: 1 = bit is checked
   ```
   It sits in the pin's own setting, not in a separate `expect:` section, because a mode only
   holds blocks (a separate key would be read as a block), and so the editor shows it on the
   pin's row. `mode_seq.py` already ignores fields it doesn't use, so it is unchanged.
   Files: `tools/nemo_ctl/validate.py` (expect only on CAPTURE, value fits the mode and the
   width, units parse; `config.py` keeps unknown fields already).
2. **Compare.** New `tools/nemo_ctl/verify.py`: `check_captures(config, mode, captures) ->
   [Row(pin, kind, expected, actual, ok, note)]`; PISO frames decoded with `sipo_piso.decode_piso_frame`
   so a mismatch names the stage and field (e.g. `stage 2 out0 bit 5`).
3. **Command.** `cli verify --mode INFERENCE [--repeat N] [--jtag] [--out report.md|.csv]`:
   runs the mode through `mode_seq.run_table` (no change to Rahaf's `mode_seq.py` beyond
   reading what `run_table` already returns; if it needs a change, agree it with her first),
   prints the table, exits non-zero on any FAIL. With `--repeat`: pass count per pin.
4. **Editor.** See "Interface changes" below. A **Verify** button next to Run on board in `gui.py` / `config_gui.html`
   (`POST /api/verify`), the table shown under the Signals panel; `expect:` editable per pin.
5. **Tests (laptop).** pytest with a fake link returning chosen captures: all-pass, each
   kind failing, tolerance edges, missing capture, repeat counts; config round trip; GUI endpoint.
6. **Lab.** EXP-09: `cli verify --jtag` on `vchip_top` (the virtual chip returns a known
   PISO frame, so `expect:` is known exactly) and on `chip_top`. Pass = the table matches
   what EXP-07/08 measured, and a deliberately wrong `expect:` gives FAIL on that pin only.

Done when: pytest green, EXP-09 PASS, USER_MANUAL section added.

## Step 2: read every output back at its own pad (RTL, `chip_top`; agree with Rahaf first)

Goal: check all 22 outputs on every run, with the chip connected, without extra pins.

1. **How.** Each chip output becomes an `IOBUF` with `T = 0` (always driving); its `O`
   (the pad's input buffer) goes through a 2-FF synchronizer into a `cap_cell`. The XDC
   keeps `DRIVE 4` + `SLEW SLOW` (they apply to the IOBUF output driver the same way).
2. **What it proves / doesn't.** Proves the right level/edges/period leave the FPGA pad,
   and catches a pad shorted to ground or to another pin (readback disagrees). Does **not**
   catch an open after the pad (FMC connector, HTG board, wire) - that stays with the
   logic analyser / scope.
3. **Files.** `gen_svh.py --chip` (Rahaf's generator: readback cells in `chip_pkg.sv`, the
   ports in the XDC), `chip_top.sv`, `sequence.chip_target()` (22 more cap cells: each step
   entry grows by 22 x 5 B, check it still fits `Target.entry_bytes` = 1024),
   `link_register_map.md`. Either Rahaf does the RTL and I do the PC side, or I do it on
   a branch she reviews - decided with her before starting.
4. **Expect.** `verify.py` derives the expected readback from each output's own setting
   (HIGH -> level 1, CLOCK -> edges + period, PULSE -> edges, SERIAL -> bits), so no
   `expect:` lines are needed for outputs; the 2-3 tick sync delay is part of the tolerance.
5. **Tests (laptop).** `chip_top_tb` extended: readback matches for every pin type; a
   forced pad value (tb drives the pad against the FPGA) is reported as a mismatch.
   pytest for the derived expectations. Resource check: 22 more `cap_cell`s (estimate on
   the lab PC from the Vivado utilization report).
6. **Lab.** xsim, bitstream, timing met, I/O report still shows DRIVE 4 / SLOW. EXP-10:
   every mode in the config gives readback PASS on all 22 pins; one pin tied to GND through
   a jumper to the SMA shell gives FAIL on that pin only (pass criterion for the check itself).

## Step 3: sample cell (logic-analyser capture, R2)

Goal: record chosen pins at a chosen rate into FPGA memory and show them on the PC.

1. **RTL.** New `fpga/src/sample_cell.sv`: N input bits (outputs' readback from Step 2 +
   the 4 chip inputs), config `RATE_DIV` (sample every k ticks of 100 MHz), `N_SAMPLES`,
   `TRIGGER` (at step start / rising or falling edge on pin p / level), `PRE_TRIGGER`
   samples. Block RAM ring buffer; flags `armed / triggered / done`. One write port, read
   port on the link byte bus.
2. **Link.** A sample region in `link_register_map.md` (v3 section), read with
   `READ_CAPTURE` in blocks; `SeqLink.read_samples()`. At ~1.2 ms per 128-byte JTAG scan,
   4096 samples x 32 bits = 16 KB ~ 0.15 s.
3. **Config.** `sample:` per mode (pins, rate, length, trigger); validator checks
   rate/length against the buffer size and the mode's duration.
4. **PC.** Samples drawn in the editor's Signals panel on top of the expected waves
   (`waves.py`), differences highlighted; `cli verify` can compare sampled edges to the
   expected edge times with a tolerance of one sample period.
5. **Tests (laptop).** `fpga/tb/sample_cell_tb.sv` self-checking in Icarus 12: each
   trigger kind, pre-trigger, rate divider, wrap, re-arm; pytest for decode + compare.
6. **Lab.** First in its own test top on the loopback pairs (doesn't touch `chip_top`),
   then in `chip_top` (with Rahaf). EXP-11: sampled `clk_sipo` / `sipo_in` match the logic
   analyser capture of the same run.

## Interface changes (browser editor only; the terminal wizard is not changed, decided 2026-11-01)

| Step | Change |
|---|---|
| 1 | An **Expect** field on each capture pin's row (+ tolerance / mask), checked live. A **Verify** button next to Run on board: PASS/FAIL table per pin (expected, measured, note), a FAIL row jumps to its pin; with repeat N, passes out of N per pin. |
| 2 | The Verify table gets a **Readback** section for the 22 outputs (expected values derived from each output's setting, nothing to type). |
| 3 | A **Sampling** box per mode (pins, rate, length, trigger, pre-trigger samples; warns if the buffer is too small). The Signals panel draws the measured samples over the expected waves and marks where they differ. |

## Step 4 (parallel): send Dima the questions

Add the "how far below ground may the inputs go" question (ringing of 0.4-0.7 V,
`docs/issues.md`) to `docs/questions_for_dima_2026-10-22.md`, final read with Rahaf, send.
Answers feed the `expect:` values of the real chip modes (Q1, Q5, Q7).

## Ownership / process

- Branch `feature/yazan-verify`; WORKLOG "Currently working on" updated before each step.
- Rahaf owns `chip_top.sv`, `mode_seq.py`, `gen_svh.py --chip`, `pin_map`: Steps 2 and 3's
  `chip_top` parts are agreed with her first.
- Every step: WORKLOG entry, EXP report for each lab run, results tagged [simulated] /
  [measured on board], CLAUDE.md §5-§7 updated in the merge PR.
