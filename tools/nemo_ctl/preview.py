"""Waveform preview as WaveDrom JSON (generic_controller_prompt.md §1 Phase 1: "waveform
preview (matplotlib or WaveDrom JSON)"). WaveDrom chosen: it's plain JSON, needs no extra
dependency, and renders in any WaveDrom-compatible markdown viewer/editor.

This is a schematic preview, not a cycle-accurate render: each signal gets one character
per drawn segment (constant / clock / pulse / data), not one character per actual tick —
real periods and delays can be thousands of ticks, far too many to draw literally.
"""
from __future__ import annotations

from .config import DFT_HELPER_TYPE, Config
from .groups import PIN_GROUPS
from .pin_types import PinType
from .units import quantize_clock, quantize_duration


def _wave_for_setting(key: str, setting) -> dict:
    t = setting.type
    p = setting.params

    if t == DFT_HELPER_TYPE or key in PIN_GROUPS:
        return {"name": key, "wave": "x", "node": ".", "data": [f"{key} (see timing table)"]}

    if t == PinType.LOW.value:
        return {"name": key, "wave": "0"}
    if t == PinType.HIGH.value:
        return {"name": key, "wave": "1"}

    if t == PinType.CLOCK.value:
        q = quantize_clock(p.get("freq"), p.get("duty", "50%"))
        cycles = p.get("cycles")
        n = min(cycles, 8) if cycles else 8
        wave = "P" + "." * (n - 1) if n > 1 else "P"
        return {"name": key, "wave": wave, "period": 1,
                "data": [f"{q.achieved_hz/1e6:.3f} MHz"]}

    if t == PinType.PULSE.value:
        pol = p.get("polarity", "active_high")
        idle, active = ("0", "1") if pol == "active_high" else ("1", "0")
        return {"name": key, "wave": f"{idle}{active}{idle}"}

    if t == PinType.SERIAL.value:
        return {"name": key, "wave": "x" + "=" * 4 + "x",
                "data": [p.get("data", "?")]}

    if t == PinType.CAPTURE.value:
        return {"name": key, "wave": "z" + "x" * 4 + "z"}

    return {"name": key, "wave": "x"}


def preview_mode(config: Config, mode: str) -> dict:
    """WaveDrom JSON {signal: [...]} for one mode, one lane per configured key, grouped
    by block with a block-name text lane as a separator."""
    signal_lanes: list[dict] = []
    for block, settings in config.modes.get(mode, {}).items():
        if not settings:
            continue
        signal_lanes.append({"name": block, "wave": ""})
        for key, setting in settings.items():
            signal_lanes.append(_wave_for_setting(key, setting))
    return {"signal": signal_lanes, "head": {"text": f"mode: {mode}"}}
