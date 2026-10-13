"""Human units (ns/us/ms/Hz/kHz/MHz/%) <-> 100 MHz-tick integers.

One tick = 10 ns, per generic_controller_prompt.md §2 ("one 100 MHz timebase; every
parameter is stored as integer ticks"). Quantizing always reports the achieved value and
the error against what the user asked for, per the same section.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

TICK_NS = 10.0
TIMEBASE_HZ = 1.0 / (TICK_NS * 1e-9)  # 100 MHz

_DURATION_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*(ns|us|µs|ms|s)?\s*$")
_FREQ_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*(Hz|kHz|MHz|GHz)?\s*$", re.IGNORECASE)
_PERCENT_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*%?\s*$")

_DURATION_UNIT_NS = {None: 1.0, "ns": 1.0, "us": 1e3, "µs": 1e3, "ms": 1e6, "s": 1e9}
_FREQ_UNIT_HZ = {None: 1.0, "hz": 1.0, "khz": 1e3, "mhz": 1e6, "ghz": 1e9}


class UnitsError(ValueError):
    pass


def parse_duration_ns(value) -> float:
    """"1us", "100ns", "1.5ms", 0, "0" -> nanoseconds (float)."""
    if isinstance(value, (int, float)):
        return float(value)
    m = _DURATION_RE.match(str(value))
    if not m:
        raise UnitsError(f"not a duration: {value!r}")
    mag, unit = m.groups()
    return float(mag) * _DURATION_UNIT_NS[unit]


def parse_freq_hz(value) -> float:
    """"1MHz", "500kHz", 1_000_000 -> Hz (float)."""
    if isinstance(value, (int, float)):
        return float(value)
    m = _FREQ_RE.match(str(value))
    if not m:
        raise UnitsError(f"not a frequency: {value!r}")
    mag, unit = m.groups()
    return float(mag) * _FREQ_UNIT_HZ[(unit or "hz").lower()]


def parse_duty(value) -> float:
    """"50%", 0.5, 50 -> fraction in (0, 1)."""
    if isinstance(value, (int, float)):
        frac = float(value) / 100.0 if value > 1 else float(value)
        return frac
    m = _PERCENT_RE.match(str(value))
    if not m:
        raise UnitsError(f"not a duty cycle: {value!r}")
    return float(m.group(1)) / 100.0


def ns_to_ticks(ns: float) -> int:
    return round(ns / TICK_NS)


def ticks_to_ns(ticks: int) -> float:
    return ticks * TICK_NS


@dataclass(frozen=True)
class QuantizedClock:
    period_ticks: int
    high_ticks: int
    requested_hz: float
    achieved_hz: float
    error_pct: float


def quantize_clock(freq, duty="50%") -> QuantizedClock:
    """freq/duty in human units -> integer ticks + achieved value/error.

    period_ticks >= 2 always (generic_controller_prompt.md §2). high_ticks is clamped to
    [1, period_ticks - 1] so a non-trivial duty always produces an edge.
    """
    requested_hz = parse_freq_hz(freq)
    duty_frac = parse_duty(duty)
    if requested_hz <= 0:
        raise UnitsError(f"frequency must be > 0, got {requested_hz}")
    period_ticks = max(2, round(TIMEBASE_HZ / requested_hz))
    high_ticks = round(period_ticks * duty_frac)
    high_ticks = min(max(high_ticks, 1), period_ticks - 1)
    achieved_hz = TIMEBASE_HZ / period_ticks
    error_pct = (achieved_hz - requested_hz) / requested_hz * 100.0
    return QuantizedClock(period_ticks, high_ticks, requested_hz, achieved_hz, error_pct)


@dataclass(frozen=True)
class QuantizedDuration:
    ticks: int
    requested_ns: float
    achieved_ns: float
    error_pct: float


def quantize_duration(value) -> QuantizedDuration:
    requested_ns = parse_duration_ns(value)
    ticks = max(0, ns_to_ticks(requested_ns))
    achieved_ns = ticks_to_ns(ticks)
    error_pct = (
        0.0 if requested_ns == 0 else (achieved_ns - requested_ns) / requested_ns * 100.0
    )
    return QuantizedDuration(ticks, requested_ns, achieved_ns, error_pct)
