# EXP-09: automatic PASS/FAIL with `cli verify` (virtual chip and chip_top)

Verification plan Step 1 (`docs/plan_2026-11-01_verification.md`, Yazan). EXP-07 / EXP-08
compared the board's results with the expected ones by eye or with `scripts/repeat_seq.py`
(one cap cell at a time). This experiment runs the new `cli verify`, which checks every
capture that has an `expect` in the config and prints PASS/FAIL per pin.

**Status: PLANNED, not run yet.** [simulated / tested] pytest only (fake board,
`tools/nemo_ctl/tests/test_verify.py`, 2026-11-01). No new bitstream: it reuses EXP-08's
`vchip_top` and EXP-07's `chip_top`.

## 1. Setup

- **Bitstreams**: `vchip_top` (EXP-08, unchanged), then `chip_top` (EXP-07, unchanged).
- **Wiring**: Part A exactly as EXP-08 (10 jumper wires, `fpga/constraints/vchip_top.xdc`
  header). Part B as EXP-07 (logic analyser optional).
- **J18 (VADJ) on 1V8**. JTAG cable on J17.
- **Configs**:
  - `config/exp09_verify_vchip.yaml`: `config/chip_sim_test.yaml` (the EXP-08 sequence) with
    `expect` on the captures. The expected values are what EXP-08 **measured** on the board:
    `piso_out` = `0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6`, `sipo_out` = 1 after the run.
  - Part B: `config/exp07_test.yaml` mode INFERENCE (no expects needed: only the run status
    is judged; the 4 capture rows are shown as `-`).

## 2. Procedure (from `tools/`, lab PC)

**Part A: vchip_top**

1. Program `vchip_top`. `python -m nemo_ctl.cli verify --seq ../config/exp09_verify_vchip.yaml --dry-run`
   lists 2 checks (`sipo_out: level 1`, `piso_out: serial 0x…C6`).
2. `python -m nemo_ctl.cli verify --seq ../config/exp09_verify_vchip.yaml --jtag`
   → expected `PASS: 3 pass, 0 fail, 2 not judged, 1 run`.
3. `… --jtag --repeat 300 --out exp09_a.md` → expected `3/3 pass` rows with `300/300 pass`
   on `piso_out` (EXP-08 saw 309/310; a single first-run corruption is the open item in
   `docs/issues.md`, record it if it happens).
4. **Negative check** (the checker itself): copy the config, change the last hex digit of the
   `piso_out` expect from `6` to `7`, run once → expected FAIL on `piso_out` only, note
   `1 bit wrong: PISO3 tdc_out0 bit 0`; `sipo_out` and `(run)` still PASS.
5. Pull the `piso_out` jumper (J2-29 → J2-17), run once → expected FAIL on `piso_out`
   (all bits 0 through the PULLDOWN; the `C6` tail missing).

**Part B: chip_top**

6. Program `chip_top`. `python -m nemo_ctl.cli verify --mode INFERENCE --config ../config/exp07_test.yaml --jtag`
   → `(run)` PASS, the 4 captures shown, not judged (no chip connected).
7. In the editor (`python -m nemo_ctl.cli gui --config ../config/exp07_test.yaml`), press
   **Verify** with runs = 10 → the same table in the page; **Copy as Markdown** works.

## 3. Results

(to be filled in on the lab PC: the tables from `--out`, exit codes, anything unexpected)

## 4. Conclusion

(to be filled in)
