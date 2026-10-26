"""Time-accurate waveforms of one mode, for the browser editor's preview (gui.py).

Unlike preview.py (WaveDrom, one symbol per segment), this works out the real edges of
every configured input pin, in ticks from RUN (1 tick = 10 ns), using the same rules as
fpga/src/sig_cell.sv:
  - LOW / HIGH: constant while running.
  - PULSE: idles at its idle level (high for active_low), goes active at `delay` for
    `width`; with `repeat` > 1, again every `period`.
  - CLOCK: from `delay`, high for H ticks then low for N-H, `cycles` times (0/blank =
    for ever); starts in its high phase.
  - SERIAL: the first bit is on the pin from `delay`; each `data_edge` edge of its clock
    (after that) moves to the next bit, SERIAL_STROBE_LAG_TICKS after that edge; after the
    last one it goes back to 0.
  - BUS groups and the DFT helper: a constant value, drawn as a labelled bus.
Outputs (CAPTURE) are driven by the chip, not the FPGA, so they're listed as such.

The cells' fixed output latency from RUN is the same for every pin, so it is left out:
the drawing is RUN-relative and shows the timing *between* pins, which is what the
config sets. The one exception is a SERIAL pin's bit changes. They follow its clock's
edge strobe, which is registered (`falling_edge <= ...`), and the shift lands a tick after
that: 2 ticks (20 ns) after the clock pin's edge, measured in xsim on sig_cell.sv
(2026-10-26). So they are drawn 2 ticks after the edge. Only the part of the waveform inside [t0, t1] is returned; a lane with more
than MAX_EDGES edges in the window comes back as `dense` (the page shows a band and asks
to zoom in) instead of thousands of points.
"""
from __future__ import annotations

from .config import DFT_HELPER_TYPE, Config, PinSetting
from .dft_helper import resolve as resolve_dft
from .groups import PIN_GROUPS
from .units import TICK_NS, UnitsError, quantize_clock, quantize_duration

MAX_EDGES = 1500
SERIAL_STROBE_LAG_TICKS = 2   # SERIAL data changes this long after its clock pin's edge (sig_cell.sv)
DEFAULT_SPAN_TICKS = 1000  # 10 us when nothing in the mode bounds the time


class WaveError(ValueError):
    pass


def _ticks(v) -> int:
    return quantize_duration(v if v not in (None, "") else 0).ticks


def _clock_shape(p: dict) -> tuple[int, int, int, int]:
    """(delay, period, high, cycles) in ticks; cycles 0 = for ever."""
    q = quantize_clock(p.get("freq"), p.get("duty", "50%"))
    return _ticks(p.get("delay")), q.period_ticks, q.high_ticks, int(p.get("cycles") or 0)


def _natural_end(s: PinSetting) -> int | None:
    """Tick at which a setting stops changing, or None if it never does (free clock)."""
    p = s.params
    if s.type == "PULSE":
        repeat = int(p.get("repeat") or 1)
        start = _ticks(p.get("delay"))
        if repeat > 1:
            return start + (repeat - 1) * _ticks(p.get("period")) + _ticks(p.get("width"))
        return start + _ticks(p.get("width"))
    if s.type == "CLOCK":
        d, n, _h, c = _clock_shape(p)
        return d + n * c if c else None
    return _ticks(p.get("delay")) if s.type in ("SERIAL",) else 0


def _segments_from_edges(initial: int, edges: list[tuple[int, int]], t0: int, t1: int) -> list[list[int]]:
    """[[tick, level], ...] starting at t0 with the level in force there, then every
    change inside (t0, t1]. `edges` = sorted (tick, new_level)."""
    level = initial
    out: list[list[int]] = []
    for t, v in edges:
        if t <= t0:
            level = v
        else:
            break
    out.append([t0, level])
    for t, v in edges:
        if t0 < t <= t1 and v != out[-1][1]:
            out.append([t, v])
    return out


