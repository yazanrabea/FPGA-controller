# EXP-06: first oscilloscope timing measurements (clock, duty, pulse width, edges)

CLAUDE.md §7 item 2: nothing so far measured frequency, duty, pulse width or edges, only
multimeter averages and LEDs (EXP-01..05). This experiment measures them with the Keysight
scope on the verified loopback pairs, using `phase5_link_jtag_top`: its test clock and test
pulse are set from the PC over JTAG (EXP-02), so one bitstream covers every setting below
with no rebuild.

## 1. Setup

- **Design**: `phase5_link_jtag_top` (bitstream `build/phase5_link_jtag_top/...`, sources
  unchanged since it was built 2026-10-22; timing met, WNS +0.206 ns).
- **Board**: ZedBoard, **J18 on 1V8**, PROG micro-USB on J17, the EXP-01 jumpers
  (J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20), switches down.
- **PC side**: `nemo_ctl.jtag.open_jtag()` (one Python session per setting), from `tools/`.
- **Scope**: recorded at the run (§4). Input **1 MΩ** (CLAUDE.md §5: 50 Ω
  loads the pin and the level sags to ~0.7 V). Probe attenuation, probe model and ground
  connection are recorded at the run. A long ground lead adds ringing of its own, so use the
  shortest ground possible, e.g. the SMA jack shell next to the header.
- Every setting is an exact number of 10 ns ticks, so the expected values below are exact,
  up to the board's 100 MHz oscillator tolerance.

## 2. Settings and what to measure

| # | Cell (pin) | Setting (ticks) | Expected | Measure |
|---|---|---|---|---|
| A1 | test_clock (J3-0, driven end) | CLOCK, period 100, high 50 | 1.000 MHz, 50.0 %, 0 / 1.8 V | frequency, duty, Vmax, Vmin, rise and fall time (10-90 %), overshoot / ringing |
| A2 | same signal at J3-16 (far end of the jumper) | same | same | same; difference from A1 = the jumper wire |
| B1 | test_clock (J3-0) | CLOCK, period 10, high 5 | 10.00 MHz, 50 % (the tool's warning limit) | same as A1 |
| B2 | same at J3-16 | same | same | same |
| C | test_clock (J3-0) | CLOCK, period 1000, high 250 | 100.0 kHz, 25.0 % | frequency, duty |
| D | test_pulse (J3-1) | PULSE, width 100, repeat period 1000, 4,000,000,000 repeats (first set to 1,000,000 = only 10 s, too short to measure; changed before measuring) | 1.00 µs high every 10.0 µs (for ~11 h, then STOP) | positive pulse width, period |
| E | all five outputs J3-0..J3-4 at once, **digital channels** D0-D4 | A1's clock + D's pulse running, LOW/HIGH cells as configured | clock and pulse as above on D0/D1; D3 constant 0, D4 constant 1 (if the HIGH cell is set) | frequency / width on the digital channels, plus the relative timing of all five |

**Analog vs digital channels.** Rows A/B use the **analog channel** (CH1): only it shows the
true level, edge shape, overshoot and ringing. Rows C/D are measured on the analog channel
and repeated on the **digital channels** (logic cable, D0-D7; threshold set to **~0.9 V** =
half of 1.8 V, because the default logic threshold is meant for 3.3 V / 5 V logic). E needs
the digital channels: they show several pins at once, but only as 0/1. The logic cable's
ground lead goes to board ground too.

**Scope limit.** The MSO-X 2002A's analog bandwidth is 70 MHz (from the datasheet as
remembered; check the front label). Its own rise time is then ~0.35 / 70 MHz ≈ 5 ns, so a
measured rise or fall time near 5 ns is the scope's limit, not the pin's.

## 3. Procedure

1. Confirm the board setup (§1), program `phase5_link_jtag_top`
   (`scripts/program_board.tcl -tclargs phase5_link_jtag_top`).
