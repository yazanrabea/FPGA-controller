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

## 4. Results — 2026-10-22, run over **JTAG** (J17), not the UART: PASS [measured on board]

### Transport change (read this first)
The kit has no USB-UART adapter, so the PC link was moved to the J17 PROG cable
(`docs/decisions.md`; JTAG plan J1-J5). This run used:
- `phase5_link_jtag_top` (= `phase5_link_top` with `LINK("JTAG")`, same cells and
  register map), built and programmed with `scripts/create_project.tcl` /
  `scripts/program_board.tcl`;
- `python -m nemo_ctl.cli link ... --jtag` instead of `--port`.

Steps 1 and 4 (UART adapter) don't apply. The UART build (`phase5_link_top`) is still not
run on hardware, and its `rxd`/`txd` pins are still TBD.

### Setup
- Yazan at the board, Claude on the lab PC (Vivado 2022.1, xsdb).
- ZedBoard, J18 on **1V8**; the EXP-01 jumpers (J3-0↔J3-16 ... J3-4↔J2-20); switches all
  down (`sw[2:0]` = pair 0); PROG micro-USB on J17.
- Fluke 115 DC V, black probe on an SMA jack's shell.
- Programmed: `PROGRAMMED: xc7z020_1 with phase5_link_jtag_top.bit (DONE=1)`. Build report:
  timing met, sys clk WNS +0.206 ns (`docs/WORKLOG.md`, J3).

| Step | Command (from `tools/`) | Expected | Measured | Pass |
|---|---|---|---|---|
| 5. link alive | `cli link status --jtag` | `STOPPED`, no timeout | `STOPPED` | PASS |
| 6. write + read back | `cli link set-clock --jtag --cell test_clock --freq 100Hz --duty 50%` (no apply), then `Link.read_reg` | CTRL 03, PARAM_A 1,000,000, PARAM_B 500,000 | CTRL `03`, PARAM_A `40420f00` = 1,000,000, PARAM_B `20a10700` = 500,000, run = False | PASS |
| 7. APPLY + RUN | `cli link apply --jtag`, `cli link run --jtag`, `cli link status --jtag` | RUNNING; LD4 on; J3-0 ≈0.9 V | `RUNNING`; LD4 on; LD0/LD1/LD2 on, LD3 off; **J3-0 0.9 V** | PASS |
| **8a. duty changed live** | `cli link set-clock --jtag --cell test_clock --freq 100Hz --duty 25% --apply` (no STOP) | J3-0 ≈0.45 V, LD4 stays on | **J3-0 0.45 V**, LD4 stayed on | **PASS** |
| **8b. frequency changed live** | `cli link set-clock --jtag --cell test_clock --freq 1Hz --duty 50% --apply` (no STOP) | LD0/LD1 blink 1/s, LD4 on | LD0 and LD1 blink once per second, LD4 on | **PASS** |
| 9. STOP | `cli link stop --jtag`, `cli link status --jtag` | STOPPED, LD4 off, pin idle 0 V | `STOPPED`; LD4 off; blinking stopped; **J3-0 0 V** | PASS |
| link error LED (LD5) | | off throughout | off (reported at step 7) | PASS |

The multimeter shows the average, so the live change is measured as a duty change (0.9 V ->
0.45 V). The frequency change was checked by eye at 1 Hz. Frequency on a scope: not done
(no scope used).

Found during the run: `cli link set-clock` printed 1 Hz as `0.0000 MHz` (fixed format). It
was cosmetic, the ticks were right. Fixed (`_fmt_hz` in `tools/nemo_ctl/cli.py`, test in
`test_cli.py`).

## 5. Conclusion

**PASS, 2026-10-22, over the JTAG transport.** Phase 5's exit criterion is met on the board:
- a clock was configured, started, changed while running (duty: 0.9 V -> 0.45 V on the
  meter; frequency: 100 Hz -> 1 Hz, seen on the LEDs) and stopped, all from the PC;
- no re-synthesis or reprogramming in between;
- RUN never dropped.

This also proves the whole JTAG link (J1-J4) on hardware: PC -> xsdb -> J17 ->
`jtag_link_bridge` -> `link_frame` -> `link_ctrl`, and back. The reply magic parsed at
byte 0, which confirms the byte order J4 assumed.

Open: the UART variant on hardware (no adapter); frequency/duty on a scope.
