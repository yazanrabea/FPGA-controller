# EXP-08: the "virtual chip" (Dima's SIPO / PISO RTL in the FPGA, over jumper wires)

Chip pipeline step C6 (plan 2026-10-26, Rahaf). EXP-07 showed the controller drives the
chip's 22 inputs as configured, at the logic level. It could not show the other direction:
nothing drove the 4 controller inputs (J3-16, J2-17..19). This experiment puts a stand-in for
the chip's SIPO / PISO path, built from **Dima's unmodified RTL**, into the same bitstream on
separate pins, and connects it to the controller with jumper wires, the way the chip will
be connected. One sequence then sends a 136-bit frame PC → controller → wires → Dima's SIPO,
and reads 168 bits back from Dima's PISO → wires → controller → PC.

**Status: PLANNED, not run.** [simulated] `vchip_top_tb` 9/9 (xsim, 2026-10-26). Bitstream built 2026-10-26: timing met (WNS +0.183 ns), 0 critical warnings.

## 1. Design

- **Top**: `vchip_top` (`fpga/src/vchip_top.sv`) = `chip_top` (unchanged, same `chip_pkg`,
  same PC tools as EXP-07) + `virtual_chip` (`fpga/src/virtual_chip.sv`).
- **Virtual chip**: Dima's `sipo_wrapper` (+ its `sipo`), a second standalone `sipo` on the
  same inputs (to hand the 136-bit frame to the PISO; `sipo_wrapper` has no port for it),
  and 4 chained `piso2` (PISO0 read first), with the Tower cells stubbed
  (`fpga/tb/tower_cell_stubs.sv`). Its clocks and resets come straight from its pins, as on
  the chip.
- **What it sends back** (Rahaf's choice): PISO data = `{frame[135:0], sel[23:0], 8'hC6}`.
  C6 is a fixed tail that shows the read is aligned.
- **phirst** (Rahaf's choice): on its own pin, jumpered from the controller's `pulse`
  (J3-13). **Virtual chip only**: on the real chip phirst is made inside (Q4).
- **Pins**: the controller's 7 DFT outputs are not pinned in this top (pin budget); the
  virtual chip uses J2-20..J2-29. Generated: `fpga/src/gen/vchip_pkg.sv` +
  `fpga/constraints/vchip_top.xdc` (`gen_svh.py --vchip`, from `pin_map` +
  `config/exp08_vchip.yaml`). DRIVE 4 / SLEW SLOW on outputs, PULLDOWN on inputs.
- **Synthesis of Dima's RTL** (scratch out-of-context run, 2026-10-26): 0 errors, 0 critical
  warnings. `piso2`: 42 FDCE per stage. `sipo_wrapper`: its `sel[23:8]` load inside the
  async reset became **16 latches (LDC)** gated by `rst_n`. See §5, question 2.

## 2. Setup

- ZedBoard, **J18 on 1V8**, PROG micro-USB on **J17**.
- **Remove the logic-analyser clips** from EXP-07 (or move them, §4 optional).
- **10 jumper wires**, HTG-FMC headers, P column (also in the header of `vchip_top.xdc`):

  | # | Controller pin | | Virtual chip pin |
  |---|---|---|---|
  | 1 | J3-3 sipo_in | → | J2-20 sipo_in |
  | 2 | J3-4 clk_sipo | → | J2-21 clk_sipo |
  | 3 | J3-5 cs | → | J2-22 cs |
  | 4 | J3-6 rst_sipo | → | J2-23 rst_sipo |
  | 5 | J3-7 clk_piso | → | J2-24 clk_piso |
  | 6 | J3-8 shift | → | J2-25 shift |
  | 7 | J3-9 rst_piso | → | J2-26 rst_piso |
  | 8 | J3-13 pulse | → | J2-27 phirst |
  | 9 | J3-16 sipo_out | ← | J2-28 sipo_out |
  | 10 | J2-17 piso_out | ← | J2-29 piso_out |

  Nothing else on J2-18..J2-29: in this top J2-20..J2-27 are inputs and J2-28/29 outputs.
- Pins used here for the first time in this direction: J3-16 and J2-17 with a real signal;
  J2-20..J2-27 as inputs (J2-20 was an input in EXP-01); J2-28/29 as outputs.

## 3. Procedure

1. Person confirms §2 (J18, J17, the 10 jumpers, no clips).
2. Program: `vivado -mode batch -source scripts/program_board.tcl -tclargs vchip_top`.
3. From `tools/`:
   ```
   python -m nemo_ctl.cli seq load ../config/chip_sim_test.yaml --jtag
   python -m nemo_ctl.cli seq run --wait 5 --jtag --target chip_top
   python -m nemo_ctl.cli seq read piso_out --jtag --target chip_top
   python -m nemo_ctl.cli seq read sipo_out --jtag --target chip_top
   ```
4. Repeat 3 once (same result expected).
5. Optional: logic analyser on J2-20..J2-27 (what the virtual chip receives) and J2-28/29.

## 4. Expected (from `vchip_top_tb`, [simulated])

| Read | Expected |
|---|---|
| `seq run` | done, no FAULT; LD4 on, LD5 / LD7 off |
| `seq read piso_out` | capture **0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6** = frame `5AA5…E7E7` + sel `0000E7` + `C6` |
| `seq read sipo_out` | level 1 (= frame bit 0) |

`sel[23:8] = 0000`: it is only loaded while `rst_sipo` is low, and after power-up the frame is
0. `sel[7:0] = E7` = frame[7:0].

Fails and what they would mean: all 0 → `shift` or `clk_piso` jumper missing (the mutant run
in simulation gave all 0 with shift held low); the frame shifted by some bits → an edge /
timing problem on the wires; `C6` missing at the end → the read is misaligned.

## 5. Open questions this experiment can answer next (planned, need your OK)

1. **phirst**: a sequence that pulses `pulse` (= phirst) once after the load should give
   `sel[23:8] = frame[39:24] = F0C3` (index 24 → 40), so the tail `F0C3E7C6`. Needs a sequence
   file + simulation first.
2. **sel after a reset** (Dima Q1): in simulation of Dima's RTL, `sel[23:8]` after a
   `rst_sipo` pulse holds the previous frame's slice 0 (`C3E7`). Vivado built that load
   from latches gated by `rst_n`, which may give `0000` instead. A sequence with a
   `rst_sipo` pulse after a load would show which. Not a fault either way: it shows that
   Dima's RTL as written behaves differently in simulation and in hardware.

## 6. Results

Not run yet.