def _clock_edges(d: int, n: int, h: int, cycles: int, t0: int, t1: int, cap: int):
    """Edges of a clock inside [t0 - n, t1], or None if more than `cap`."""
    k0 = max(0, (t0 - d) // n - 1)
    k1 = (t1 - d) // n + 1
    if cycles:
        k1 = min(k1, cycles - 1)
    if k1 < k0:
        return [], d + n * cycles if cycles else None
    if 2 * (k1 - k0 + 1) > cap:
        return None, None
    edges = []
    for k in range(k0, k1 + 1):
        edges.append((d + k * n, 1))
        edges.append((d + k * n + h, 0))
    if cycles and k1 == cycles - 1:
        edges.append((d + cycles * n, 0))
    return edges, None


def _strobes(clock: PinSetting, edge: str, after: int, count: int) -> list[int]:
    """Ticks of the first `count` `edge` edges of `clock` at or after `after`."""
    d, n, h, c = _clock_shape(clock.params)
    off = h if edge == "falling" else 0
    k = max(0, -(-(after - d - off) // n))
    out = []
    while len(out) < count and (not c or k < c):
        out.append(d + k * n + off)
        k += 1
    return out


def mode_waves(config: Config, mode: str, t0_ns: float | None = None,
               t1_ns: float | None = None) -> dict:
    """{"t0", "t1", "end", "lanes": [...]} in ns. Each lane: {block, key, kind, label,
    idle, segments: [[t_ns, level|text], ...]} with kind "bit" | "bus" | "dense" |
    "output" | "error"; `idle` is the pin's level before RUN when it is known (pulses,
    clocks, serial), else None. Without t0/t1 the window is 0 .. 10 % past the last
    finite event."""
    blocks = config.modes.get(mode, {})
    settings = [(b, k, s) for b, kv in blocks.items() for k, s in kv.items()]
    clocks = {k: s for _b, k, s in settings if s.type == "CLOCK"}

    ends = []
    for _b, _k, s in settings:
        try:
            e = _natural_end(s)
        except (UnitsError, TypeError, ValueError):
            e = None
        if e:
            ends.append(e)
        if s.type == "SERIAL" and s.params.get("clock") in clocks:
            try:
                st = _strobes(clocks[s.params["clock"]], s.params.get("data_edge", "falling"),
                              _ticks(s.params.get("delay")), int(s.params.get("bits") or 0))
                if st:
                    ends.append(st[-1] + SERIAL_STROBE_LAG_TICKS)
            except (UnitsError, TypeError, ValueError):
                pass
    end = max(ends) if ends else 0
    if end == 0:
        free = [c for c in clocks.values()]
        try:
            end = max((_clock_shape(c.params)[1] * 8 for c in free), default=DEFAULT_SPAN_TICKS)
        except (UnitsError, TypeError, ValueError):
            end = DEFAULT_SPAN_TICKS
    t0 = 0 if t0_ns is None else max(0, int(t0_ns // TICK_NS))
    t1 = int(end * 1.1) + 1 if t1_ns is None else int(t1_ns // TICK_NS)
    if t1 <= t0:
        raise WaveError("the end of the window must be after its start")

    lanes = []
    for block, key, s in settings:
        try:
            lanes.append({"block": block, "key": key, "idle": _idle(s), **_lane(s, key, clocks, t0, t1)})
        except (UnitsError, TypeError, ValueError, KeyError) as exc:
            lanes.append({"block": block, "key": key, "idle": None, "kind": "error",
                          "label": str(exc), "segments": []})

    def ns(seg):
        return [[t * TICK_NS, v] for t, v in seg]
    for ln in lanes:
        ln["segments"] = ns(ln["segments"])
    # "finite": the mode has a last event; False -> "end" is only a display span (8 clock
    # periods) for free-running clocks / static levels (mode_seq.py then needs a duration)
    return {"t0": t0 * TICK_NS, "t1": t1 * TICK_NS, "end": end * TICK_NS, "lanes": lanes,
            "finite": bool(ends)}


def _idle(s: PinSetting) -> int | None:
    """The pin's level before RUN (sig_cell idles at its idle level): an active-low pulse
    idles high, pulses / clocks / serial otherwise low. None where the config alone
    doesn't say (LOW/HIGH constants, buses, outputs)."""
    if s.type == "PULSE":
        return 1 if s.params.get("polarity") == "active_low" else 0
    if s.type in ("CLOCK", "SERIAL"):
        return 0
    return None


def _lane(s: PinSetting, key: str, clocks: dict, t0: int, t1: int) -> dict:
    p = s.params
    if s.type == DFT_HELPER_TYPE:
        sel = resolve_dft(p.get("adc"), p.get("signal"))
        # the configured ADC, not b_value (equal only while the DFT table is the UNCONFIRMED
        # one); s drives 4 pins (s0..s3_dft), so 4 bits
        return {"kind": "bus", "label": f"ADC {p.get('adc')}, {p.get('signal')} (b={sel.b_value:03b}, s={sel.s_value:04b})",
                "segments": [[t0, f"b={sel.b_value:03b} s={sel.s_value:04b}"]]}
    if key in PIN_GROUPS or s.type == "BUS":
        v = p.get("value")
        n = len(PIN_GROUPS.get(key, []))
        txt = f"0b{int(v):0{n}b}" if isinstance(v, int) else str(v)
        return {"kind": "bus", "label": f"bus {', '.join(PIN_GROUPS.get(key, []))}", "segments": [[t0, txt]]}
    if s.type == "CAPTURE":
        return {"kind": "output", "label": f"chip output, captured ({p.get('mode', 'level')})", "segments": []}
    if s.type in ("LOW", "HIGH"):
        v = 1 if s.type == "HIGH" else 0
        return {"kind": "bit", "label": "constant " + str(v), "segments": [[t0, v]]}

    if s.type == "PULSE":
        active_low = p.get("polarity") == "active_low"
        idle, act = (1, 0) if active_low else (0, 1)
        d, w = _ticks(p.get("delay")), _ticks(p.get("width"))
        repeat = int(p.get("repeat") or 1)
        period = _ticks(p.get("period")) if repeat > 1 else 0
        if w < 1:
            raise WaveError("width is 0 ticks")
        edges = []
        for i in range(repeat):
            st = d + i * period
            edges += [(st, act), (st + w, idle)]
        label = f"pulse {w * TICK_NS:g} ns{', x' + str(repeat) if repeat > 1 else ''}"
        return {"kind": "bit", "label": label, "segments": _segments_from_edges(idle, edges, t0, t1)}

    if s.type == "CLOCK":
        d, n, h, c = _clock_shape(p)
        edges, _ = _clock_edges(d, n, h, c, t0, t1, MAX_EDGES)
        q = quantize_clock(p.get("freq"), p.get("duty", "50%"))
        label = f"{q.achieved_hz / 1e6:.4g} MHz" + (f", {c} cycles" if c else "")
        if edges is None:
            return {"kind": "dense", "label": label + " (too many edges here, zoom in)",
                    "segments": [[max(t0, d), "clock"]]}
        return {"kind": "bit", "label": label, "segments": _segments_from_edges(0, edges, t0, t1)}

    if s.type == "SERIAL":
        clk = clocks.get(p.get("clock"))
        if clk is None:
            raise WaveError(f"its clock {p.get('clock')!r} isn't a CLOCK in this mode")
        bits = int(p.get("bits") or 0)
        raw = p.get("data")
        try:
            value = int(raw, 0) if isinstance(raw, str) else int(raw)
        except (TypeError, ValueError):
            raise WaveError(f"data {raw!r} isn't a number (e.g. 0xA5)") from None
        if bits < 1:
            raise WaveError("needs bits >= 1")
        order = range(bits - 1, -1, -1) if p.get("msb_first", True) else range(bits)
        seq = [(value >> i) & 1 for i in order]
        d = _ticks(p.get("delay"))
        st = _strobes(clk, p.get("data_edge", "falling"), d, bits)
        edges = [(d, seq[0])]
        for i, t in enumerate(st):
            edges.append((t + SERIAL_STROBE_LAG_TICKS, seq[i + 1] if i + 1 < bits else 0))
        if sum(1 for t, _ in edges if t0 <= t <= t1) > MAX_EDGES:
            return {"kind": "dense", "label": f"{bits} bits (too many edges here, zoom in)",
                    "segments": [[max(t0, d), "data"]]}
        label = f"{bits} bits {'MSB' if p.get('msb_first', True) else 'LSB'} first on {p.get('clock')} {p.get('data_edge', 'falling')}"
        if len(st) < bits:
            label += f" (only {len(st)} clock edges: incomplete)"
        return {"kind": "bit", "label": label, "segments": _segments_from_edges(0, edges, t0, t1)}

    raise WaveError(f"unknown type {s.type!r}")
