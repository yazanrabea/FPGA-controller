# EXP-02: Phase 5 runtime link bring-up (change a setting from the PC, no re-synthesis)

Per `generic_controller_prompt.md` Phase 5's exit criterion: "I change a clock frequency
from the PC without re-synthesis and see it on the multimeter/scope." This experiment
has **not been run yet** — it needs Vivado (not available in the environment that
designed it), physical access to the ZedBoard, a USB-UART adapter, and a
multimeter/oscilloscope. Everything below through §3 is prepared and simulated; §4
(Results) is a template to fill in while actually running it.

## 1. Setup

- **Design**: `fpga/src/phase5_link_top.sv` (top), `fpga/constraints/phase5_link_top.xdc`.
  Depends on `fpga/src/uart_rx.sv`, `uart_tx.sv`, `link_ctrl.sv`, `run_ctrl.sv`,
  `sig_cell.sv`, `cap_cell.sv` (same generic cells Phase 4 uses).
- **Board**: ZedBoard, VADJ jumper (J18) on **1.8 V** (CLAUDE.md §4 — check before powering
  up; this governs the FMC bank the 5 loopback pairs use, not the UART adapter below).
- **Jumper wires**: same 5 loopback pairs as EXP-01 (`docs/experiments/EXP-01...md` §1's
  table) — J3-0↔J3-16, J3-1↔J2-17, J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20.
- **USB-UART adapter**: **BLOCKED — not yet possible.** Which PMOD header and whether its
  bank is 3.3 V or VADJ (1.8 V) has never been confirmed against the ZedBoard reference
  manual (`docs/controller_spec.md` §9, carried forward unresolved since Phase 0).
  `rxd`/`txd` are deliberately unconstrained in the XDC until this is checked — **do not
  wire anything or invent a pin assignment.** This is the actual blocker on running this
  experiment at all; confirm the pin + voltage first, update
  `fpga/constraints/phase5_link_top.xdc` with `PACKAGE_PIN`/`IOSTANDARD` for `rxd`/`txd`,
  update this section with what was found, *then* continue.
- **Switches**: `sw[2:0]` = which pair's status shows on the LEDs (0-4, same order as
  Phase 4: CLOCK/PULSE/SERIAL/LOW/HIGH). No RUN switch this phase — RUN/STOP are
  exclusively link-controlled (`link run`/`link stop`), that's the point of Phase 5. No
  reset button — same power-on counter as every other bring-up design generates `rst_n`.
- **LEDs**: LD0 = driven output (selected pair), LD1 = captured input, LD2 = live match
  (sticky "last capture matched" for the SERIAL pair), LD3 = sticky fault latch, LD4 =
  RUN status, LD5 = sticky UART frame-error indicator (debug aid — should stay off; if it
  lights, something is garbling bytes: check baud rate and wiring first).
- **PC side**: `pip3 install -r tools/requirements.txt` (pulls in `pyserial`), a terminal,
  `tools/nemo_ctl/link.py` / `nemo_ctl.cli link ...` (see `docs/USER_MANUAL.md` §6).
- **Instruments**: Fluke 115 multimeter; Keysight oscilloscope if available.

## 2. What's already done (not part of this experiment's result)

- RTL + Python **[simulated]**: `scripts/run_phase5_link_sim.sh` runs `uart_tb` (12
  checks, TX/RX loopback + frame-error detection), `link_ctrl_tb` (22 checks, byte-level
  frame parsing/register file/all 8 commands/NACK on bad checksum or unknown CMD), and
  `phase5_link_top_tb` (7 checks, **real bit-serial UART timing end to end**, including
  this exact exit criterion: configure `test_clock` to a 20-tick period, RUN, measure the
  period on the loopback pin, then — while still RUNning, no STOP — write a new 40-tick
  period and APPLY again, and confirm the pin's measured period actually changed from 20
  to 40 ticks). All currently pass.
- `tools/nemo_ctl/link.py`'s unit tests (`tools/nemo_ctl/tests/test_link.py`, 27 checks,
  part of the repo's 99-test `pytest` suite) exercise the same frame encode/decode and
  the `Link` class's command methods against an in-memory model of `link_ctrl.sv`'s
  parsing rules — not real hardware, but real exercise of the Python side's protocol
  logic (checksum, address math, NACK handling, timeouts).
