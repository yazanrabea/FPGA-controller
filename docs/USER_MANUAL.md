# NEMO generic controller — user manual

For a lab user who did **not** build this system and just wants to use it: configure a
mode, check it's safe, preview it, run it on hardware once that phase is ready. If you
want to understand *why* it's built this way, read `CLAUDE.md` and
`docs/controller_spec.md` instead — this manual only covers *how to operate it*.

> **Note on this manual's structure.** The task brief this project follows
> (`generic_controller_prompt.md`) was going to gain a "4. User manual" section
> specifying exactly what this document must contain. That section was never actually
> delivered to me (after being asked for three times, what came back each time was a
> different existing file already in this repo) — so the structure below is my own
> judgment of what a lab user needs, not a given outline. Tell me what to reorganize once
> the real outline exists.

## 0. Status: what's actually usable right now

| Phase | What it covers | Status | You can do today |
|---|---|---|---|
| 0 | Spec: pin table, config schema, link choice | Done, approved | Read `docs/controller_spec.md` |
| 1 | Config file + Python core (load/validate/preview) | Done | §2 below |
| 2 | Interactive CLI wizard | Done | §3 below |
| 3 | RTL cells (`sig_cell`/`cap_cell`/`run_ctrl`) + testbenches | Done, **simulated only** | §4 below |
| 4 | Top-level design + compile-time config | RTL/software done, **hardware step not run** | §5 below (build + simulate now; wiring/measuring needs you) |
| 5 | Runtime link (framed UART protocol, register file, Python client + CLI) | RTL/software done, **simulated only, hardware step not run** | §6 below (talk to it once §5's board is actually built and wired; the link itself needs its own build/wiring too, see §6.1) |
| 6 | SIPO load / PISO read as profiles of the generic cells, against Dima's RTL | Python + RTL done, **simulated only (Icarus 12)**; xsim run against Dima's unmodified `sipo_wrapper.sv` not done; no hardware step yet (no chip-pin map) | §7 below |
| 7 | Mode sequencer: a mode as an ordered list of steps, run by an FPGA step engine | Engine + loopback bring-up top done, **simulated only (Icarus 12)**; hardware run EXP-03 not done; link v2 (step table over UART, 136/168-bit frames) not started | §8 below |
| 8 | Chip-ready checklist | Not started | — |

Nothing past Phase 7 exists yet. Phase 6 is simulation-only by nature until the chip-pin ->
FMC map exists; Phase 7's bring-up top can be run on the board now (EXP-03). Phases 4 **and** 5 are **not complete** by this project's
own rule ("a phase is not done until ... I have followed it successfully myself") — the
RTL and simulations are ready for both, but nobody has actually built either in Vivado and
measured it on the ZedBoard yet. `docs/experiments/EXP-01_phase4_generic_controller_bringup.md`
and `docs/experiments/EXP-02_phase5_link_bringup.md` have the exact procedures.

## 1. Setup (one time)

From the repo root:

```
pip3 install -r tools/requirements.txt
```

That gets you `openpyxl`, `pyyaml`, `pytest` — enough for everything in §2-§3. All
commands below are run as a Python module, from inside `tools/`, not from the repo root:

```
cd tools
python3 -m nemo_ctl.cli --help
```

(Running a script under `tools/nemo_ctl/` directly by path, e.g.
`python3 tools/nemo_ctl/gen_pin_db.py` from the repo root, also works for the two
generator scripts specifically — but the `cli.py` commands in this manual need `-m` from
inside `tools/`, since they use Python's package-relative imports.)

For §4 (RTL simulation) you additionally need **Icarus Verilog** (`iverilog`/`vvp`) and,
optionally, **yosys** for a resource estimate. Neither is Vivado and neither programs a
board — they're free, local tools used only to catch RTL bugs before anyone touches real
hardware. On macOS:

```
brew install icarus-verilog yosys
```

**On the Windows lab PC** nothing extra is needed: the `scripts/run_phase*.sh` scripts
fall back to **Vivado 2022.1's own simulator (xsim)** at `C:\Xilinx\Vivado\2022.1` when
Icarus isn't installed (`scripts/sim_lib.sh` picks the tool; force one with `SIM=icarus`
or `SIM=xsim`). Run them from **Git Bash**, and use `python` instead of `python3` there
(on that PC `python3` is only the Windows Store stub). yosys isn't installed on the lab
PC, so the Phase 3 script skips the utilization estimate.

**On a Windows laptop without Vivado**, install Icarus Verilog with
`winget install Icarus.Verilog` (it goes to `C:\iverilog\bin`, which the scripts find even
if it's not on `PATH`). That's Icarus **12**, older than the macOS one: it can't elaborate
`fpga/tb/uart_tb.sv` (Phase 5), and Phase 6 runs need a stand-in for one of Dima's files
(§7.4). If you have two Pythons and only one has the packages, the scripts use the one
that can `import yaml`.

If you're on an Intel Mac with both an Intel and an Apple-silicon Homebrew installed and
the Intel one's compiler is broken, use `/opt/homebrew/bin/brew` explicitly (see
`CLAUDE.md` §4).

For §5 (hardware) you need Vivado 2022.1, a ZedBoard, the HTG-FMC-SMA-LVDS daughter
board, jumper wires, and (for measuring) a multimeter and ideally an oscilloscope.

For §6 (the runtime link) you additionally need `pyserial` (already in
`tools/requirements.txt`, so step 1 above covers it) and, on hardware, a USB-UART
adapter wired to the board — see §6.1 for what's still unconfirmed about that wiring.

## 2. Phase 1 — working with the config file directly

`config/nemo_config.yaml` is the source of truth: one YAML file describing, per mode
(`READ`/`WRITE`/`INFERENCE`), per chip block, what every input pin does. You can hand-edit
it, generate it with the wizard (§3), or round-trip it through Excel.

### 2.1 Validate a config

```
python3 -m nemo_ctl.cli validate --config ../config/nemo_config.yaml
```

Prints every issue found, one per line, `[ERROR]` or `[WARNING]`:

- `[ERROR]` means something is actually wrong — a type that pin doesn't allow, a
  frequency over the 50 MHz hard limit, a pin configured twice, a `SERIAL` setting
  referencing a clock that isn't configured. Fix these before using the config.
- `[WARNING]` means something is unconfirmed, not wrong — most commonly "this pin's max
  safe frequency is TBD (chip-side limit unknown)" or a DFT-helper pick (marked
  UNCONFIRMED pending Dima's answer, see `docs/controller_spec.md` §4). Warnings are
  expected and safe to proceed past; nothing in this project claims the chip-side
  unknowns are resolved.

No output at all means no issues of either kind.

### 2.2 Preview timing

```
python3 -m nemo_ctl.cli preview --mode INFERENCE --format table --config ../config/nemo_config.yaml
```

Prints a markdown table: every configured pin, its type, its start delay, and — for
clocks and pulses — the *achieved* value and error against what you asked for (e.g. a
3 MHz request becomes "achieved 3.0303 MHz, +1.0%" because of tick quantization; see
`docs/controller_spec.md` §2 for why). Use `--format wavedrom` instead to get a WaveDrom
JSON waveform diagram (paste it into a WaveDrom-compatible viewer to see the picture).

### 2.3 Move a config to/from Excel

```
python3 -m nemo_ctl.cli export-excel --config ../config/nemo_config.yaml --out my_config.xlsx
python3 -m nemo_ctl.cli import-excel --excel my_config.xlsx --config ../config/nemo_config.yaml
```

One sheet per mode, same columns either way — edit in Excel if that's easier than YAML,
then import it back. `gen-template` gives you a blank sheet to start from instead of an
existing config:

```
python3 -m nemo_ctl.cli gen-template --out blank_template.xlsx --modes INFERENCE
```

One row per input pin, grouped by block, `Type` column left blank for you to fill in.

## 3. Phase 2 — the interactive wizard

The wizard is the easiest way to build a mode: it walks every block, then every input pin
in that block, shows you the current setting, and offers a menu built from exactly the
types that pin is allowed to use (so you never see a nonsensical option like "pulse" on a
pin that only does `CLOCK`).

### 3.1 Running it

```
python3 -m nemo_ctl.cli wizard --mode INFERENCE --config ../config/nemo_config.yaml
```

**This overwrites the config file you point it at.** If you're trying it out for the
first time, work on a copy:

```
cp ../config/nemo_config.yaml /tmp/my_test.yaml
python3 -m nemo_ctl.cli wizard --mode INFERENCE --config /tmp/my_test.yaml
```

### 3.2 What you'll be asked, block by block

For every block, first:

```
Copy block 'Clock Generator' from another mode? Enter mode name, or blank to skip:
Reset block 'Clock Generator' to defaults (clear it)? [y/N]:
```

Answer blank + `n` to walk its pins one by one instead (the usual path). Then, for each
pin:

```
-- clk (Clock Generator) -- current: unset (idle)
   note: Drives on-chip phi1/phi2/phiR generation; max rate TBD (Q7).
    1. clock [clock]
    2. keep / skip (leave as-is) [keep]
  choice:
```

Type the number, the word in brackets, or an unambiguous prefix of it. `keep` always
works and leaves that pin untouched. Picking a real type asks follow-up questions:

| You picked | You'll be asked | Units accepted |
|---|---|---|
| `low` / `high` | nothing | — |
| `pulse` | width, then delay (blank=0), then polarity (blank=pin's default) | `ns`, `us`, `ms`, `s`, or a bare number of ticks |
| `clock` | frequency, then duty (blank=50%), then cycles (blank=free-running), then delay | `Hz`, `kHz`, `MHz`, or a bare number of Hz |
| `serial` | which clock pin it shifts on, the data (hex string or file path), bit count, MSB-first? (`Y`/`n`), which edge the data changes on | — |

Every clock/pulse answer is echoed back with the achieved value and error immediately,
e.g. `-> achieved 1.0000 MHz (N=100 ticks, high=50, +0.00%)` — that's the same
tick-quantization §2.2 shows in the preview, just inline as you type.

### 3.3 Grouped pins (buses) and the DFT helper

Some pins are walked once as a *group* instead of individually — e.g. `s0_p`, `s1_p`,
`s2_p` show up together as one prompt, because `tools/nemo_ctl/groups.py` treats them as
one 3-bit bus:

```
-- group s_p (s0_p, s1_p, s2_p) --
   current bus setting: unset (idle)
    1. set as one bus value [bus]
    2. set pins individually [individual]
    3. keep / skip (leave as-is) [keep]
```

`bus` lets you type one number (decimal, `0x..`, or `0b..`) instead of three separate
LOW/HIGH picks. `individual` falls back to the normal per-pin menu for each member pin if
you need raw control. The two DFT groups (`b_dft`, `s_dft`) additionally offer a `dft`
option: pick an ADC index (0-7) and a signal name instead of raw bits — this is the DFT
helper from `docs/controller_spec.md` §4, and it is explicitly **unconfirmed**
(pending Dima), so don't treat its bit pattern as chip-verified.

### 3.4 Finishing up

At the end it validates (same checks as §2.1, printed the same way) and saves. Add
`--excel out.xlsx` to the `wizard` command to also export an Excel copy once it's done.

## 4. Phase 3 — running the RTL simulations

Nothing here touches hardware. This is Icarus Verilog checking that `sig_cell.sv`,
`cap_cell.sv`, and `run_ctrl.sv` behave correctly — the same three building blocks the
Phase 4 top level (§5) is made of.

From the repo root:

```
scripts/run_phase3_sims.sh
```

Runs four self-checking testbenches (`sig_cell_tb`, `cap_cell_tb`, `run_ctrl_tb`,
`integration_tb`) and a yosys resource estimate. Each testbench ends with one of:

```
ALL TESTS PASSED (28 checks)
```
or
```
3 CHECK(S) FAILED out of 28
```

That line is the real answer — if you see `FAILED`, something is broken; don't trust a
"looks mostly fine" skim of the PASS/FAIL lines above it, read the actual count.

## 5. Phase 4 — the hardware bring-up top level

`phase4_loopback_top.sv` drives one `sig_cell`+`cap_cell` pair per signal type
(CLOCK/PULSE/SERIAL/LOW/HIGH) on FMC loopback pairs 0-4, so you can prove the generic
cells work on real hardware before any real chip pin is assigned.

### 5.1 Simulate it first (always do this before touching Vivado)

```
scripts/run_phase4_sim.sh
```

This also regenerates `fpga/src/gen/nemo_cfg_pkg.sv` from
`config/phase4_loopback_test.yaml` automatically. Expect `ALL TESTS PASSED (21 checks)`.

### 5.2 Build it in Vivado

```
vivado -mode batch -source scripts/create_project.tcl -tclargs phase4_loopback_top
```

Open `build/phase4_loopback_top/phase4_loopback_top.xpr`, run synthesis + implementation,
generate the bitstream, program the board. (If you only changed
`config/phase4_loopback_test.yaml`, re-run `cd tools && python3 -m nemo_ctl.gen_svh`
*first* — `create_project.tcl` picks up the regenerated file automatically, but only if
it exists before you run it.)

### 5.3 Wire it up and run it

**Full procedure, wiring diagram, and expected readings**:
`docs/experiments/EXP-01_phase4_generic_controller_bringup.md`. In short:

- VADJ jumper (J18) on the ZedBoard must be on **1.8 V** before you power anything.
- 5 jumper wires on the HTG-FMC-SMA-LVDS board, P column only: J3-0↔J3-16, J3-1↔J2-17,
  J3-2↔J2-18, J3-3↔J2-19, J3-4↔J2-20.
- `sw[4]` = RUN (hold high to run). `sw[2:0]` = which pair's status shows on the LEDs
  (0=CLOCK, 1=PULSE, 2=SERIAL, 3=LOW, 4=HIGH).
- LD0 = driven output, LD1 = captured input, LD2 = live match (or sticky "serial
  matched" for pair 2), LD3 = sticky fault latch, LD4 = RUN status.
- This is the step nobody has actually run yet. **Do not write a PASS/FAIL into EXP-01's
  results table without a real reading taken on real hardware.**

## 6. Phase 5 — the runtime link

Phase 4's `phase4_loopback_top` has compile-time-only config: every CLOCK/PULSE/SERIAL/
LOW/HIGH setting is baked in at synthesis time, so changing anything means re-running
Vivado. `phase5_link_top.sv` replaces that with the exact same 5 debug cells
(`test_clock`/`test_pulse`/`test_serial`/`test_low`/`test_high`), but every setting now
comes from the PC over a USB-UART link instead — a framed byte protocol
(`docs/link_register_map.md`) parsed by `fpga/src/link_ctrl.sv`, with a Python client
(`tools/nemo_ctl/link.py`) and matching `nemo_ctl.cli link` commands on this side.

**Scope note**: this is still only the same 5 fixed debug cells Phase 4 used, not the
full ~26-signal generic chip config from `docs/controller_spec.md`/`config/nemo_config.yaml`
— that per-pin RTL hasn't been built or wired to the link yet. `link set-clock` and the
`SigCellConfig`/`CapCellConfig` classes in `link.py` only know about those 5 names (see
`DEBUG_CELL_NAMES`).

### 6.1 Before you touch hardware

`rxd`/`txd` (the UART lines) are **deliberately left unconstrained** in
`fpga/constraints/phase5_link_top.xdc`. Which ZedBoard PMOD header carries a USB-UART
adapter, and whether that bank is 3.3 V or VADJ (1.8 V), was never confirmed back in
Phase 0 (`docs/controller_spec.md` §9) — building this in Vivado will warn about
unconstrained I/O until that's checked against the actual ZedBoard reference manual and
the XDC updated. **Do not invent a pin assignment or a voltage.** This is the main
blocker on actually running §6.2-§6.3 on real hardware; everything else (RTL, Python,
CLI) is ready and waiting on it.

### 6.2 Simulate it first

```
scripts/run_phase5_link_sim.sh
```

Runs three self-checking testbenches in order: `uart_tb` (TX/RX loopback, 12 checks),
`link_ctrl_tb` (frame parser + register file + command dispatch, byte-level, 22 checks),
and `phase5_link_top_tb` (the real thing, bit-serial UART timing end to end, 7 checks).
The last one models a mock
PC (its own `uart_tx`/`uart_rx` pair) talking real bit-serial UART frames to the DUT, not
just the byte-level shortcut `link_ctrl_tb.sv` uses — including the actual Phase 5 exit
criterion: configure `test_clock` to a 20-tick period, RUN it, measure the period on the
loopback pin, then — **while still RUNning, no STOP** — write a new 40-tick period and
APPLY again, and confirm the pin's period actually changed. All checks pass
**[simulated]**.

### 6.3 Talk to it from the PC

Once a board is programmed with `phase5_link_top` and wired per §6.1 (**not possible
yet** — see above), find the adapter's serial device name (e.g. `/dev/tty.usbserial-XXXX`
on macOS, `/dev/ttyUSB0` on Linux, `COM3` on Windows) and:

```
cd tools
python3 -m nemo_ctl.cli link status --port /dev/ttyUSB0
python3 -m nemo_ctl.cli link run --port /dev/ttyUSB0
python3 -m nemo_ctl.cli link set-clock --port /dev/ttyUSB0 --cell test_clock --freq 2kHz --apply
python3 -m nemo_ctl.cli link stop --port /dev/ttyUSB0
python3 -m nemo_ctl.cli link read-captures --port /dev/ttyUSB0
```

`set-clock` is the direct exercise of Phase 5's exit criterion ("change a clock
frequency from the PC without re-synthesis and see it on the multimeter/scope"): run
`link run` once, then run `link set-clock` again with a different `--freq --apply`
**without stopping first**, and watch the frequency actually change on the instrument.
`--freq`/`--duty` take the same units as the wizard (§3.2) and are quantized by the same
`quantize_clock()` — the achieved value and error are printed immediately, same as
everywhere else in this tool. Every `link` subcommand's `--help` has the full option
list; `--baud`/`--timeout` default to 115200/1.0s and rarely need changing.

For scripting instead of the CLI, `tools/nemo_ctl/link.py`'s `Link` class has the same
operations (`run()`/`stop()`/`apply()`/`status()`/`send_cell_config()`/`send_config()`/
`read_captures()`) plus the raw `write_reg()`/`read_reg()`/`read_capture_raw()` if you
need an address `docs/link_register_map.md` describes but no helper wraps yet.

**Full procedure, exit-criterion checklist, and results table**:
`docs/experiments/EXP-02_phase5_link_bringup.md`. **This step (and therefore all of
Phase 5) has not been run on real hardware yet** — don't write a PASS/FAIL into EXP-02
without an actual reading.

## 7. Phase 6 — SIPO load and PISO read

Loading the chip's 136-bit SIPO frame and reading its 168-bit PISO frame, done with the
same generic cells as everything else (no special SIPO/PISO hardware), and checked in
simulation against Dima's own RTL (`fpga/reference/dima_blocks/`). **Simulation only**:
there's no chip-pin -> FMC map yet, so there's nothing to build or wire. The chip-side
timing it follows (which clock edges, polarities, delays) is partly **UNCONFIRMED** until
Dima answers `docs/controller_spec.md` Q1-Q7.

### 7.1 The two profiles

`config/phase6_sipo_piso.yaml` describes both, one setting per chip pin, times from RUN:

| Profile | Pin | Type | What it does (default, 1 MHz) |
|---|---|---|---|
| SIPO_LOAD | `rst_sipo` | PULSE, active-low | 100 ns reset at RUN |
| | `clk_sipo` | CLOCK, 136 cycles | from 1.1 us; exactly 136 rising edges, one per frame bit |
| | `sipo_in` | SERIAL, 136 bits, MSB first | from 1.08 us (just before clk_sipo); changes on clk_sipo's falling edge |
| | `cs` | PULSE, active-high | at 137.1 us, after the last clk_sipo edge; its rising edge latches the frame |
| PISO_READ | `rst_piso` | HIGH | reset held inactive |
| | `clk_piso` | CLOCK, 168 cycles | from 0; edge 1 loads, edges 2-168 shift |
| | `shift` | PULSE, active-high | 750 ns to 167.75 us: low for the load edge, high for every shift edge |
| | `piso_out` | CAPTURE serial, 168 bits | sampled on clk_piso's falling edge; falling edge 1 reads bit 1 before any shift |

The frame to load is under `sipo_in.frame`: `sel_lo` (the 8 bits that become `sel[7:0]`)
and 8 `slices` of 16 bits (slice k = frame bits `[8+16k +: 16]`; slice k reaches
`sel[23:8]` after the k-th `phirst` edge, and slice 0 never does, Q1). You can give a raw
136-bit `data: "0x..."` instead. `testbench.piso_stages` are only the values the
simulation feeds Dima's PISO.

Fields marked UNCONFIRMED in the file: `sipo_in.data_edge`, `piso_out.edge`,
`piso_out.chip_delay` (delay from clk_piso to piso_out on the chip, unknown until
measured), and the polarities.

### 7.2 Generate and check

After any edit to the YAML, from inside `tools/`:

```
python -m nemo_ctl.gen_svh --phase6
```

This **checks the timing first** and only then writes `fpga/src/gen/phase6_cfg_pkg.sv`.
A good config prints one warning (the edges are UNCONFIRMED, that's expected) and
`wrote ...phase6_cfg_pkg.sv`. A config that would corrupt a frame is refused and nothing
is written, for example `cs` moved to 100 us:

```
error: SIPO_LOAD: cs rises at tick 10000, before clk_sipo's last falling edge (tick 13660): parallel_out may latch an incomplete frame
```

What it checks: 136 / 168 clock cycles; clk_sipo starts after rst_sipo releases; sipo_in
starts before clk_sipo's first edge; cs after the last clk_sipo edge; shift rises inside
clk_piso's first low phase and stays high to the end; clk_piso's high time is at least 3
ticks (FPGA input sync) + `chip_delay`. A polarity different from Dima's RTL only warns
(the pad might invert it). `python -m nemo_ctl.gen_svh` without `--phase6` still makes the
Phase 4 package, unchanged.

### 7.3 Build a frame or decode a capture by hand

From inside `tools/`, in Python:

```python
from nemo_ctl.sipo_piso import pack_sipo_frame, dima_sel_after, decode_piso_frame
frame = pack_sipo_frame(0xA5, [0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888])
hex(frame)                   # '0x88887777666655554444333322221111a5'
hex(dima_sel_after(frame, 3))   # '0x4444a5'  = sel[23:0] after 3 phirst edges
for st in decode_piso_frame(0xfffc02469fc001ab5550155555000102001fffff00):
    print(st)                # PisoStage(out1=16383, tdc_out1=0, out0=4660, tdc_out0=127) ... PISO0 first
```

`dima_sel_after(frame, 0, prev_frame=...)`: right after `rst_sipo`, `sel[23:8]` holds the
*previous* load's slice 0 (0 on the first load), a quirk of Dima's RTL (Q1).

### 7.4 Simulate it

From the repo root (Git Bash on Windows):

```
scripts/run_phase6_sim.sh
```

Regenerates the package, then runs `phase6_sipo_piso_tb`: our controller
(`fpga/src/phase6_sipo_piso_top.sv`) driving Dima's SIPO and four chained PISO stages, in
three RUNs with 0, 400 and 600 ns of chip delay on piso_out. Expect:

```
ALL TESTS PASSED (69 checks)
```

RUN 3 is *meant* to get a wrong frame (600 ns is more than the 470 ns the check allows at
1 MHz); its check passes when the frame is wrong.

With **Icarus** the script prints `NOTE: Icarus -> using fpga/tb/sipo_wrapper_icarus_shim.sv`:
Icarus 12 can't elaborate Dima's `sipo_wrapper.sv`, so it uses a copy with one change
(how `sel` is driven, not what it holds). Only **xsim** (`SIM=xsim scripts/run_phase6_sim.sh`,
lab PC) runs Dima's original file. **Phase 6 isn't finished until the xsim run passes.**

### 7.5 What Phase 6 does not do yet

- No hardware: no XDC, the chip pins aren't assigned to FMC pins.
- Not reachable over the Phase 5 link: its registers are 16 bits wide, the frames are
  136/168 (deferred to Phase 7).
- `phirst` comes from the chip's own clock generator; the simulation drives it by hand.
- Before the first APPLY the controller drives every pin 0, so the chip's active-low
  resets are *asserted* until the config is applied (open item for Phase 8).

## 8. Phase 7 — the mode sequencer

A mode becomes an **ordered list of steps**. Each step changes some pins and then ends
either after a fixed time or when something happens (a cell finishes, a capture
completes, an edge count or a level is reached), with a timeout so it can never hang.
The FPGA runs the steps itself (`fpga/src/seq_engine.sv`), so step boundaries are exact
to the 10 ns tick. Today it runs a compile-time step table on the loopback pairs
(`phase7_seq_loopback_top`). Sending a step table to the board at runtime, over the
link, is the next part of Phase 7 and not built yet.

### 8.1 Writing a sequence

`config/phase7_seq_loopback.yaml`, one entry per step:

```yaml
steps:
  - name: idle               # step 0: must set EVERY cell; it is also the idle state
    set:     {clk: {type: LOW}, rst: {type: HIGH}, ...}     # pin settings, same format as §2
    capture: {data_in: {mode: SERIAL, bits: 8}, ...}        # capture modes: LEVEL/EDGE_COUNT/PERIOD/SERIAL
    until:   {after: 1s}
  - name: reset
    set: {rst: {type: PULSE, width: 500ms, polarity: active_low}}   # only what changes
    until: {after: 1s}
```

How a step ends (`until`), one of:

| `until:` | Ends when | Needs `timeout`? |
|---|---|---|
| `{after: 1s}` | exactly that long after the step started | no |
| `{done: clk, timeout: 5s}` | that pin's setting finished (CLOCK with `cycles`, PULSE, SERIAL) | yes |
| `{captured: data_in, timeout: 5s}` | that SERIAL capture got all its bits | yes |
| `{edges: {cell: cs_in, count: 1}, timeout: 2s}` | that EDGE_COUNT capture counted that many rising edges | yes |
| `{level: {cell: en_in, value: 1}, timeout: 100ms}` | that input is at that level | yes |

Rules worth knowing:
- A step only lists the cells it **changes**. Everything else keeps running untouched
  (a clock started in an earlier step doesn't restart). A listed cell restarts at the
  step's start, so its `delay` counts from there.
- `done` / `captured` must refer to a cell set or re-armed **in the same step**.
- If a wait times out, the sequence **FAULTs**: every pin goes to idle, nothing further
  runs. The same happens on ABORT.
- After the last step (or a fault/abort) the pins return to step 0's settings. **Capture
  results are kept** until the next START; edge counts are cleared when RUN drops.
- Wait conditions are checked from a step's 3rd tick (30 ns) on, so a condition that's
  already true ends the step after 30 ns.
- Up to 16 steps. On this bring-up top the cells are fixed: `clk rst data cs en` drive
  FMC pins 0–4, `clk_in rst_in data_in cs_in en_in` read pins 16–20 through the jumpers.
  `data` can only be SERIAL shifted on `clk`'s falling edge, and `data_in` captures on
  `clk`'s rising edge.

### 8.2 Check it

From inside `tools/`:

```
python -m nemo_ctl.sequence ../config/phase7_seq_loopback.yaml
```

Prints one line per step: when it starts (exact while every earlier step has a fixed
duration), which cells it applies, and how it ends. A bad sequence prints every problem
(`error: ...`) and exits 1, for example `step 0 must set every cell` or `a wait step needs
a 'timeout'`.

### 8.3 Generate and simulate

```
python -m nemo_ctl.gen_svh --phase7          # from tools/: -> fpga/src/gen/phase7_cfg_pkg.sv
scripts/run_phase7_sim.sh                    # from the repo root
```

The generator runs the same checks and writes nothing if they fail. The sim script runs
`seq_engine_tb` (expect `ALL TESTS PASSED (31 checks)`) and the bring-up top's testbench
(`ALL TESTS PASSED (27 checks)`). The real sequence takes seconds, so the top's testbench
uses a copy with every time ×1e-4, written to a temp folder. `gen_svh` refuses to write a
time-scaled package without `--out`, so it can't end up in a bitstream by accident.

### 8.4 Run it on the board

Follow `docs/experiments/EXP-03_phase7_sequencer_loopback.md`. In short: same 5 jumpers as
EXP-01, `sw[4]` up = START, down = ABORT; LD0–LD2 show the step, LD3 busy, LD4 done,
LD5 FAULT, LD6 serial capture matched, LD7 aborted. Pulling the J2-20 jumper must give a
FAULT at step 4.

### 8.5 Program-verify from Python

`nemo_ctl.sequence.program_verify(seq, build, read_cell, check, max_iters)` repeats
pulse → read → compare: `build(i)` makes iteration i's step table (e.g. a longer pulse each
time), `check(value)` says when the read-back value is good. It stops at the first pass,
after `max_iters`, or immediately if the sequencer FAULTs. It is tested against a mock;
connecting it to the board needs the link v2 work (not built yet).

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'nemo_ctl'` | Ran a `cli.py` command without `-m`, or not from inside `tools/` | `cd tools` first, then `python3 -m nemo_ctl.cli ...` |
| `ImportError ... 'types' ...` when running a script directly | A very old checkout — `tools/nemo_ctl/types.py` used to shadow the stdlib `types` module. Fixed by renaming it to `pin_types.py`. | `git pull` |
| Wizard says "not understood: ''" repeatedly | You answered blank where the menu needs an actual choice (blank is only valid for optional follow-ups like delay/duty, not the main type menu) | Type a number or a bracketed keyword |
| `validate` prints nothing | That's success, not a hang — no issues found | — |
| `iverilog: command not found` | Not installed, or installed under `/opt/homebrew/bin` which isn't on `PATH` | `export PATH="/opt/homebrew/bin:$PATH"` or install it |
| `ERROR: neither Icarus Verilog nor Vivado xsim found` | Neither simulator is on `PATH` or in its default install folder | Install Icarus (macOS) or run on a PC with Vivado 2022.1 in `C:\Xilinx\Vivado\2022.1` |
| `python3` prints only `Python` and does nothing (Windows) | Windows Store alias, not a real Python | Use `python` |
| A testbench's checks pass individually but you're not sure the design is really right | Simulation proves logic, not real voltage levels, timing margins, or signal integrity | That's exactly why Phases 4/5 still need a real hardware run (§5.3/§6.3) — don't treat [simulated] as a substitute for [measured on board] |
| `link status`/`link run`/... hangs or times out | Wrong `--port`, adapter not actually wired/powered, or `--baud` doesn't match the loaded bitstream's `uart_tx.sv`/`uart_rx.sv` `BAUD` parameter | Double-check the port name and wiring; confirm baud matches (115200 by default) |
| `link ...` raises `ModuleNotFoundError: No module named 'serial'` | `pyserial` isn't installed | `pip3 install -r tools/requirements.txt` (step §1) |
| `gen_svh --phase6` prints `error: SIPO_LOAD: ...` / `PISO_READ: ...` and writes nothing | The config's timing would load or read a corrupted frame | Fix the pin the message names (§7.2); the message says which edge/tick it collides with |
| `sipo_wrapper.sv:49: error: ... Part select is double-driving unresolved wire` | Icarus 12 compiling Dima's original `sipo_wrapper.sv` directly | Use `scripts/run_phase6_sim.sh`, which swaps in the Icarus stand-in (§7.4) |
| `uart_tb.sv:64: error: Cannot "return" from tasks` | Icarus 12 (Windows winget package) is too old for the Phase 5 testbench | Run Phase 5 sims with Icarus 13 (macOS) or xsim (lab PC) |
| `ModuleNotFoundError: No module named 'yaml'` from a sim script | An old checkout picking a Python without the packages | `git pull`, or `pip install -r tools/requirements.txt` for that Python |
| `error: ... step 0 must set every cell` from `nemo_ctl.sequence` / `gen_svh --phase7` | Step 0 is also the idle state, so it must give every cell a setting | Add the missing cells to step 0's `set:` / `capture:` |
| `gen_svh --phase7 --time-scale ...` says `give --out` | A time-scaled table is for simulation only | Add `--out <file outside fpga/src/gen>`, or drop `--time-scale` for the hardware package |
| EXP-03: LD5 (FAULT) on with every jumper in | A wait timed out: a loopback isn't reading back (loose jumper, wrong header row, VADJ not 1V8) | LD0–LD2 show which step; check that step's jumper |
| `link.NackError` | The device NACKed — either a bad checksum got through somehow, or you sent `LOAD_MODE` (permanently unimplemented) | Check `--baud` and wiring (a bad checksum from clean code usually means a framing/timing problem, not a logic bug); don't use `LOAD_MODE` |

## 10. Where things live (quick reference)

| Thing | Path |
|---|---|
| The config you actually edit/run | `config/nemo_config.yaml` |
| Full pin spec / disagreements / open questions | `docs/controller_spec.md` |
| Python tool source | `tools/nemo_ctl/` (see its own `README.md` for a module-by-module list) |
| RTL sources | `fpga/src/` |
| Testbenches | `fpga/tb/` |
| Hardware procedure for Phase 4 | `docs/experiments/EXP-01_phase4_generic_controller_bringup.md` |
| Phase 5 link protocol / byte-level register map | `docs/link_register_map.md` |
| Phase 5 Python client + CLI | `tools/nemo_ctl/link.py`, `nemo_ctl.cli link` |
| Hardware procedure for Phase 5 | `docs/experiments/EXP-02_phase5_link_bringup.md` |
| Phase 6 SIPO/PISO config | `config/phase6_sipo_piso.yaml` -> `fpga/src/gen/phase6_cfg_pkg.sv` |
| Phase 6 frames, timing rules (Python) | `tools/nemo_ctl/sipo_piso.py` |
| Phase 6 top / testbench / sim script | `fpga/src/phase6_sipo_piso_top.sv`, `fpga/tb/phase6_sipo_piso_tb.sv`, `scripts/run_phase6_sim.sh` |
| Dima's SIPO/PISO RTL (reference, never edited) | `fpga/reference/dima_blocks/` |
| Phase 7 sequence (bring-up) | `config/phase7_seq_loopback.yaml` -> `fpga/src/gen/phase7_cfg_pkg.sv` |
| Phase 7 step format, checks, program-verify (Python) | `tools/nemo_ctl/sequence.py` |
| Phase 7 engine / top / XDC / sims | `fpga/src/seq_engine.sv`, `fpga/src/phase7_seq_loopback_top.sv`, `fpga/constraints/phase7_seq_loopback_top.xdc`, `scripts/run_phase7_sim.sh` |
| Hardware procedure for Phase 7 | `docs/experiments/EXP-03_phase7_sequencer_loopback.md` |
| Chronological project log | `docs/WORKLOG.md` |
