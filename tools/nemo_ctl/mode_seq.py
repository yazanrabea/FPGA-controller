"""Chip pipeline step C5: an editor *mode* (config/nemo_config.yaml) -> a *sequence* for chip_top.

The editor / wizard / Excel describe a mode as "every pin does X" ({block: {pin: setting}}).
chip_top runs step sequences (sequence.py). This turns one mode into a 2-step sequence for
target `chip_top` (sequence.chip_target()):

  step 0 "idle":  every chip input at its idle level (pin_db: rst_sipo / rst_piso HIGH, the
                  rest LOW; TBD idle levels are LOW and reported), every chip output captured
                  as LEVEL. Also the state chip_top returns to after the run.
  step 1 <mode>:  every pin the mode configures, exactly as configured (same keys: freq, duty,
                  cycles, delay, width, polarity, repeat, period, data, bits, msb_first,
                  clock, data_edge); BUS groups and the DFT helper become LOW/HIGH per member
                  pin; CAPTURE settings become cap-cell modes. Ends after `duration`.

So what the editor's Signals panel draws for a mode is what chip_top drives (EXP-07 compares
the two on the logic analyser). The duration defaults to 10 % past the mode's last finite
event (waves.py); a mode with only free-running clocks needs an explicit one.

Nothing here guesses: a SERIAL with no data, an unknown capture mode, an edge the bitstream
isn't wired for (chip_pkg: sipo_in on clk_sipo falling, piso_out on clk_piso falling) are errors.
"""
from __future__ import annotations

import math

from .config import DFT_HELPER_TYPE, Config
from .dft_helper import resolve as resolve_dft
from .groups import PIN_GROUPS, group_bits
from .pins import Pin, load_pin_db
from .sequence import SequenceError, StepTable, Target, chip_target, compile_steps

_CAP_MODES = {"level": "LEVEL", "edge_count": "EDGE_COUNT", "edges": "EDGE_COUNT",
              "period": "PERIOD", "frequency": "PERIOD", "serial": "SERIAL"}
_SIG_KEYS = ("freq", "duty", "cycles", "delay", "width", "polarity", "repeat", "period",
             "data", "bits", "msb_first", "clock", "data_edge")
MAX_DURATION_S = 40.0          # 32-bit tick counter at 100 MHz = 42.9 s


class ModeError(SequenceError):
    pass


def _idle_steps(target: Target, pin_db: dict[str, Pin], notes: list[str]) -> dict:
    sets, tbd = {}, []
    for c in target.sig_cells:
        lvl = (pin_db[c.name].idle_level or "").upper()
        if lvl not in ("LOW", "HIGH"):
            tbd.append(c.name)
            lvl = "LOW"
        sets[c.name] = {"type": lvl}
    if tbd:
        notes.append(f"idle level TBD in pin_db (Dima), idle = LOW for: {', '.join(tbd)}")
    caps = {c.name: {"mode": "LEVEL"} for c in target.cap_cells}
    return {"name": "idle", "set": sets, "capture": caps}


def _mode_settings(config: Config, mode: str, target: Target) -> tuple[dict, dict]:
    """(sig settings, cap settings) of one mode, by chip signal name."""
    sig_names = {c.name for c in target.sig_cells}
    cap_names = {c.name for c in target.cap_cells}
    sets: dict[str, dict] = {}
    caps: dict[str, dict] = {}

    def put_bit(pin: str, bit: int, where: str):
        if pin in sets:
            raise ModeError(f"{where}: {pin} is already set in this mode")
        sets[pin] = {"type": "HIGH" if bit else "LOW"}

    for block, key, s in config.iter_settings(mode):
        where = f"{mode}/{block}/{key}"
        p = s.params
        if s.type == DFT_HELPER_TYPE:
            sel = resolve_dft(p.get("adc"), p.get("signal"))
            for pin, bit in {**group_bits("b_dft", sel.b_value), **group_bits("s_dft", sel.s_value)}.items():
                put_bit(pin, bit, where)
        elif key in PIN_GROUPS:
            if s.type != "BUS":
                raise ModeError(f"{where}: a group needs type BUS, got {s.type}")
            for pin, bit in group_bits(key, int(p.get("value", 0))).items():
                put_bit(pin, bit, where)
        elif s.type == "CAPTURE":
            if key not in cap_names:
                raise ModeError(f"{where}: {key} is not a chip output")
            m = _CAP_MODES.get(str(p.get("mode", "level")).lower())
            if m is None:
                raise ModeError(f"{where}: unknown capture mode {p.get('mode')!r} "
                                f"(level / edge_count / period / serial)")
            cap = {"mode": m}
            if m == "SERIAL":
                cap.update(bits=p.get("bits"), msb_first=p.get("msb_first", True))
                spec = target.cap_cells[target.cap_index(key)]
                if spec.strobe and (p.get("clock", spec.strobe[0]), p.get("edge", spec.strobe[1])) != spec.strobe:
                    raise ModeError(f"{where}: chip_top captures {key} on {spec.strobe[0]}'s "
                                    f"{spec.strobe[1]} edge, the mode asks for "
                                    f"{p.get('clock')}'s {p.get('edge')} edge")
            caps[key] = cap
        else:
            if key not in sig_names:
                raise ModeError(f"{where}: {key} is not a chip input")
            if key in sets:
                raise ModeError(f"{where}: {key} is already set in this mode")
            if s.type == "SERIAL":
                raw = p.get("data")
                try:
                    int(raw, 0) if isinstance(raw, str) else int(raw)
                except (TypeError, ValueError):
                    raise ModeError(f"{where}: SERIAL data {raw!r} isn't a number yet "
                                    f"(set it in the editor, e.g. 0xA5)") from None
            sets[key] = {"type": s.type, **{k: p[k] for k in _SIG_KEYS if k in p}}
    return sets, caps


def mode_steps(config: Config, mode: str, duration_s: float | None = None,
               target: Target | None = None, pin_db: dict[str, Pin] | None = None) -> tuple[list[dict], list[str]]:
    """The 2 raw steps (as sequence YAML would have them) + notes for the user."""
    from .waves import mode_waves
    target = target or chip_target()
    pin_db = pin_db or load_pin_db()
    if mode not in config.modes:
        raise ModeError(f"no mode {mode!r} in the config (has {list(config.modes)})")
    notes: list[str] = []
    idle = _idle_steps(target, pin_db, notes)
    sets, caps = _mode_settings(config, mode, target)
    if not sets and not caps:
        raise ModeError(f"mode {mode!r} configures nothing")
    if duration_s is None:
        end_ns = mode_waves(config, mode)["end"]
        if end_ns <= 0:
            raise ModeError(f"mode {mode!r} has no finite end (free-running clocks only): give a duration")
        duration_s = math.ceil(end_ns * 1.1 / 1000) * 1e-6       # +10 %, whole microseconds
        notes.append(f"duration {duration_s * 1e6:g} us (the mode's last event + 10 %)")
    if not 0 < duration_s <= MAX_DURATION_S:
        raise ModeError(f"duration {duration_s} s out of range (0 .. {MAX_DURATION_S} s)")
    run = {"name": mode, "set": sets, "until": {"after": f"{duration_s * 1e6:g}us"}}
    if caps:
        run["capture"] = caps
    idle["until"] = {"after": "10us"}
    return [idle, run], notes


def mode_table(config: Config, mode: str, duration_s: float | None = None) -> tuple[StepTable, list[str]]:
    """The mode compiled for chip_top (errors as SequenceError, one per line)."""
    steps, notes = mode_steps(config, mode, duration_s)
    return compile_steps(steps, chip_target()), notes
