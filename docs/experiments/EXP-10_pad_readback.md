# EXP-10: pad readback of the 22 outputs (`cli verify` on the new `chip_top`)

Verification plan Step 2 (`docs/plan_2026-11-01_verification.md`, decided 2026-11-02). EXP-07
checked the 22 outputs once, by eye, on the logic analyser. This experiment checks that the
FPGA itself reads every output back at its pin and that `cli verify` judges them right.

**Status: PLANNED, not run.** [simulated] `chip_top_tb` 15/15, `readback_cell_tb` 10/10
(xsim, 2026-11-02); pytest `test_readback.py` 15 (the Python expectation = the RTL's numbers).
Not built yet.

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

## 3. Results
(to be filled in on the lab PC)

## 4. Conclusion
(to be filled in)
