# EXP-11: the in-FPGA sampler on the loopback bench (`sample_loopback_top`)

Verification plan Step 3 (`docs/plan_2026-11-01_verification.md`, Yazan). Requirement 2 of
the mentors ("sample the waveform according to a setting"): the FPGA records its own pins
at a chosen rate around a trigger, and the PC reads the record back and shows it.
(EXP-10 is reserved for Step 2, the pad readback.)

**Status: PASS** [measured on board] 2026-11-02 (steps 1-3, 5-7; step 4, the logic-analyser
cross-check, not done). [simulated] Icarus 12 and xsim 2022.1: `sample_cell_tb` 39/39,
`sample_loopback_top_tb` 24/24.

## 1. Setup

- **Bitstream**: `sample_loopback_top` (`vivado -mode batch -source scripts/create_project.tcl
  -tclargs sample_loopback_top build`). Before the board: `scripts/run_sample_sim.sh` with
  `SIM=xsim` (the CLAUDE.md §4 rule: xsim too, not only Icarus). Record WNS and the block-RAM
  count (expected: 2 RAMB36 more than `phase7_link_jtag_top`, a 16 x 4096 buffer).
- **Pins / wiring**: exactly as EXP-03 / EXP-04: jumpers J3-0..J3-4 -> J3-16, J2-17..J2-20
  (pairs 0-4). **Order (2026-11-02): no jumpers -> program `sample_loopback_top` -> then the
  jumpers.** With `chip_top` loaded, J2-20 is an output (b1_dft), so J3-4 -> J2-20 would join
  two outputs. `fpga/constraints/sample_loopback_top.xdc` = `phase7_link_jtag_top.xdc`.
- **J18 (VADJ) on 1V8**. JTAG cable on J17. Logic analyser (MSO-X 2002A digital channels) on
  J3-0 (`clk`) and J3-1 (`rst`) for the cross-check in step 4.

## 2. Procedure (from `tools/`, lab PC)

1. `python -m nemo_ctl.cli seq load ../config/phase7_seq_loopback.yaml --jtag`.
2. `python -m nemo_ctl.cli seq sample --jtag --rate 1kHz --samples 4000 --trigger ext --step 1
   --pre 100 --run --wait 15 --check ../config/phase7_seq_loopback.yaml --out exp11_a.vcd`
   - expected: the check table `PASS: 10 pass, 0 fail` (exit 0);
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
6. Negative check: pull jumper J2-17 (`rst_in`) and repeat 2: `rst_in` flat at 0 and the
   check FAILs on `rst_in` only (no FAULT: nothing waits on `rst_in`). (The same check on the
   RTL's own records passes in simulation: `scripts/run_sample_sim.sh`, record A all pass,
   record B fails on the pulled `clk_in` only.)
7. `--read-only` after a second `seq run` without a new setup: a new record (re-armed).

## 3. Results (2026-11-02, lab PC, Rahaf at the bench), [measured on board]

### Build
- `sample_loopback_top`: timing met, **WNS +0.148 ns / WHS +0.012 ns**, 0 critical warnings;
  6,434 LUT / 10,958 FF / **4.5 BRAM** (`phase7_link_jtag_top` 2.5: +2 RAMB36 = the 16 x 4096
  buffer, as expected).

### Bench
- J18 on 1V8, JTAG on J17. Order kept: **no jumpers** -> 13:08:12 programmed
  `sample_loopback_top` (DONE=1; link idle, `sampler_info` = 16 bits x 4096) -> Rahaf put on the
  5 jumpers J3-0->J3-16, J3-1->J2-17, J3-2->J2-18, J3-3->J2-19, J3-4->J2-20 (P column).
  No logic analyser (step 4 not done).

