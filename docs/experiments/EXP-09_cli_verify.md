# EXP-09: automatic PASS/FAIL with `cli verify` (virtual chip and chip_top)

Verification plan Step 1 (`docs/plan_2026-11-01_verification.md`, Yazan). EXP-07 / EXP-08
compared the board's results with the expected ones by eye or with `scripts/repeat_seq.py`
(one cap cell at a time). This experiment runs the new `cli verify`, which checks every
capture that has an `expect` in the config and prints PASS/FAIL per pin.

**Status: Part A PASS** [measured on board] 2026-11-02 (steps 1-5, `vchip_top` rebuilt
2026-11-02 with the pad-readback `chip_top`). Part B: covered by EXP-10 (`cli verify` on the
new `chip_top`, 100/100, 2026-11-02); steps 6-7 as written not repeated. [tested] pytest
(fake board, `tools/nemo_ctl/tests/test_verify.py`, 2026-11-01).

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

1. **Order: no jumpers -> program `vchip_top` -> then the 10 jumpers** (with `chip_top`
   loaded, J2-20..25 are outputs). `vchip_top` must be rebuilt after 2026-11-02 (it contains
   `chip_top`, which changed for the pad readback). `python -m nemo_ctl.cli verify --seq ../config/exp09_verify_vchip.yaml --dry-run`
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

6. **Remove the 10 jumpers first** (with `chip_top`, J2-20..25 are outputs: J3-3..8 -> J2-20..25
   would join two outputs). Then program `chip_top`. (Part B is also covered by EXP-10, which
   ran `cli verify` on `chip_top` with the pad readback, 2026-11-02.) `python -m nemo_ctl.cli verify --mode INFERENCE --config ../config/exp07_test.yaml --jtag`
   → `(run)` PASS, the 4 captures shown, not judged (no chip connected).
7. In the editor (`python -m nemo_ctl.cli gui --config ../config/exp07_test.yaml`), press
   **Verify** with runs = 10 → the same table in the page; **Copy as Markdown** works.

## 3. Results (2026-11-02, lab PC, Rahaf at the bench), [measured on board]

### Setup
- `vchip_top` rebuilt 12:51 (WNS +0.060 / WHS +0.034 ns, 17,741 LUT / 23,893 FF / 4.5 BRAM,
  0 critical warnings). J18 1V8, J17.
- Order kept: EXP-11's 5 jumpers removed -> **no jumpers** -> 14:20:48 programmed `vchip_top`
  (DONE=1) -> Rahaf put on the 10 jumpers.
- Readback in this top: `PAD_READBACK = 0`, the 22 outputs are read from the output
  registers inside the FPGA (its DFT outputs have no pins), so the readback rows check the
  controller logic, not the pads.

### Runs
| # | Time | Step | Result |
|---|---|---|---|
| - | 14:27:08 | 1 `--dry-run` | 2 expectations: `sipo_out: level 1`, `piso_out: serial 0x5AA5…E7E70000E7C6` |
| 1 | 14:28:19 | 2 | **FAIL**: `piso_out` = all 168 bits 1, `sipo_out` = 0; `(run)` + 22 readback rows + the sipo_in frame PASS. Cause (Rahaf): the two return wires were **swapped**, J2-28 -> J2-17 and J2-29 -> J3-16, so each capture read the other vchip output |
| 2 | 14:32:16 | 2 (same wiring) | **FAIL**: `piso_out` = `0x5AA` then 0s, `sipo_out` = 1 (still swapped: J2-17 read the vchip's `sipo_out` line, whose content depends on the previous load) |
| 3 | 14:35:32 | 2 (wires moved to J2-28 -> J3-16, J2-29 -> J2-17) | **PASS: 26 pass, 0 fail, 3 not judged**; `piso_out` = `0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6` bit-exact, `sipo_out` 1 |
| 4 | 14:36:13-14:36:47 | 3 `--repeat 300` | **PASS, every row 300/300**, exit 0 (`docs/measurements/EXP-09_a_verify_300.md`) |
| 5 | 14:37:25 | 4 negative: expect `…E7C7` (copy of the config, last digit 6 -> 7) | FAIL on `piso_out` only: **"1 bit wrong: PISO3 tdc_out0 bit 0"**; the rest PASS (25/1); exit 1 |
| 6 | 14:38:58 | 5 negative: J2-29 -> J2-17 pulled | FAIL on `piso_out` only: all 0 (PULLDOWN), **82 bits wrong = the 82 ones of the expected frame**; `sipo_out`, `(run)`, readback PASS; exit 1 |

- The plan expected `3 pass`; the 23 pad-readback rows (Step 2, added after the plan) make
  it 26.
- The swap was safe: both wrong wires joined an FPGA output to an FPGA input.
- The EXP-08 first-run corruption (1/310) did not appear in these 303 correctly wired runs
  (plus 2 swapped ones after programming). Still open in `docs/issues.md`.

## 4. Conclusion

**Part A PASS.** `cli verify` judges the virtual chip's answer correctly on the board: the
EXP-08 frame comes back bit-exact 300/300, a one-bit wrong expectation fails exactly that bit
(named by PISO / field / bit), and a pulled wire fails exactly that pin. The swapped return
wires in runs 1-2 were also caught (FAIL, controller side still PASS), which pointed at the
wiring rather than the design. Part B (`chip_top`) is covered by EXP-10.
