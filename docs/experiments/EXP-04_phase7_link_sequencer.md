# EXP-04: Phase 7 round 2, step sequence loaded and run over the UART link

Per `generic_controller_prompt.md` Phase 7, exit "[simulated], then [measured on board]
with loopback", plus the program-verify loop driven from Python. Same sequence and
jumpers as EXP-03, but the table arrives from the PC (`python -m nemo_ctl.cli seq ...`)
instead of being compiled in. **Not run yet, and blocked**: the USB-UART adapter's PMOD
pin and bank voltage have never been confirmed (EXP-02, `docs/controller_spec.md` §9), so
`phase7_link_top.xdc` leaves `rxd`/`txd` unconstrained. §1–§3 are prepared and
simulated; §5 is filled in only with real readings.

## 1. Setup

- **Design**: `fpga/src/phase7_link_top.sv` + `fpga/constraints/phase7_link_top.xdc`.
  Uses `link_frame.sv`, `uart_rx.sv`, `uart_tx.sv`, `seq_bank.sv`, `seq_engine.sv`,
  `sig_cell.sv`, `cap_cell.sv` and the generated `fpga/src/gen/phase7_link_pkg.sv`
  (`cd tools && python -m nemo_ctl.gen_svh --phase7-link`; `scripts/run_phase7_sim.sh`
  also regenerates it).
- **Before building**: add `rxd`/`txd` `PACKAGE_PIN` + `IOSTANDARD` lines to
  `phase7_link_top.xdc` **only after** the PMOD pin and its bank voltage are checked in
  the ZedBoard reference manual (and recorded in `docs/controller_spec.md` §9 and
  `docs/decisions.md`). Do not guess.
- **Board**: ZedBoard, VADJ jumper J18 on **1.8 V**.
- **Jumpers**: the same 5 as EXP-01/EXP-03 (J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18,
  J3-3↔J2-19, J3-4↔J2-20, P column). PULLDOWN on LA16–20_P, as in EXP-03.
- **PC**: USB-UART adapter on the confirmed PMOD pins, 115200 baud 8N1; `pyserial`
  installed (`pip install -r tools/requirements.txt`).
- **LEDs**: LD0–LD2 step (current while running, last afterwards), LD3 busy, LD4 done,
  LD5 FAULT, LD6 LATE, LD7 link error (UART framing error or FIFO overflow).

## 2. What's already done (not this experiment's result)

- **[simulated, Icarus 12]** `scripts/run_phase7_sim.sh` → `phase7_link_top_tb` 21/21:
  a mock PC over real bit-serial UART (2 Mbaud in simulation) loads the ×1e-4 demo
  table, APPLY puts the pins at step 0, RUN gives exact step lengths and rst/clk on the
  pins, STATUS = done + late (from `confirm`), `data_in` reads 0xA5 over the link, a
  write while running is refused, a pulled jumper FAULTs at step 4, STOP aborts at step 2.
- **[not hardware]** pytest: `SeqLink`, `cli seq` and `program_verify` against a
  frame-level fake of the v2 map.
- Not done: Vivado build of this top, xsim.

## 3. Expected sequence

Same 6 steps as EXP-03 §2 (`config/phase7_seq_loopback.yaml`, ≈6 s). One difference:
step 5 starts ~0.4 µs late, because `confirm` ends after 30 ns and the next step must be
copied out of RAM first. So STATUS ends `done late` and LD6 is on. That's expected, not a
failure.

## 4. Procedure

1. Lab PC: `SIM=xsim scripts/run_phase7_sim.sh` (all four testbenches pass). Confirm the
   UART pin (step above), add it to the XDC, then build:
   `vivado -mode batch -source scripts/create_project.tcl -tclargs phase7_link_top build`.
   Record timing/utilization in §5 (a report, not a measurement).
2. VADJ on 1.8 V, the 5 jumpers, adapter wired. Program:
   `vivado -mode batch -source scripts/program_board.tcl -tclargs phase7_link_top`.
   Note the adapter's port name (e.g. `COM5`).
3. From `tools/`: `python -m nemo_ctl.cli seq status --port COM5` → `STATUS: idle; ...`
   (the link works). LD7 off.
4. `python -m nemo_ctl.cli seq load ../config/phase7_seq_loopback.yaml --port COM5`.
   Multimeter: J3-1 (`rst`) ≈1.8 V, J3-0/2/3/4 ≈0 V (step 0 applied).
5. **Run 1**: `python -m nemo_ctl.cli seq run --wait 15 --port COM5`. Expect LEDs step
   0,1,2,3,5 over ≈6 s, then `STATUS: done late; step 0, last step 5`, LD4 + LD6 on. Scope
   (if available) as in EXP-03 Run 1. Then `seq read data_in` → `capture 0xA5`.
6. **Run 2 (fault)**: pull J2-20, `seq run --wait 15` → `STATUS: fault ...; last step 4`,
   exit code 1, LD5 on. Put the jumper back.
7. **Run 3 (abort)**: `seq run` (no wait), then during step 2 (LEDs 010) `seq stop` →
   `seq status` shows `aborted`, last step 2; J3-0 ≈0 V.
8. **Run 4 (change without re-synthesis)**: edit `config/phase7_seq_loopback.yaml` (e.g.
   `load`'s `data` to `"0x3C"` and `expect` to match), `seq load`, `seq run --wait 15`,
   `seq read data_in` → `capture 0x3C`. This is the point of round 2.
9. **Run 5 (program-verify, optional)**: a short Python script calling
   `program_verify(SeqLink(...), build, "data_in", check, max_iters)` with a `build(i)` that
   changes the SERIAL data each iteration. Record iterations and history.
10. Record everything in §5, tagged [measured on board]. Disagreements go to
    `docs/issues.md` as symptoms, not guessed causes.

## 5. Results — PENDING, not yet run (blocked on EXP-02's UART pin)

| Check | Expected | Measured | Instrument | Pass/Fail |
|---|---|---|---|---|
| UART pin + bank voltage confirmed | from the ZedBoard reference manual | — | manual | — |
| Build | timing met, no critical warnings | — | Vivado report | — |
| `seq status` before load | `idle`, LD7 off | — | PC | — |
| After `seq load`: J3-1 / others | ≈1.8 V / ≈0 V | — | multimeter | — |
| Run 1 status | `done late`, last step 5 | — | PC | — |
| Run 1 `data_in` | `0xA5` | — | PC | — |
| Run 2 (J2-20 pulled) | `fault`, last step 4, LD5 | — | PC, eyes | — |
| Run 3 (stop in step 2) | `aborted`, last step 2, J3-0 ≈0 V | — | PC, multimeter | — |
| Run 4 (new data, no rebuild) | `data_in` = the new value | — | PC | — |

**Fill a row only with an actual reading from the board.**

## 6. Conclusion

Not yet reached. Depends on §5.