### Runs
| # | Time | What | Result |
|---|---|---|---|
| 1 | 14:09:02 | step 1 `seq load` | 6 steps loaded, step 0 applied |
| 2 | 14:09:13 | step 2 (1 kHz, ext trigger at step 1, `--check`) | **FAULT at step 4** (`confirm`, waits for `en_in` high); record 3211 samples (stopped at the fault); check `9 pass, 1 fail`: `en` rose at 3761 ms, **`en_in` 0 edges**. Cause: the J3-4 -> J2-20 jumper was not making contact; Rahaf re-seated it ("fixed the jumper"). `EXP-11_a_run1_fault.vcd` / `.svg` |
| 3 | 14:11:20 | step 2 again | **PASS: 10 pass, 0 fail**; `record: 4000 samples, trigger at index 100`, triggered done; STATUS `done late` (expected: `confirm` ends at once, EXP-04 §5) |
| 4 | 14:11:49 | step 5 (10 MHz, rise on `clk`, pre 50) | **PASS**: `clk` (and `clk_in`) low up to index 49, high from index 50 (5000 ns in the VCD at 100 ns/sample); trigger at 2.0100 s after RUN (sample 20,100,001) |
| 5 | 14:12:16 | step 7 as written: `seq run`, then `--read-only` | record identical to run 4 byte for byte (the sequence is deterministic, so this alone can't show a new record) |
| 6 | 14:12:37 | step 7 sharpened: set up rise on **`cs`** (no run), `seq run`, `--read-only` | **PASS (re-armed)**: a new record, trigger at 4.010 s (sample 40,100,001), `cs` / `cs_in` rise at index 50, `en` / `en_in` already high |
| 7 | 14:13:29 | step 6 negative, one jumper pulled | sequence ends `done late` (no FAULT); check **`9 pass, 1 fail`: `data_in` 0 edges, all 8 expected edges missing**; the other 9 pins PASS, `rst_in` follows `rst` |

Run 3 in detail (`docs/measurements/EXP-11_a.vcd`, drawing `EXP-11_a.svg`; times after RUN,
1 ms resolution):
- `rst` (and `rst_in`): falls at 1.001 s (the trigger, start of step 1), rises at 1.501 s:
  500 samples later.
- `clk`: 16 edges, rises at 2.011, 2.261 s, ... (250 ms period = 4 Hz, 8 rises in step 2).
- `data`: 8 edges from 2.001 s; read at each `clk` rise from the VCD: **10100101 = 0xA5**.
- `en` rises at 3.761 s (step 3), `cs` 4.011 -> 4.511 s.
- Every `*_in` has the same edges at the same sample as its output.

Step 6 note: the plan said "pull J2-17 (`rst_in`)". The record showed `rst_in` still connected
and `data_in` flat, so before recording it Claude asked; Rahaf checked the board: the jumper
pulled was **J2-18** (`data_in`, LA18_P), matching the pin map (EXP-03 table). So the negative
check was done on `data_in` instead of `rst_in`: it fails on exactly that pin. Side
observation: the sequence did **not** FAULT, although step 2 waits for `data_in` "captured":
the SERIAL capture counts `clk_in` edges, so it captured 0x00 and went on. Only the sampler
check (or reading `data_in`'s capture) shows the missing data.

Step 3: the lab PC has no VCD viewer (no GTKWave / PulseView); the records are drawn as SVG
timing diagrams instead (`docs/measurements/EXP-11_a.svg`, `EXP-11_neg.svg`,
`EXP-11_a_run1_fault.svg`; a small script from the VCD, outputs blue, inputs red).
VCDs: `EXP-11_a.vcd`, `EXP-11_a_run1_fault.vcd`, `EXP-11_neg.vcd`,
`EXP-11_b_clk_rise_10MHz.vcd`, `EXP-11_d_rearm_cs_rise.vcd`.

Not done: step 4 (logic-analyser cross-check, optional).

## 4. Conclusion

**PASS** (steps 1, 2, 3, 5, 6, 7; step 4 not done). The in-FPGA sampler records all 10
loopback pins on the board at 1 kHz and 10 MHz, triggers on a step start and on a pin edge
at exactly the programmed index, re-arms on each run, and its record, judged against the
sequence by `--check`, PASSES when the bench is right and fails on **exactly the pin** that
is disconnected (twice, once by accident: a loose J3-4 -> J2-20 jumper, once on purpose:
J2-18). It found a bench fault on its own. Limit: it samples the pins inside the FPGA (logic
level after the input buffer), so it is not an independent instrument; the logic-analyser
cross-check (step 4) is still open.
