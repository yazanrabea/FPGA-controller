"""Per-mode timing summary: every setting quantized to ticks, with achieved value/error
shown immediately (generic_controller_prompt.md §2: "the tool converts the user's Hz/ns/
us/ms to ticks and ALWAYS shows the achieved value and error").
"""
from __future__ import annotations

from dataclasses import dataclass

from .config import DFT_HELPER_TYPE, Config
from .dft_helper import resolve as resolve_dft
from .groups import PIN_GROUPS
from .pin_types import PinType
from .units import quantize_clock, quantize_duration, ticks_to_ns


@dataclass(frozen=True)
class TimingRow:
    block: str
    key: str
    type: str
    start_tick: int | None  # delay, in ticks from RUN
    duration_tick: int | None  # None = free-running / not time-bounded
    summary: str  # human-readable achieved value + error


def summarize_mode(config: Config, mode: str) -> list[TimingRow]:
    rows: list[TimingRow] = []
    for block, key, setting in config.iter_settings(mode):
        rows.append(_summarize_setting(block, key, setting))
    return rows


def _delay_ticks(params: dict) -> int | None:
    if "delay" not in params:
        return 0
    return quantize_duration(params["delay"]).ticks


def _summarize_setting(block: str, key: str, setting) -> TimingRow:
    t = setting.type
    p = setting.params

    if t == DFT_HELPER_TYPE:
        sel = resolve_dft(p.get("adc"), p.get("signal"))
        return TimingRow(block, key, t, None, None,
                          f"adc={p.get('adc')} signal={p.get('signal')!r} -> "
                          f"b={sel.b_value:03b} s={sel.s_value:04b} (UNCONFIRMED)")

    if key in PIN_GROUPS:
        value = p.get("value")
        return TimingRow(block, key, t, 0, 0, f"value={value} over {PIN_GROUPS[key]}")

    if t == PinType.LOW.value:
        return TimingRow(block, key, t, 0, None, "constant 0")
    if t == PinType.HIGH.value:
        return TimingRow(block, key, t, 0, None, "constant 1")

    if t == PinType.CLOCK.value:
        q = quantize_clock(p.get("freq"), p.get("duty", "50%"))
        delay = _delay_ticks(p)
        cycles = p.get("cycles")
        duration = q.period_ticks * cycles if cycles else None
        cyc_str = f"{cycles} cycles" if cycles else "free-running"
        return TimingRow(
            block, key, t, delay, duration,
            f"requested {q.requested_hz/1e6:.4f} MHz -> achieved {q.achieved_hz/1e6:.4f} MHz "
            f"({q.error_pct:+.2f}%), N={q.period_ticks} ticks, {cyc_str}",
        )

    if t == PinType.PULSE.value:
        q = quantize_duration(p.get("width"))
        delay = _delay_ticks(p)
        pol = p.get("polarity", "active_high")
        repeat = p.get("repeat")
        rep_str = f", repeat={repeat}" if repeat else ""
        return TimingRow(
            block, key, t, delay, q.ticks,
            f"width {q.ticks} ticks ({q.achieved_ns:.0f} ns, {q.error_pct:+.2f}%), "
            f"polarity={pol}{rep_str}",
        )

    if t == PinType.SERIAL.value:
        bits = p.get("bits", 0)
        clock_key = p.get("clock")
        return TimingRow(block, key, t, _delay_ticks(p), None,
                          f"{bits} bits, msb_first={p.get('msb_first', True)}, "
                          f"data_edge={p.get('data_edge', '?')}, clocked by {clock_key!r}")

    if t == PinType.CAPTURE.value:
        mode_kind = p.get("mode", "level")
        if mode_kind == "serial":
            return TimingRow(block, key, t, None, None,
                              f"serial capture, {p.get('bits', 0)} bits, "
                              f"edge={p.get('edge', '?')}, clocked by {p.get('clock')!r}")
        return TimingRow(block, key, t, None, None, f"capture mode={mode_kind}")

    return TimingRow(block, key, t, None, None, "(unrecognized type)")


def format_timing_table(rows: list[TimingRow]) -> str:
    lines = ["| Block | Pin | Type | Start (ticks / ns) | Summary |",
             "|---|---|---|---|---|"]
    for r in rows:
        start = "-" if r.start_tick is None else f"{r.start_tick} / {ticks_to_ns(r.start_tick):.0f} ns"
        lines.append(f"| {r.block} | {r.key} | {r.type} | {start} | {r.summary} |")
    return "\n".join(lines)
