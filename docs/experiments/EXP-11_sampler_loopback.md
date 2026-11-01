# EXP-11: the in-FPGA sampler on the loopback bench (`sample_loopback_top`)

Verification plan Step 3 (`docs/plan_2026-11-01_verification.md`, Yazan). Requirement 2 of
the mentors ("sample the waveform according to a setting"): the FPGA records its own pins
at a chosen rate around a trigger, and the PC reads the record back and shows it.
(EXP-10 is reserved for Step 2, the pad readback.)

**Status: PLANNED, not run yet.** [simulated] Icarus 12 only (2026-11-01):
`sample_cell_tb` 39/39, `sample_loopback_top_tb` 19/19. Not yet: xsim, the bitstream, the board.

## 1. Setup

- **Bitstream**: `sample_loopback_top` (`vivado -mode batch -source scripts/create_project.tcl
  -tclargs sample_loopback_top build`). Before the board: `scripts/run_sample_sim.sh` with
  `SIM=xsim` (the CLAUDE.md §4 rule: xsim too, not only Icarus). Record WNS and the block-RAM
  count (expected: 2 RAMB36 more than `phase7_link_jtag_top`, a 16 x 4096 buffer).
- **Pins / wiring**: exactly as EXP-03 / EXP-04: jumpers J3-0..J3-4 -> J3-16, J2-17..J2-20
  (pairs 0-4). `fpga/constraints/sample_loopback_top.xdc` = `phase7_link_jtag_top.xdc`.
- **J18 (VADJ) on 1V8**. JTAG cable on J17. Logic analyser (MSO-X 2002A digital channels) on
  J3-0 (`clk`) and J3-1 (`rst`) for the cross-check in step 4.

## 2. Procedure (from `tools/`, lab PC)

1. `python -m nemo_ctl.cli seq load ../config/phase7_seq_loopback.yaml --jtag`.
2. `python -m nemo_ctl.cli seq sample --jtag --rate 1kHz --samples 4000 --trigger ext --step 1
   --pre 100 --run --wait 15 --out exp11_a.vcd`
   - expected: `record: 4000 samples, trigger at index 100`, done;
   - `rst` falls at the trigger (index 100 or 101 = the start of step 1, 1 s after RUN) and
     rises 500 ms (500 samples) later; `clk` 8 rising edges at 4 Hz in step 2; `data` = 0xA5 bit by bit;
   - every `*_in` pin has the same edges as its output (same times, one sample).
3. Open `exp11_a.vcd` in GTKWave / PulseView; screenshot to `docs/measurements/`.
4. Cross-check against the instrument: the same run on the logic analyser (`clk`, `rst`);
   the edge times must agree within one sample (1 ms here).
5. Trigger on a pin, faster: `--rate 10MHz --samples 4096 --trigger rise --on clk --pre 50`
   -> `clk` low up to index 49 and high from index 50 (the first rising edge, in step 2); the
   record is 410 us long and `clk` stays high for 125 ms, so that is its only edge.
6. Negative check: pull jumper J2-17 (`rst_in`) and repeat 2: `rst_in` flat at 0, the rest
   unchanged (no FAULT: nothing waits on `rst_in`).
7. `--read-only` after a second `seq run` without a new setup: a new record (re-armed).

## 3. Results

(to be filled in on the lab PC: build numbers, the printed edges, screenshots, the
logic-analyser comparison)

## 4. Conclusion

(to be filled in)
