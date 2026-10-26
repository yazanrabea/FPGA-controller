"""Validator: allowed types per pin, safe limits, SERIAL->CLOCK references, no pin used
twice — the four checks generic_controller_prompt.md §1/Phase 1 calls out explicitly.
"""
from __future__ import annotations

from dataclasses import dataclass

from .config import DFT_HELPER_TYPE, Config, PinSetting
from .dft_helper import resolve as resolve_dft
from .groups import PIN_GROUPS
from .pins import Pin
from .pin_types import PinType
from .units import UnitsError, quantize_clock, quantize_duration

# generic_controller_prompt.md §2: warn above 10 MHz (jumper-wire signal integrity,
# docs/issues.md), hard limit 50 MHz — applies to every CLOCK pin regardless of any
# pin-specific limit in pin_db (which is usually still TBD/None).
GENERIC_CLOCK_WARN_HZ = 10e6
GENERIC_CLOCK_HARD_LIMIT_HZ = 50e6


@dataclass(frozen=True)
class Issue:
    level: str  # "error" | "warning"
    mode: str
    block: str
    key: str
    message: str

    def __str__(self) -> str:
        return f"[{self.level.upper()}] {self.mode}/{self.block}/{self.key}: {self.message}"


def _error(issues, mode, block, key, msg):
    issues.append(Issue("error", mode, block, key, msg))


def _warn(issues, mode, block, key, msg):
    issues.append(Issue("warning", mode, block, key, msg))


def validate_config(config: Config, pin_db: dict[str, Pin]) -> list[Issue]:
    issues: list[Issue] = []

    for mode in config.mode_names():
        clock_pins = {
            key for block, key, s in config.iter_settings(mode)
            if s.type == PinType.CLOCK.value
        }
        touched: dict[str, str] = {}  # pin name -> "block/key" that already touched it

        def touch(pin_name: str, block: str, key: str):
            if pin_name in touched:
                _error(issues, mode, block, key,
                       f"pin {pin_name!r} already configured by {touched[pin_name]!r}")
            else:
                touched[pin_name] = f"{block}/{key}"

        for block, key, setting in config.iter_settings(mode):
            if setting.type == DFT_HELPER_TYPE:
                _validate_dft_select(issues, mode, block, key, setting)
                continue

            if key in PIN_GROUPS:
                _validate_bus(issues, mode, block, key, setting, touch)
                continue

            pin = pin_db.get(key)
            if pin is None:
                _error(issues, mode, block, key, f"unknown pin {key!r} (not in pin_db)")
                continue
            touch(key, block, key)

            if pin.block != block:
                _error(issues, mode, block, key,
                       f"pin {key!r} belongs to block {pin.block!r}, not {block!r}")

            try:
                pin_type = PinType(setting.type)
            except ValueError:
                _error(issues, mode, block, key, f"unknown type {setting.type!r}")
                continue
            if pin_type not in pin.allowed_types:
                _error(issues, mode, block, key,
                       f"type {pin_type.value} not allowed for {key!r} "
                       f"(allowed: {[t.value for t in pin.allowed_types]})")
                continue

            _validate_limits(issues, mode, block, key, pin, setting, clock_pins)

    _validate_pin_map(issues, config, pin_db)
    return issues


def _validate_pin_map(issues, config: Config, pin_db: dict[str, Pin]):
    """config.pin_map: chip signal -> FMC LA_P pin (docs/decisions.md, 2026-10-26).
    Errors: a signal not in pin_db, a name that isn't one of the 32 LA_P pins, an LA pin
    used twice. Warnings: a signal without a pin, a pin not yet verified on the board in
    the direction it's used. An empty pin_map (test configs) is not checked."""
    if not config.pin_map:
        return
    from .fmc_pins import FMC_PINS, is_verified
    used: dict[str, str] = {}
    for sig, la in config.pin_map.items():
        pin = pin_db.get(sig)
        block = pin.block if pin else "?"
        if pin is None:
            _error(issues, "pin_map", block, sig, f"unknown chip signal {sig!r} (not in pin_db)")
            continue
        if la is None:
            _warn(issues, "pin_map", block, sig, "no FMC pin assigned yet")
            continue
        if la not in FMC_PINS:
            _error(issues, "pin_map", block, sig,
                   f"{la!r} is not one of the 32 FMC LA_P pins (LA00_P .. LA31_P)")
            continue
        if la in used:
            _error(issues, "pin_map", block, sig, f"{la} is already used by {used[la]!r}")
            continue
        used[la] = sig
        fpga_drives = pin.direction == "in"           # a chip input is an FPGA output
        if not is_verified(la, fpga_drives):
            f = FMC_PINS[la]
            _warn(issues, "pin_map", block, sig,
                  f"{la} ({f.header}, {f.package_pin}) not verified on the board as an FPGA "
                  f"{'output' if fpga_drives else 'input'} yet (docs/pin_verification.md)")
    for sig, pin in pin_db.items():
        if sig not in config.pin_map:
            _warn(issues, "pin_map", pin.block, sig, "missing from pin_map")


