# Task: Generic, user-configurable signal controller for the NEMO / Y-Flash chip

Read `CLAUDE.md` and `docs/WORKLOG.md` first and follow all their rules (documentation,
branches, testbenches, XDC, 2-FF synchronizers on every chip output, registered outputs,
Vivado 2022.1, ZedBoard XC7Z020, FMC LVCMOS18 with VADJ on 1V8). Never invent pins,
voltages or chip behavior: anything not in the files is TBD and goes in the open
questions. Work strictly in phases. At the end of each phase: stop, summarize what was
done, how it was tested (tag **[simulated]** / **[measured on board]**), what you assumed
and could not verify, and **wait for my approval** before starting the next phase.

Locate the input files yourself; do not trust the paths below. If a file is missing or
the name differs, search the repo and tell me what you used. Sources: the Blocks workbook
(sheet "Blocks Interface - Digital"), the newest pinout workbook (`IO_pinout2.xlsx`,
sheet "IO-Pins-Dima", whose pad ring now uses package pin numbers 1 to 68), the session1
explainer (README or PDF), and `fpga/reference/dima_blocks/` (sipo.sv, sipo_wrapper.sv,
piso.sv).

## 1. Goal

Replace the hard-coded bring-up designs with ONE controller in which the user decides,
without editing HDL, what every digital chip input does in each Y-Flash mode.

- **Modes (profiles):** READ, WRITE, INFERENCE. Keep the mode list in data so WRITE can
  later be split into PROGRAM / ERASE.
- For each mode -> each chip block -> each input pin of that block, the user picks:
  1. **LOW** - constant 0
  2. **HIGH** - constant 1
  3. **PULSE** - width (required); optional start delay, polarity, repeat count + period
  4. **CLOCK** - frequency (required); optional duty, start delay, cycle count (0 = free-running)

  Extra types required by the real chip:

  5. **SERIAL** - bit pattern (hex string or file) shifted out one bit per edge of a
     referenced CLOCK pin, MSB or LSB first, data changing on a configurable edge
     (needed for `sipo_in`)
  6. **CAPTURE** - for chip outputs: level, edge count, frequency/duty measurement, or
     N-bit serial capture on edges of a referenced clock pin
  7. **BUS value** - a group of pins treated as one number (for example `b0..b2_dft`,
     `s0..s3_dft`, `s0_p..s2_p`), so the user can type a value instead of three LOW/HIGH picks

- **Per-pin safe limits** in the config: minimum pulse width, maximum frequency, allowed
  types, idle level, polarity. The validator rejects anything outside them.
- **Analog biases and supplies** (`v_read`, `v_write`, `v_erase`, `vth`, `vcch_*`,
  `bl_vdc`, `tdc_vb`, `vtc_vb`, `delta_vb`, `lvr_*`, `pad`) are NOT driven by the FPGA.
  List them in the docs as external supplies and keep them out of the generators.

- **Blocks and pins** (blue rows of the sheet), grouped by the "block" column:

  | Block | Inputs (FPGA drives) | Outputs (FPGA reads) |
  |---|---|---|
  | DFT - All | b0_dft, b1_dft, b2_dft | dft0_buff, dft1_buff |
  | dft per ADC | s0_dft, s1_dft, s2_dft, s3_dft | |
  | DSA | rst_dsa | |
  | Array with Muxes | s0_p, s1_p, s2_p, pulse | |
  | Clock Generator | clk, reset, set | |
  | SIPO | sipo_in, clk_sipo, cs, rst_sipo | sipo_out |
  | PISO | clk_piso, shift, rst_piso | piso_out |

  Cross-check the table against the pinout workbook and the session1 explainer (expected:
  22 inputs + 4 outputs). Report every disagreement; never silently pick one. Known ones
  to confirm: `rst_sipo` is on pad 39 of the pad ring but pin 39 is "Unused" in the
  digital sheet; an unnumbered `PISO_WR` row sits between pins 22 and 23 of that sheet;
  the sheet `Pinout_Dima (2)` looks like an old draft, so treat "IO-Pins-Dima" as the
  source of truth.

- **DFT helper** (convenience layer; raw bit control must stay possible):
  "DFT - All" is an 8:1 mux of pairs; `b2..b0` choose which "dft per ADC" pair reaches
  `dft0_buff`/`dft1_buff` (000 selects the first pair, a / a1, and so on). Schematic
  inputs: a=dft13, a1=dft03; b=dft12/dft02; c=dft11/dft01; d=dft10/dft00; e=dft17/dft07;
  f=dft16/dft06; g=dft15/dft05; h=dft14/dft04. Inside each "dft per ADC", `s0..s3_dft`
  choose among d0..d7 = phirst, phi1, phi2, vtc_out_dft (repeated on d4..d7). Let the user
  pick "ADC k, signal X" and compute the bits from a lookup table in the config. Mark the
  table **UNCONFIRMED** (bit order, which letter is which select code, which s-code gives
  which signal on dft_0 vs dft_1) until Dima confirms.