- One real protocol detail worth remembering while debugging on hardware: a `READ_REG`/
  `READ_CAPTURE` **request** frame still carries `LEN` dummy payload bytes (included in
  the checksum) even though their content is ignored — `link_ctrl.sv`'s parser doesn't
  special-case `CMD` when deciding whether to expect a data phase. `link.py` already
  handles this; a hand-built request that omits those bytes will get a checksum
  mismatch -> NACK.

## 3. Procedure (to run on hardware)

1. Confirm the UART adapter's PMOD header + bank voltage (§1) and update the XDC. **Do
   not proceed past this step without a confirmed answer.**
2. `vivado -mode batch -source scripts/create_project.tcl -tclargs phase5_link_top`, open
   the project, synthesize + implement, generate the bitstream, program the board.
3. Confirm VADJ (J18) is on 1.8 V. Wire the 5 loopback jumpers per §1.
4. Connect the USB-UART adapter to the PC; note the serial device name
   (`/dev/tty.usbserial-...`, `/dev/ttyUSB0`, or `COM...`).
5. **Echo / basic link check**: `python3 -m nemo_ctl.cli link status --port <PORT>` —
   expect `STOPPED` printed (not a timeout/exception). This alone proves the UART link is
   alive in both directions before testing anything else.
6. **Register write/readback**: `link set-clock --port <PORT> --cell test_clock --freq 1kHz`
   (don't pass `--apply` yet), then independently read it back — e.g. via a short Python
   snippet using `Link.read_reg(link.SIG_BASE + 5, 4)` — and confirm the raw bytes match
   the period `quantize_clock("1kHz")` would compute (`100_000` ticks at 100 MHz... but
   see the sw override below if that's inconveniently slow on a multimeter — adjust
   `--freq` to taste, 100 Hz-ish is easiest to read, same as EXP-01's pair 0).
7. **Full config + RUN**: `link apply`, `link run`, confirm LD4 lights, then multimeter
   (or scope) on the test_clock loopback pin (J3-0/J3-16) same as EXP-01's pair 0 —
   expect the DC average matching the configured duty cycle (e.g. ~0.9 V for 50% duty on
   a 1.8 V swing, same math as EXP-01).
8. **The actual exit criterion — change frequency live**: with RUN still active and
   *without* `link stop`, run `link set-clock --port <PORT> --cell test_clock --freq <NEW> --apply`
   with a different frequency, and re-measure the same pin. The reading must change to
   match the new frequency, with no re-synthesis, no reprogram, and the RUN LED (LD4)
   staying on the whole time.
9. **STOP**: `link stop`, confirm LD4 turns off and the pin idles.
10. Record every reading in §4 below, tagged **[measured on board]**. Record any UART
    frame errors (LD5) or NACKs encountered, even if eventually resolved, in
    `docs/issues.md` per CLAUDE.md §9.

## 4. Results — PENDING, not yet run

| Step | Expected | Measured | Instrument | Pass/Fail |
|---|---|---|---|---|
| UART adapter pin + voltage confirmed | PACKAGE_PIN/IOSTANDARD added to the XDC | — | — | — |
| `link status` (before RUN) | `STOPPED`, no timeout | — | — | — |
| Register readback matches what was written | raw bytes == requested ticks | — | — | — |
| test_clock running at the first configured frequency | DC avg matches configured duty | — | — | — |
| **Frequency changed live (no STOP, no re-synthesis)** | new DC avg / new period on scope, RUN LED never dropped | — | — | — |
| `link stop` | LD4 off, pin idle | — | — | — |
| UART frame-error LED (LD5) | stays off throughout | — | — | — |

**No row above may be filled in without an actual reading taken on real hardware.** Do
not mark PASS/FAIL from simulation or from what "should" happen — that's §2/§3, not this
table.

## 5. Conclusion

Not yet reached — depends on §4. If the "frequency changed live" row passes, Phase 5's
own exit criterion is met and Phase 5 can be marked done per `docs/USER_MANUAL.md`'s
standing rule (manual section written **and** followed successfully).
