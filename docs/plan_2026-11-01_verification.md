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
   # (dft0_buff: {type: CAPTURE, mode: edge_count, expect: 136}: dropped 2026-11-02, an edge
   #  count is cleared when the run ends and can't be checked after it, docs/issues.md)
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
   **Added while building it:** `--seq <file>` runs a step sequence (expect on a step's
   `capture:` entry) instead of a mode, because EXP-08's PISO readback needs `shift` raised
   between the load and the read, which a single editor mode can't express.
4. **Editor.** See "Interface changes" below. A **Verify** button next to Run on board in `gui.py` / `config_gui.html`
   (`POST /api/verify`), the table shown under the Signals panel; `expect:` editable per pin.
5. **Tests (laptop).** pytest with a fake link returning chosen captures: all-pass, each
   kind failing, tolerance edges, missing capture, repeat counts; config round trip; GUI endpoint.
6. **Lab.** EXP-09 (`docs/experiments/EXP-09_cli_verify.md`, `config/exp09_verify_vchip.yaml`): `cli verify --seq ... --jtag` on `vchip_top` (the virtual chip returns a known
   PISO frame, so `expect:` is known exactly) and on `chip_top`. Pass = the table matches
   what EXP-07/08 measured, and a deliberately wrong `expect:` gives FAIL on that pin only.

Done when: pytest green, EXP-09 PASS, USER_MANUAL section added.

## Step 2: read every output back at its own pad (RTL, `chip_top`; agreed with Rahaf 2026-11-02)

Goal: check all 22 outputs on every run, with the chip connected, without extra pins.

**Decided 2026-11-02 (Rahaf):** a new cell (not a change to `cap_cell`); the `sipo_in`
bit-exact check now; work on `main`; RTL + tests first, stop after simulation, then the PC
side, the build and EXP-10, each after her OK. (Design below replaces the 2026-11-01 sketch:
that one counted edges with `cap_cell`, which clears its count when the run ends.)

1. **The problem the design works around.** Everything is read after the run: by then the
   outputs are back at idle and `cap_cell` has cleared its edge count. So the readback cell
   records during the run and keeps its results until the next RUN starts.
2. **`fpga/src/readback_cell.sv` (new), one per output:** during the run (its `run` delayed
   by the same 2 ticks as the synchronizer, so the window matches the pin): rising-edge
   count, "saw 0" / "saw 1", last period and high time, level when the run ended. Cleared
   on RUN rising, held after. No settings (nothing in the step table).
3. **`chip_top.sv`:** each output an `IOBUF` (T = 0, always driving); its `O` through a 2-FF
   synchronizer into its `readback_cell`. Parameter `PAD_READBACK` (1 = IOBUF; 0 = the cell
   reads the output register internally, for `vchip_top`, whose 7 DFT outputs have no pin).
   **`sipo_in` bit-exact:** its readback shifted on the readback of `clk_sipo`'s sampling
   edge (the edge opposite `SIPO_ON_FALLING`, as the chip samples) into a 136-bit register.
   Link region (READ_REG): 0x0200 + 16 x cell (flags, edges, period, high), an info block
   (cell count, `PAD_READBACK`, SIPO bit count) and the SIPO register. 16-byte stride: the
   address bits pick the cell, no compare chain (timing was +0.112 ns).
4. **`gen_svh.py --chip`:** the region constants in `chip_pkg.sv`. XDC unchanged (same port
   names; DRIVE 4 / SLEW SLOW apply to the IOBUF's driver). `chip_target()` and the step
   table unchanged (534 of 1024 bytes).
5. **PC (`link.py`, `verify.py`, editor):** the expected readback derived from the run itself
   (`waves.py` for a mode, `seqwaves.py` for a sequence): edges and flags exact, period /
   high within a few ticks; wait steps (variable length) only by flags. A "Readback" table
   in `cli verify` and the editor's Verify.
6. **Tests:** `readback_cell_tb`; `chip_top_tb` extended (every pin type, a pin forced wrong
   -> only that pin FAILs, the SIPO frame bit-exact); `vchip_top_tb` still 9/9; xsim; pytest.
7. **Lab:** build (timing, I/O report still DRIVE 4 / SLOW, resources); **EXP-10**: every
   mode -> readback PASS on all 22 pins, compared once with the logic analyser; negative
   check = a deliberately wrong expectation. The 2026-11-01 "tie a pin to GND" is dropped
   (shorting a driving output is not safe).
8. **What it can't see:** an open after the pad (connector, HTG board, wire, chip socket),
   and analog level / ringing (0/1 at the 0.9 V threshold). Those stay with the scope.

## Step 3: sample cell (logic-analyser capture, R2)

**Progress 2026-11-01 (Yazan):** item 1 (RTL) and the decode/compare half of item 4 are done
and [simulated] / [tested]: `fpga/src/sample_cell.sv` + `fpga/tb/sample_cell_tb.sv` 39/39
(Icarus 12; xsim still to run on the lab PC), `tools/nemo_ctl/samples.py` + pytest 24.
Changes from the text below: the config is taken when a record is **armed** (run rising), not
on apply (a mid-run apply would have changed a running record); a `trig_count` output places
the record on the RUN time axis. Open: where `sample:` lives in the config (a mode only holds
blocks, as for `expect`), the link region (item 2), the test top on the loopback pairs (item 6),
and the editor overlay.

**Progress 2026-11-01, later (Yazan):** items 2 and 6 (laptop part) done: `phase7_link_top`
parameter `SAMPLER` + wrapper `fpga/src/sample_loopback_top.sv` / `.xdc` (pins of
`phase7_link_jtag_top`, none moved), register map "v2 sampler", `SeqLink.sampler_*`,
`cli seq sample` (VCD / CSV out), `fpga/tb/sample_loopback_top_tb.sv` 19/19. Next on the lab
PC: xsim, the bitstream, EXP-11 (`docs/experiments/EXP-11_sampler_loopback.md`). Still open: a
sampler in `chip_top` (with Rahaf), `sample:` in the mode config, the editor overlay.

**Progress 2026-11-01, third part (Yazan):** the PC-side comparison (item 4) for sequences: the
record now carries the step number (bits 13:10), `tools/nemo_ctl/seqwaves.py` builds a
sequence's expected waves from the step starts the record shows (others derived across
fixed-length steps), and `cli seq sample --check <sequence>` gives PASS / FAIL per pin and a
VCD with `<pin>_exp`. Checked on the RTL's own records in simulation
(`scripts/check_sample_dump.py`: jumpers in -> all pass; `clk_in` pulled -> only `clk_in`
fails). **What's left of Step 3 needs the lab or Rahaf:** xsim + the build + EXP-11, and a
sampler in `chip_top`. The `sample:` part of the mode config and the editor overlay are only
useful once `chip_top` has a sampler (the editor works on chip modes), so they move there.

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