## 2. Architecture (implement this; if you find a concrete reason to deviate, explain first)

```
PC:   config file (source of truth) -> Python tool (validate, quantize, wizard) -> link
FPGA: link RX -> shadow registers -> atomic APPLY -> active registers
      -> one generic cell per chip pin, sharing one timebase and one global RUN/STOP
      -> output FF (IOB=TRUE) -> FMC LA_P pins.
      Chip outputs -> 2-FF sync -> capture cells -> status registers -> back to PC.
```

Rules:

- One 100 MHz timebase; every parameter is stored as integer ticks (10 ns).
  CLOCK = period N ticks (N >= 2) + high time H ticks. The tool converts the user's
  Hz / ns / us / ms to ticks and ALWAYS shows the achieved value and error
  (e.g. 3 MHz -> N=33 -> 3.0303 MHz, +1.0 %). Warn above 10 MHz (jumper-wire signal
  integrity, see `docs/issues.md`); hard limit 50 MHz.
- **Atomic apply:** new settings are written to shadow registers and take effect on one
  clock cycle, on an explicit APPLY command, so a half-changed config never reaches the chip.
- All cells start on the same tick at RUN; start delays define relative timing between pins.
- Every output comes straight from a flip-flop. `cs`, `clk`, `clk_sipo`, `clk_piso` must
  be glitch-free (never combinational).
- On reset / STOP / link loss every output returns to its configured idle level. Polarity
  and idle level are per-pin config fields (reset pins may be active-low; unknown until
  Dima answers), never hard-coded.
- Chip-pin -> FMC LA_P mapping is a table in the config, not in HDL, keyed by the pad
  numbers of the newest pinout workbook. Use only the verified LA_P pins; XDC must match
  the table. Mark any pad without a verified FMC pin as TBD.
- phi1 / phi2 / phirst are generated **on the chip** by the Clock Generator from
  clk/reset/set. Do NOT build a non-overlapping-phase generator in the FPGA unless the
  explainer's open question on it is answered otherwise. Flag the matching CLAUDE.md
  item accordingly.
- Parameters, not constants: `SIPO_BITS=136`, `PISO_BITS=168`, `MSB_FIRST`, cell count,
  active edges.

Example config shape (adapt in phase 0):

```yaml
modes:
  INFERENCE:
    Clock Generator:
      clk:   {type: CLOCK, freq: 1MHz, duty: 50%}
      reset: {type: PULSE, width: 1us, delay: 0, polarity: active_low}
      set:   {type: LOW}
    SIPO:
      clk_sipo: {type: CLOCK, freq: 1MHz, cycles: 136, delay: 2us}
      sipo_in:  {type: SERIAL, clock: clk_sipo, data: frame0.hex, msb_first: true}
      cs:       {type: PULSE, width: 1us, delay: 140us}
    DFT - All:
      dft_select: {adc: 3, signal: phi1}   # helper -> b0..b2, s0..s3
      # raw alternative: b_dft: {type: BUS, value: 0b011}
```

## 3. Phases

### Phase 0 - Spec (no code)
Deliver `docs/controller_spec.md`: pin table (pin, pad number, block, direction, allowed
types, safe limits, idle level, polarity, FMC LA pin or TBD, notes); config schema; FPGA
register map; link protocol draft; resource estimate; the list of disagreements between
the sheets; open questions. Compare link options and recommend one:
- (a) USB-UART adapter on a PMOD (pure RTL; check the PMOD bank voltage in the ZedBoard manual)
- (b) Zynq PS + AXI-Lite (on-board USB-UART is wired to the PS; needs block design + Vitis)
- (c) Vivado VIO over JTAG (debug only)

**Exit:** I approve the spec and choose the link.

### Phase 1 - Config format + Python core (no hardware)
`config/nemo_config.yaml` (source of truth, in git) + Excel import/export (one sheet per
mode, same columns, generated template). Package `tools/nemo_ctl`: load, validate
(allowed types per pin, safe limits, SERIAL must reference a CLOCK pin, no pin used twice),
quantize to ticks, per-mode timing summary, waveform preview (matplotlib or WaveDrom
JSON). Pin database generated from the workbook. pytest unit tests.

**Exit:** tests pass; the example INFERENCE preview looks right.

