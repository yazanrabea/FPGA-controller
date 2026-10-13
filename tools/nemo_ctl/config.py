"""Load/save config/nemo_config.yaml — the source-of-truth format from
generic_controller_prompt.md §2 architecture diagram ("PC: config file (source of truth)").

Kept deliberately light: a PinSetting is just {type, **params}; params are whatever that
type needs (freq/duty/cycles/delay for CLOCK, width/delay/polarity/repeat/period for
PULSE, clock/data/msb_first/data_edge for SERIAL, value for BUS, adc/signal for the DFT
helper pseudo-type). validate.py / timing.py / preview.py interpret params per type;
nothing here enforces their shape, so new per-type fields don't require touching this file.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .types import PinType

DFT_HELPER_TYPE = "DFT_HELPER"  # pseudo-type: not a hardware PinType, resolved by dft_helper.py

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "nemo_config.yaml"


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class PinSetting:
    key: str  # pin name, a groups.PIN_GROUPS key, or "dft_select"
    type: str  # a PinType value, or DFT_HELPER_TYPE
    params: dict = field(default_factory=dict)


@dataclass
class Config:
    modes: dict[str, dict[str, dict[str, PinSetting]]]  # mode -> block -> key -> setting
    pin_map: dict[str, str | None] = field(default_factory=dict)

    def mode_names(self) -> list[str]:
        return list(self.modes.keys())

    def iter_settings(self, mode: str):
        """Yield (block, key, PinSetting) for one mode."""
        for block, settings in self.modes.get(mode, {}).items():
            for key, setting in settings.items():
                yield block, key, setting


def _parse_setting(key: str, raw) -> PinSetting:
    if not isinstance(raw, dict) or "type" not in raw:
        raise ConfigError(f"{key!r}: setting must be a mapping with a 'type' key, got {raw!r}")
    type_str = raw["type"]
    if type_str != DFT_HELPER_TYPE:
        try:
            PinType(type_str)
        except ValueError:
            raise ConfigError(f"{key!r}: unknown type {type_str!r}") from None
    params = {k: v for k, v in raw.items() if k != "type"}
    return PinSetting(key=key, type=type_str, params=params)


def _parse_block(block_name: str, raw: dict) -> dict[str, PinSetting]:
    if raw is None:
        return {}
    settings: dict[str, PinSetting] = {}
    for key, raw_setting in raw.items():
        if key == "dft_select":
            settings[key] = PinSetting(key=key, type=DFT_HELPER_TYPE, params=dict(raw_setting))
        else:
            settings[key] = _parse_setting(key, raw_setting)
    return settings


def load_config(path: Path | None = None) -> Config:
    path = path or DEFAULT_CONFIG_PATH
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    modes: dict[str, dict[str, dict[str, PinSetting]]] = {}
    for mode_name, mode_body in (doc.get("modes") or {}).items():
        mode_body = mode_body or {}
        modes[mode_name] = {
            block_name: _parse_block(block_name, block_body)
            for block_name, block_body in mode_body.items()
        }
    pin_map = dict(doc.get("pin_map") or {})
    return Config(modes=modes, pin_map=pin_map)


def config_to_dict(config: Config) -> dict:
    """Empty blocks (no settings at all — e.g. fully absorbed into another block's DFT
    helper pick) are dropped, not emitted as `{}`. Every consumer (iter_settings,
    validate_config, timing, preview) already treats "block absent" and "block present
    but empty" identically, and excel_io.py's per-mode sheet has no way to represent a
    block with zero rows — so both directions of the round-trip must agree on dropping
    them, or re-importing an exported sheet silently loses those keys."""
    out_modes = {}
    for mode_name, blocks in config.modes.items():
        out_blocks = {}
        for block_name, settings in blocks.items():
            out_block = {}
            for key, setting in settings.items():
                if setting.type == DFT_HELPER_TYPE:
                    out_block[key] = dict(setting.params)
                else:
                    out_block[key] = {"type": setting.type, **setting.params}
            if out_block:
                out_blocks[block_name] = out_block
        out_modes[mode_name] = out_blocks
    return {"modes": out_modes, "pin_map": dict(config.pin_map)}


def save_config(config: Config, path: Path | None = None) -> None:
    path = path or DEFAULT_CONFIG_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        yaml.safe_dump(config_to_dict(config), f, sort_keys=False, width=100)
