# nemo_ctl

Phase 1 of `generic_controller_prompt.md` (see `docs/controller_spec.md`). Config format +
Python core only — **no hardware, no FPGA code yet.**

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
| `types.py` | The 7 setting types (LOW/HIGH/PULSE/CLOCK/SERIAL/CAPTURE/BUS). |
| `groups.py` | BUS pin groupings (`s_p`, `b_dft`, `s_dft`). |
| `dft_helper.py` | "pick ADC k, signal X" -> raw DFT bits. **UNCONFIRMED**, see `docs/controller_spec.md` §4 — raw BUS control is the reliable fallback. |
| `units.py` | ns/us/ms/Hz/kHz/MHz/% <-> 100 MHz-tick integers, always reporting achieved value + error. |
| `config.py` | Loads/saves `config/nemo_config.yaml`. |
| `validate.py` | Allowed types per pin, safe limits, SERIAL must reference a CLOCK pin, no pin used twice. |
| `timing.py` | Per-mode timing summary table. |
| `preview.py` | WaveDrom JSON waveform preview for one mode. |
| `excel_io.py` | Excel import/export, one sheet per mode, same columns as the YAML; also a blank template generator. |
| `tests/` | pytest suite — run from the repo root with `python3 -m pytest`. |

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
