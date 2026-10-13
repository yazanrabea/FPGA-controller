"""Excel import/export: one sheet per mode, same columns, generated template
(generic_controller_prompt.md §1/Phase 1) — the wizard, the YAML and the Excel sheet are
three views of one format, so this must round-trip losslessly against config.py.
"""
from __future__ import annotations

from pathlib import Path

import openpyxl

from .config import DFT_HELPER_TYPE, Config, PinSetting
from .groups import PIN_GROUPS
from .pins import Pin

# Union of every param key used by any type (config.py docstring lists them). Block/Pin/
# Type are always present; everything else is blank unless that type uses it.
PARAM_COLUMNS = [
    "freq", "duty", "delay", "cycles", "width", "repeat", "period", "polarity",
    "clock", "data", "msb_first", "data_edge", "bits", "mode", "edge", "value",
    "adc", "signal",
]
COLUMNS = ["Block", "Pin", "Type"] + PARAM_COLUMNS


def export_config(config: Config, path: Path) -> None:
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    for mode_name, blocks in config.modes.items():
        ws = wb.create_sheet(mode_name)
        ws.append(COLUMNS)
        for block_name, settings in blocks.items():
            for key, setting in settings.items():
                row = [block_name, key, setting.type]
                row += [setting.params.get(col) for col in PARAM_COLUMNS]
                ws.append(row)
    wb.save(path)


def export_template(pin_db: dict[str, Pin], path: Path, modes=("READ", "WRITE", "INFERENCE")) -> None:
    """One row per driveable pin, grouped by block, Type left blank for the user to fill
    in (or copy from an existing mode's sheet)."""
    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    for mode_name in modes:
        ws = wb.create_sheet(mode_name)
        ws.append(COLUMNS)
        for pin in pin_db.values():
            if pin.direction != "in":
                continue
            ws.append([pin.block, pin.name, ""] + [None] * len(PARAM_COLUMNS))
    wb.save(path)


def _row_to_setting(key: str, row: dict) -> PinSetting:
    type_str = row["Type"]
    params = {}
    for col in PARAM_COLUMNS:
        v = row.get(col)
        if v is not None and v != "":
            params[col] = v
    return PinSetting(key=key, type=type_str, params=params)


def import_config(path: Path) -> Config:
    wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
    modes: dict[str, dict[str, dict[str, PinSetting]]] = {}
    for ws in wb.worksheets:
        mode_name = ws.title
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            modes[mode_name] = {}
            continue
        header = list(rows[0])
        blocks: dict[str, dict[str, PinSetting]] = {}
        for raw_row in rows[1:]:
            row = dict(zip(header, raw_row))
            block = row.get("Block")
            key = row.get("Pin")
            if not block or not key or not row.get("Type"):
                continue
            blocks.setdefault(block, {})[key] = _row_to_setting(key, row)
        modes[mode_name] = blocks
    return Config(modes=modes, pin_map={})
