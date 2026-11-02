# EXP-10: pad readback of the 22 outputs (`cli verify` on the new `chip_top`)

Verification plan Step 2 (`docs/plan_2026-11-01_verification.md`, decided 2026-11-02). EXP-07
checked the 22 outputs once, by eye, on the logic analyser. This experiment checks that the
FPGA itself reads every output back at its pin and that `cli verify` judges them right.

**Status: PASS** [measured on board] 2026-11-02 (steps 1, 2, 3, 5; step 4, the optional
logic-analyser cross-check, not done). [simulated] `chip_top_tb` 15/15, `readback_cell_tb` 10/10 (xsim);
pytest `test_readback.py` 15 (the Python expectation = the RTL's numbers).

## 1. Setup
- **Bitstream:** `chip_top` rebuilt with the readback (`create_project.tcl -tclargs chip_top
  build`): record WNS, utilization, and that the I/O report still shows DRIVE 4 / SLEW SLOW on
  `chip_out[*]` (now IOBUFs) and PULLDOWN on `chip_in[*]`.
- **Board:** ZedBoard, J18 on 1V8, J17. **No jumpers** (as EXP-07). Logic analyser optional.

## 2. Procedure (from `tools/`)
1. Program `chip_top`. `python -m nemo_ctl.cli verify --seq ../config/chip_sim_test.yaml --jtag`
   -> the "Pad readback" section: 22 pins + the `sipo_in` frame, all PASS; `(readback)` says
   "at the pads". Expected per pin = `test_readback.py`'s RTL table (clk_sipo 136 edges /
   period 100 / high 50, clk_piso 168, cs 1 edge / high 100, sipo_in 32 edges, ...).
2. `... --repeat 100 --out exp10_seq.md` -> 100/100 on every row.
3. A mode: in the editor, INFERENCE (with a `sipo_in` frame typed, not saved), **Verify** ->
   the readback section all PASS. Same with `cli verify --mode INFERENCE --config <a copy with
   the frame>`.
4. Optional, once: logic analyser on 8 of the outputs (as EXP-07 pass 1) during one run, to
   confirm the readback numbers independently (edges / period of clk_sipo, clk_piso).
5. **Negative check (the checker itself):** after a run of step 1, read the readback once and
   check it against a deliberately altered copy of the steps (`clk_sipo` 135 cycles instead of
   136); exactly these may FAIL: `clk_sipo` (edges), `sipo_in` (its last bit follows
   clk_sipo: end level, high) and the `sipo_in frame` (bit count); every other row PASS
   (dry run on the simulated numbers, 2026-11-02: exactly those three):
   ```
   python -c "import yaml, copy; from nemo_ctl.jtag import open_jtag; from nemo_ctl.link import SeqLink; from nemo_ctl.sequence import chip_target; from nemo_ctl.readback import check_readback; st = yaml.safe_load(open('../config/chip_sim_test.yaml'))['steps']; bad = copy.deepcopy(st); bad[1]['set']['clk_sipo']['cycles'] = 135; sl = open_jtag(link_cls=SeqLink, target=chip_target()); rb = sl.read_readback(); sl.close(); [print(r.pin, r.ok, r.note) for r in check_readback(bad, [c.name for c in chip_target().sig_cells], rb) if r.ok is False]"
   ```
   No pin is shorted on purpose (not safe for a driving output).

## 3. Results (2026-11-02, lab PC), [measured on board]

### Build
- First build (12:14): **timing NOT met**, WNS -0.046 ns, 3 failing endpoints, all
  `u_frame/bus_raddr -> bus_rdata` (14 logic levels, 6 CARRY4): the readback region's range
  compares / subtractions on the register read path, which had +0.112 ns before. Not
  programmed. Fix: the region decoded from address bits only (0x0200-0x03FF = `a[15:9]`,
  `a[8:4]` = 32 records of 16 bytes, `a[3:0]` = the byte), same addresses
  (`docs/issues.md`). In xsim the first version of that (`rec[a[3:0]*8 +: 8]`) returned byte
  0 for every address; shifts by `{a, 3'b0}` instead -> `chip_top_tb` 15/15 again,
  `vchip_top_tb` 9/9.
- Second build (12:27): **timing met, WNS +0.176 ns**, WHS +0.013 ns, 0 critical warnings;
  17,652 LUT / 23,433 FF / 4.5 BRAM / 35 IOB (was 12.5k / 19.4k / 4.5 / 35). I/O report: all
  22 `chip_out[*]` BIDIR, LVCMOS18, **DRIVE 4, SLOW**; the 4 `chip_in[*]` PULLDOWN.

### Runs
- Setup (Rahaf, unchanged since 11:25): J18 1V8, J17, **no jumpers**. 12:28:47 programmed
  `chip_top` (DONE=1).
- **Step 1** `verify --seq ../config/chip_sim_test.yaml --jtag`: `(run)` PASS; readback "22 pins
  at the pads, window **31953 ticks** (319.53 us)" = the simulation's number exactly; **all 22
  pins + the sipo_in frame PASS**, each equal to the RTL table (clk_sipo 136 / 100 / 50,
  clk_piso 168 / 100 / 50, sipo_in 32 edges / 800 / 300, cs 1 / high 100, shift 1 edge ending
  high, reset / rst_sipo / rst_piso held high, the other 14 held low); frame
  `0x5AA55A0FF0123456789ABCDEF0C3C3E7E7` bit-exact. `PASS: 24 pass, 0 fail, 5 not judged`.
- **Step 2** `... --repeat 100 --out ../docs/measurements/EXP-10_verify_seq_100.md`
  (12:28:59-12:29:11): **every readback row 100/100**, `PASS: 24 pass, 0 fail, 100 runs`.
- **Step 5** (negative): the board's readback checked against a copy with clk_sipo 135
  cycles: FAIL on exactly `clk_sipo` (edges), `sipo_in` (end, high) and `sipo_in frame` (136
  bits sampled, 135 expected); the other 20 rows PASS. The checker catches a real difference
  and nothing else.
- **Step 3** (editor, restarted with the current code): Rahaf, mode INFERENCE with a `sipo_in`
  frame typed (not saved), **Verify**: "all pass in the editor" (the Pad readback section, 22
  pins + the frame). The table itself was not copied into this report.
- Step 4 (logic analyser cross-check): optional, not done.

## 4. Conclusion
- **EXP-10 PASS.** The FPGA reads every one of its 22 chip outputs back at the pin during the
  run, and the PC predicts each pin's behaviour from the steps alone (no hand-written
  expectations): all 22 + the `sipo_in` frame match, 100/100, for a sequence and for an editor
  mode. The window length matches the simulation to the tick, and a wrong expectation fails
  exactly the affected rows.
- Limits: it sees the pin at the FPGA, not after it (an open in the connector, HTG board, wire
  or chip socket is invisible), and only 0/1 at the input threshold (no analog level, no
  ringing: the scope's job). In `vchip_top` the readback is internal (no pads for the DFT
  outputs).