2. Record the scope model, probe, attenuation, input impedance and ground connection.
3. For each row of §2: the PC configures the cell, APPLY, RUN; the person at the scope
   reads the measurements (the scope's automatic measurements are fine; say which). Record
   the reading exactly; a screenshot goes in `docs/measurements/` if possible.
4. STOP at the end.

## 4. Results — IN PROGRESS (2026-10-26, lab PC), [measured on board]

### Run record
- Rahaf at the bench, Claude on the lab PC. Board setup confirmed by Rahaf ("the board is
  good"): J18 1V8, the 5 jumpers, switches down, J17.
- Programmed `phase5_link_jtag_top` (`DONE=1`); test_clock set over JTAG to CLOCK
  period 100 / high 50 ticks (read back 100 / 50), APPLY, RUN.
- Instrument: first the Agilent MSO-X 2002A (only its V/div knob was set up). The readings
  below are from a **Keysight CX3324A** (the team switched instruments). Coupling: AC at
  first, then DC (see A1). **Ground: the shortest clip, connected to a ground point next to
  the measured pin** (Rahaf, reported after the run, applies to A1/A2). Probe/sensor model:
  not recorded.

### A1: test_clock 1 MHz, 50 %, on J3-0 (confirmed by Rahaf)

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Frequency | 1 MHz | 1.000 MHz | matches |
| Duty | 50 % | 50.0 % | matches |
| Amplitude | 1.8 V | 1.8 V swing (VADJ 1V8) | matches |
| Maximum | 1.3 V | ~1.8 V if DC-coupled | see below |
| Minimum | -1.3 V | ~0 V if DC-coupled | see below |
| Rise time | 17.8 ns | not specified (pin + jumper + probe/sensor + instrument bandwidth) | slower than a bare LVCMOS18 output would usually be; probe/sensor not yet known |
| Fall time | 17.0 ns | as above | as above |
| **Maximum, DC-coupled** | **2.2 V** | ~1.8 V | **+0.4 V overshoot** (~22 % of the swing) |
| **Minimum, DC-coupled** | **-0.4 V** | ~0 V | **-0.4 V undershoot** |

Max/min of +-1.3 V with a 1.8 V amplitude would fit an **AC-coupled** (centred) input:
+-0.9 V levels plus ~0.4 V of overshoot on each edge. Rahaf confirmed the channel **was
AC-coupled** and switched it to **DC** ("received what I need"); the max/min with DC
coupling: **max 2.2 V, min -0.4 V**, i.e. ~0.4 V of overshoot above 1.8 V and ~0.4 V of
undershoot below 0 V on the edges. That is the ringing CLAUDE.md §5 already noted for jumper
wires on a 1 MΩ input.

Cautions (not conclusions):
- Ground: the **shortest clip, next to the measured pin** (reported after the run). A long
  lead would have added ringing of its own; a short clip adds much less, so most of the
  ringing is likely on the pin itself. A ground spring on the probe tip (a few mm) would
  settle it fully. The probe/sensor model was not recorded, and the ringing zoom was not
  done.
- For the chip: -0.4 V below ground on a chip input may be outside its rating. The rating
  is unknown, so it is added to the open questions (chip datasheet / Dima). If it holds up
  with a short ground, the usual fixes are shorter wires or a series resistor at the driver.

### A2: test_clock 1 MHz, 50 %, on J3-16 (far end of the jumper, an FPGA input)

Same probe/ground and settings as A1 (DC coupling); only the probe tip moved.

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Frequency | 1 MHz | 1.000 MHz | matches |
| Duty | 50 % | 50.0 % | matches |
| Maximum | 2.42 V | ~1.8 V | +0.62 V overshoot |
| Minimum | -0.7 V | ~0 V | -0.7 V undershoot |
| Rise / fall | ~18 ns / ~18 ns | as A1 | same edge speed as the driving end |
| Amplitude | not read | 1.8 V | |

A1 vs A2: the far end (the wire's unterminated end at an FPGA input) rings more (+0.62 /
-0.7 V vs +0.4 / -0.4 V). The edges are equally fast. Interpretation, with the same
probe-ground caveat as A1.

### B1: test_clock 10 MHz, 50 % (period 10 / high 5 ticks, changed live), on J3-0

Same probe/ground, DC coupling, timebase 100 ns/div. At 50 ns/div the instrument showed no
duty value (Rahaf).

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Frequency | 10 MHz | 10.00 MHz | matches |
| Duty | 51 % | 50.0 % (exactly 5 / 10 ticks) | ~1 % off; with ~18 ns edges in a 50 ns half-period, where the 50 % crossing falls on a slow edge moves the measured duty. Interpretation |
| Maximum | 2.1 V | ~1.8 V | +0.3 V |
| Minimum | -0.4 V | ~0 V | -0.4 V |
| Amplitude | 2.45 V | 1.8 V | larger than the swing: the ringing doesn't settle before the next edge. Interpretation |
| Rise / fall | ~31 ns / ~28 ns | as A1 (~18 ns) | slower than at 1 MHz, although the FPGA's edge doesn't depend on frequency: 10-90 % is taken of an amplitude inflated by ringing (2.45 V). Interpretation; a direct look at one edge would confirm |

### B2: test_clock 10 MHz, 50 %, on J3-16

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Frequency | 10 MHz | 10.00 MHz | matches |
| Duty | 51 % | 50.0 % | as B1 |
| Maximum | ~2.3 V | ~1.8 V | +0.5 V |
| Minimum | -0.64 V | ~0 V | -0.64 V; the far end rings more, as at 1 MHz |
| Amplitude, rise / fall | not read | | |

### C: test_clock 100 kHz, 25 % (period 1000 / high 250 ticks), on J3-0

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Frequency | 100 kHz | 100.0 kHz | matches |
| Duty | 25 % | 25.0 % | matches. At this speed the ~18 ns edges are negligible, which fits the 51 % at 10 MHz being an edge effect |

### D: test_pulse, width 100 ticks every 1000 ticks, on J3-1

| Quantity | Reading (as reported) | Expected | Note |
|---|---|---|---|
| Positive width | 1 µs | 1.00 µs | matches |
| Period | 10 µs | 10.0 µs | matches |

### E: all five outputs at once, digital channels (MSO-X 2002A logic cable)

Settings at the time:
- J3-0: clock 100 kHz / 25 %;
- J3-1: pulse 1 µs every 10 µs;
- J3-2: test_serial, unconfigured, so LOW;
- J3-3: LOW;
- J3-4: HIGH, set for this row.

The clock and the pulse were restarted by the same APPLY on the same tick. Leads D0-D4 on
J3-0..J3-4. Threshold and ground lead as instructed (0.9 V, board ground), not separately
confirmed.

| Channel | Reading (as reported) | Expected | Pass |
|---|---|---|---|
| D0 / D1 rising edges | rise together | same tick, both cells restarted by one APPLY | PASS |
| D0 / D1 falling edges | don't fall together | D1 (pulse) falls at 1 µs, D0 (clock) at 2.5 µs | PASS |
| D2, D3 | at 0 | 0 | PASS |
| D4 | at 1 | 1 | PASS |

D0 high time and D1 width on the digital channels: not read (D measured the width on the
analog channel).

STOP from the PC at the end (`link stop --jtag`, STATUS `STOPPED`).

## 5. Conclusion

**Timing: PASS, 2026-10-26.** Every frequency, duty and width the FPGA was told to make came
out as set:
- 1 MHz and 100 kHz exactly; 10 MHz at 51 % instead of 50 % (an edge-measurement effect);
- 25 % duty;
- a 1.00 µs pulse every 10.0 µs;
- two cells started on the same tick rise together.

All settings were made from the PC over JTAG on one bitstream.

**Signal quality: the first real numbers, and an open issue.** On jumper wires, measured with
the CX3324A at 1 MΩ, DC coupling:

| | 1 MHz, J3-0 | 1 MHz, J3-16 | 10 MHz, J3-0 | 10 MHz, J3-16 |
|---|---|---|---|---|
| Max | 2.2 V | 2.42 V | 2.1 V | ~2.3 V |
| Min | -0.4 V | -0.7 V | -0.4 V | -0.64 V |
| Rise / fall | 17.8 / 17.0 ns | ~18 / ~18 ns | ~31 / ~28 ns | not read |

- Overshoot and undershoot of 0.4-0.7 V on a 1.8 V signal, worse at the wire's far end
  (an FPGA input, the unterminated end). Edges ~18 ns.
- At 10 MHz the signal doesn't settle between edges. The tool's 10 MHz warning limit is
  justified for jumper wiring.

**Caveats:**
- Ground was the shortest clip next to the measured pin, so the ringing is likely mostly
  real. It's not proven: a spring-tip ground would remove the last doubt, and the probe
  model was not recorded.
- The ringing zoom on one edge was not done.
- Amplitude was only read at 1 MHz J3-0 and 10 MHz J3-0.

**Open, before the chip is connected** (`docs/issues.md`):
1. Optional: repeat A1 / A2 with a ground spring on the probe tip and a recorded probe
   model (A1/A2 already used the shortest clip next to the pin).
2. Check the chip's input rating below ground (datasheet / Dima). -0.7 V undershoot may be
   outside it.
3. If the ringing is real: shorter wires, a series resistor at the driver, or a lower drive
   strength in the XDC (`DRIVE`, `SLEW SLOW`), and measure again.
