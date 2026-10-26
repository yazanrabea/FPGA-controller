# nemo_ctl

Phases 1-2 of `generic_controller_prompt.md` (see `docs/controller_spec.md`): config
format + Python core, plus the interactive CLI wizard. **No hardware, no FPGA code yet.**

```
pip3 install -r tools/requirements.txt
python3 -m pytest          # from the repo root; pytest.ini points at tools/nemo_ctl/tests
```

## Layout

| File | Purpose |
|---|---|
| `gen_pin_db.py` | Regenerates `data/pin_db.yaml` from the lab workbooks (`docs/reference/nemo_chip/*.xlsx`) + the Phase-0 reconciliation from `docs/controller_spec.md` §2/§3. Run it again after the workbooks change. |
| `data/pin_db.yaml` | Generated. The 26-signal pin database: both sheets' pad numbers, allowed types, safe limits (mostly TBD), idle level, polarity, notes. |
| `pins.py` | Loads `data/pin_db.yaml` into `Pin` records. |
| `pin_types.py` | The 7 setting types (LOW/HIGH/PULSE/CLOCK/SERIAL/CAPTURE/BUS). |
| `groups.py` | BUS pin groupings (`s_p`, `b_dft`, `s_dft`). |
| `dft_helper.py` | "pick ADC k, signal X" -> raw DFT bits. **UNCONFIRMED**, see `docs/controller_spec.md` §4 — raw BUS control is the reliable fallback. |
| `units.py` | ns/us/ms/Hz/kHz/MHz/% <-> 100 MHz-tick integers, always reporting achieved value + error. |
| `config.py` | Loads/saves `config/nemo_config.yaml`. |
| `validate.py` | Allowed types per pin, safe limits, SERIAL must reference a CLOCK pin, no pin used twice. |
| `timing.py` | Per-mode timing summary table. |
| `preview.py` | WaveDrom JSON waveform preview for one mode. |
| `excel_io.py` | Excel import/export, one sheet per mode, same columns as the YAML; also a blank template generator. |
| `wizard.py` | Headless wizard engine (Phase 2): pick mode -> each block -> each input pin, with copy-block-from-another-mode, reset-to-defaults, and a DFT helper menu. Takes `ask`/`tell` callables so the whole flow is scriptable in tests, not just from a real terminal. |
| `cli.py` | The only file that calls `input()`/`print()` directly. `python3 -m nemo_ctl.cli wizard --mode INFERENCE` (also `validate`, `preview`, `export-excel`, `import-excel`, `gen-template`, the browser form `gui`, and the board commands `link ...` (Phase 5) and `seq ...` (Phase 7 round 2)). |
| `gen_svh.py` | Generates a top level's compile-time package: `nemo_cfg_pkg.sv` for `phase4_loopback_top` (default), `phase6_cfg_pkg.sv` for `phase6_sipo_piso_top` (`--phase6`, refuses a config that fails `sipo_piso`'s timing checks), `phase7_cfg_pkg.sv` for `phase7_seq_loopback_top` (`--phase7`, `--time-scale`/`--out` for a simulation copy), `phase7_link_pkg.sv` for `phase7_link_top` (`--phase7-link`, `--table-out` for the testbench's table). `python -m nemo_ctl.gen_svh [--phase6|--phase7|--phase7-link]`. |
| `sipo_piso.py` | Phase 6: 136-bit SIPO frame pack/unpack + Dima's `sel` behaviour (Q1/Q2 as written), 168-bit PISO frame encode/decode (4 stages, PISO0 first), SIPO_LOAD / PISO_READ timing builders and rules, `config/phase6_sipo_piso.yaml` loader. |
| `sequence.py` | Phase 7: step sequence format (`set` / `capture` / `until`), validator, tick compiler (with a time scale for simulation copies), step summary, `program_verify()` loop; round 2: `entry_layout` / `encode_step` (the link-v2 step-entry bytes, single source for the RTL package) and `link_late_warnings`. `python -m nemo_ctl.sequence <yaml>` checks a sequence. |
| `jtag.py` | JTAG link (J4): the PC side of `fpga/src/jtag_link_bridge.sv`. Scan format (`pack_down` / `parse_up`), `JtagTransport` (same `write`/`read` as `SerialTransport`, applies the transport rules of `docs/link_register_map.md`), `XsdbScanPort` (runs `scripts/jtag_server.tcl` in Vivado's xsdb), `open_jtag()`. CLI: `--jtag` instead of `--port`. |
| `link.py` | Phase 5 link client (`Link`: frames, WRITE_REG/READ_REG/RUN/STOP/APPLY/STATUS/READ_CAPTURE) and Phase 7 round 2 `SeqLink` (link v2: load a step table, start, wait, read captures; implements `sequence.Sequencer`). |
| `gui.py` + `data/config_gui.html` | Browser form for the config (`python -m nemo_ctl.cli gui`): local server on 127.0.0.1 (standard library only); same checks (`validate_config`), achieved values (`timing.py`) and save (`save_config`, `.bak` kept) as the wizard. |
| `waves.py` | Real edge times of one mode, per pin, in ns from RUN (same rules as `sig_cell.sv`), for the editor's Signals panel (`POST /api/waves`). Windowed; too-dense lanes flagged. |
| `tests/` | pytest suite — run from the repo root with `python3 -m pytest`. |

## Build a mode interactively

```
python3 -m nemo_ctl.cli wizard --mode INFERENCE
```

Walks every input pin, block by block, showing the current setting and a menu built from
exactly the types that pin allows. Grouped pins (`s0_p,s1_p,s2_p` etc.) are walked once as
a group, with a "set individually" escape hatch back to raw per-pin control. Saves back to
`config/nemo_config.yaml` (or `--config <path>`); add `--excel out.xlsx` to also export.

## Quick check

```python
from nemo_ctl.config import load_config
from nemo_ctl.pins import load_pin_db
from nemo_ctl.validate import validate_config
from nemo_ctl.timing import summarize_mode, format_timing_table

cfg = load_config()          # config/nemo_config.yaml
db = load_pin_db()
for issue in validate_config(cfg, db):
    print(issue)
print(format_timing_table(summarize_mode(cfg, "INFERENCE")))
```

## What's still open

Everything flagged TBD/UNCONFIRMED in `docs/controller_spec.md` §4/§5 — most pin
meanings/polarities, the DFT lookup table, the chip-pin -> FMC LA_P assignment
(`pin_map` in `config/nemo_config.yaml`, currently all `null`), and max safe frequencies.
None of that blocks Phase 1 (it's all data, not code), but it does mean most of
`validate_config`'s output on any real mode is warnings, not green lights.