### Phase 2 - Interactive wizard (CLI)
Flow: pick mode -> each block -> each input pin: show the current setting and a menu:

1. 0
2. 1
3. pulse -> width (+ optional delay)
4. clock -> frequency (+ optional duty, cycles, delay)
5. serial
6. bus value (for grouped pins)
7. keep / skip

Accept units (ns, us, ms, Hz, kHz, MHz). Show the achieved value immediately. Options:
copy a block from another mode, reset a block to defaults, DFT helper menu. It writes the
same config file, so the wizard, the YAML and the Excel sheet are three views of one format.
A GUI is optional and only after phase 5 works.

**Exit:** I build a full INFERENCE profile in the wizard and it round-trips through Excel.

### Phase 3 - RTL cells + testbenches
`fpga/src`: `sig_cell.sv` (LOW/HIGH/PULSE/CLOCK/SERIAL/BUS), `cap_cell.sv` (level, edge
count, period/high-time measurement, serial capture), `run_ctrl.sv` (timebase, RUN/STOP,
shadow registers and APPLY). Self-checking testbenches in `fpga/tb`: measured
period/width/delay/cycle count equal the requested ticks, including edge cases (N=2, odd
N, width=1 tick, delay=0, cycles=1, config change while running).

**Exit:** all testbenches pass [simulated]; utilization estimate for 26 cells.

### Phase 4 - Top level with compile-time config (no link yet)
Python generates `fpga/src/gen/nemo_cfg_pkg.svh` from the config; one top + its XDC;
RUN/STOP and mode select on switches, status on LEDs. Hardware test of every signal type
on the verified loopback pairs (internal check + multimeter with a slow clock + scope when
available).

**Exit:** [measured on board] results in `docs/experiments/EXP-<nn>_*.md`.

### Phase 5 - Runtime link
Implement the link chosen in phase 0. Simple framed protocol (cmd, addr, data, checksum):
WRITE_REG, READ_REG, LOAD_MODE, APPLY, RUN, STOP, STATUS, READ_CAPTURE. Python:
`nemo_ctl.link` with `send_config(mode)`, `apply()`, `run()`, `stop()`, `read_captures()`.
Test order: echo -> register write/readback -> full config.

**Exit:** I change a clock frequency from the PC without re-synthesis and see it on the
multimeter/scope.

### Phase 6 - SIPO / PISO against Dima's model
Express SIPO load (rst_sipo, 136 clk_sipo edges, one cs edge) and PISO read (load edge
with shift=0, read bit 1 before further clocks, 167 shifts, split 4 x [14+7+14+7]) as
profiles of the generic types. Data-change and sampling edges are config fields and
UNCONFIRMED until Dima answers. If the generic cells can't meet this timing cleanly,
propose dedicated engines instead. Testbench: our controller + `fpga/reference/dima_blocks`
(stub the Tower cells).

**Exit:** known frame in -> correct `sel[23:0]`; known results -> correct 168-bit decode
[simulated].

### Phase 7 - Mode sequencer
A mode becomes an ordered list of steps; each step = pin configuration + duration or "wait
until capture condition". Examples:
- INFERENCE = reset -> load SIPO -> clear DSA (rst_dsa) -> run the phi_R slices -> load
  and read PISO
- WRITE = select cell via SIPO -> set s*_p -> pulse; how v_write / v_erase are applied is
  external and TBD

Program-verify loop (pulse -> read -> compare -> repeat) driven from Python.

**Exit:** [simulated], then [measured on board] with loopback.

### Phase 8 - Chip-ready checklist (only after the open questions are answered)
Final pin map and levels, safe power-up order (FPGA outputs at idle before/while the chip
is powered; no back-powering), and a first-light test: read phi1/phi2 through the DFT mux
with `cap_cell` frequency measurement to verify the on-chip clock generator.

## 4. Open items to ask Dima (keep configurable, never hard-code)

- Active edge and polarity of `cs`, `shift` and all resets; minimum pulse widths; setup
  times against the last `clk_sipo` edge.
- Maximum safe `clk`, `clk_sipo`, `clk_piso` frequencies.
- Whether `rst_sipo` exists on the chip and between which frames it must be pulsed.
- What `pulse` does in each mode.
- When to load the PISO (after all 8 slices?) and what `tdc_out` shows at that moment.
- DFT lookup table (see section 1).

## 5. Every phase

- Branch `feature/<name>-<topic>`; small commits; docs updated in the same commit.
- Don't touch files my partner listed in WORKLOG "Currently working on".
- Anything unknown: mark it TBD in the config/spec and add it to the open questions.
  Don't guess.