def _validate_bus(issues, mode, block, key, setting: PinSetting, touch):
    members = PIN_GROUPS[key]
    if setting.type != PinType.BUS.value:
        _error(issues, mode, block, key, f"group key {key!r} must use type BUS")
        return
    value = setting.params.get("value")
    if value is None:
        _error(issues, mode, block, key, "BUS setting needs a 'value'")
        return
    if not isinstance(value, int) or not (0 <= value < (1 << len(members))):
        _error(issues, mode, block, key,
               f"value {value!r} doesn't fit {len(members)}-bit group {key!r}")
        return
    for m in members:
        touch(m, block, key)


def _validate_dft_select(issues, mode, block, key, setting: PinSetting):
    adc = setting.params.get("adc")
    signal = setting.params.get("signal")
    try:
        sel = resolve_dft(adc, signal)
    except (ValueError, TypeError) as exc:
        _error(issues, mode, block, key, f"invalid dft_select: {exc}")
        return
    _warn(issues, mode, block, key, sel.note)


def _validate_limits(issues, mode, block, key, pin: Pin, setting: PinSetting, clock_pins: set[str]):
    pin_type = PinType(setting.type)
    limits = pin.limits or {}

    if pin_type == PinType.CLOCK:
        try:
            q = quantize_clock(setting.params.get("freq"), setting.params.get("duty", "50%"))
        except (UnitsError, TypeError) as exc:
            _error(issues, mode, block, key, f"bad CLOCK setting: {exc}")
            return
        # Checked against the *requested* frequency, not achieved: quantize_clock clamps
        # period_ticks to a minimum of 2, so achieved_hz can never exceed 50 MHz on this
        # 100 MHz timebase — checking achieved_hz here would make this branch dead code.
        if q.requested_hz > GENERIC_CLOCK_HARD_LIMIT_HZ:
            _error(issues, mode, block, key,
                   f"requested {q.requested_hz/1e6:.4f} MHz exceeds the generic 50 MHz hard limit "
                   f"(clamped to {q.achieved_hz/1e6:.4f} MHz, {q.error_pct:+.1f}% off)")
        elif q.requested_hz > GENERIC_CLOCK_WARN_HZ:
            _warn(issues, mode, block, key,
                  f"{q.achieved_hz/1e6:.4f} MHz is above 10 MHz — jumper-wire signal "
                  f"integrity risk (docs/issues.md)")
        max_freq = limits.get("max_freq_hz")
        if max_freq is not None and q.requested_hz > max_freq:
            _error(issues, mode, block, key,
                   f"requested {q.requested_hz/1e6:.4f} MHz exceeds this pin's max_freq_hz={max_freq}")
        if max_freq is None:
            _warn(issues, mode, block, key, "this pin's max safe frequency is TBD (chip-side limit unknown)")

    elif pin_type == PinType.PULSE:
        width = setting.params.get("width")
        if width is None:
            _error(issues, mode, block, key, "PULSE setting needs a 'width'")
            return
        try:
            q = quantize_duration(width)
        except UnitsError as exc:
            _error(issues, mode, block, key, f"bad PULSE width: {exc}")
            return
        min_ticks = limits.get("min_width_ticks")
        if q.ticks < 1:
            _error(issues, mode, block, key, "PULSE width quantizes to 0 ticks")
        elif min_ticks is not None and q.ticks < min_ticks:
            _error(issues, mode, block, key,
                   f"PULSE width {q.ticks} ticks is below this pin's min_width_ticks={min_ticks}")

    elif pin_type == PinType.SERIAL:
        clock = setting.params.get("clock")
        if not clock:
            _error(issues, mode, block, key, "SERIAL setting needs a 'clock' reference")
        elif clock not in clock_pins:
            _error(issues, mode, block, key,
                   f"SERIAL references {clock!r}, which is not configured as a CLOCK in mode {mode!r}")

    elif pin_type == PinType.CAPTURE:
        clock = setting.params.get("clock")
        if clock and clock not in clock_pins:
            _error(issues, mode, block, key,
                   f"CAPTURE references {clock!r}, which is not configured as a CLOCK in mode {mode!r}")


def has_errors(issues: list[Issue]) -> bool:
    return any(i.level == "error" for i in issues)
