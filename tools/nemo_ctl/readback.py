"""Verification plan Step 2 (pad readback): what each chip_top output pin should have done
during a run, and the check of what the FPGA read back at its pads (link.SeqLink.read_readback).

chip_top's readback_cell (fpga/src/readback_cell.sv) records per output, over the run as the
pins saw it: rising edges, saw 0 / saw 1, the last period (rise to rise), the last high time
(rise to the fall after it) and the level at the end. This module derives the same numbers
from the run's steps, with seqwaves.sequence_waves (waves.py's rules, the ones sig_cell.sv
follows): nothing to type, the expectation is the setting itself.

Timing: fixed-length steps (`until: {after: T}`) run tick-exact. A step that waits for a
condition has no length in advance: the FPGA reports the window length (RB_INFO), so with
ONE wait step its length is the window minus the fixed steps. With more than one, the step
starts after the first wait aren't known and the pins aren't judged (shown only).

Tolerances: edges, saw 0 / 1 and the end level exact; period and high +-1 tick.
What it can't see (docs/plan_2026-11-01_verification.md Step 2): an open after the pad
(connector, board, wire, chip) and analog level / ringing.
"""
from __future__ import annotations

from dataclasses import dataclass

from .seqwaves import STEP0_APPLY_NS, SeqWaveError, sequence_waves
from .units import TICK_NS, UnitsError, parse_duration_ns
from .verify import Row

PERIOD_TOL_TICKS = 1


@dataclass(frozen=True)
class PinStats:
    edges: int
    period: int     # ticks, 0 = fewer than two rising edges
    high: int       # ticks, 0 = no complete high pulse
    saw0: bool
    saw1: bool
    end: int

    def text(self) -> str:
        saw = "/".join(v for v, s in (("0", self.saw0), ("1", self.saw1)) if s) or "-"
        t = f"edges {self.edges}, saw {saw}, end {self.end}"
        if self.period:
            t += f", period {self.period}"
        if self.high:
            t += f", high {self.high}"
        return t


def _initial(raw: dict) -> int:
    """The pin before RUN: step 0 preloaded with RUN low = its setting's idle level."""
    t = str((raw or {}).get("type", "")).upper()
    if t == "HIGH":
        return 1
    if t == "PULSE":
        return 1 if (raw or {}).get("polarity") == "active_low" else 0
    return 0                                  # LOW, CLOCK, SERIAL


def stats_from_segments(segs: list[list], initial: int, window_ticks: int) -> PinStats:
    """readback_cell's numbers for a pin that starts at `initial` and follows `segs`
    ([[t_ns, level], ...] from RUN) over a window of `window_ticks` ticks."""
    level = initial
    edges = period = high = 0
    last_rise = prev_rise = None
    saw = {initial}
    for t_ns, v in segs:
        t = int(round(t_ns / TICK_NS))
        if t >= window_ticks:
            break
        if v == level:
            continue
        if v == 1:
            edges += 1
            prev_rise, last_rise = last_rise, max(t, 0)
            if prev_rise is not None:
                period = last_rise - prev_rise
        elif last_rise is not None:
            high = max(t, 0) - last_rise
        level = v
        saw.add(v)
    return PinStats(edges, period, high, 0 in saw, 1 in saw, level)


def _after_ns(step: dict) -> float | None:
    u = (step or {}).get("until") or {}
    return parse_duration_ns(u["after"]) if "after" in u else None


def step_starts(steps: list[dict], window_ticks: int) -> dict[int, float] | None:
    """step -> APPLY time (ns from RUN), from the fixed lengths and the window. None if more
    than one step has no fixed length (their starts can't be told apart)."""
    try:
        lens = [_after_ns(s) for s in steps]
    except UnitsError as exc:
        raise SeqWaveError(str(exc)) from None
    waits = [k for k, d in enumerate(lens) if d is None]
    if len(waits) > 1:
        return None
    if waits:
        k = waits[0]
        lens[k] = max(0.0, window_ticks * TICK_NS - sum(d for d in lens if d is not None))
    starts, t = {}, STEP0_APPLY_NS
    for k, d in enumerate(lens):
        starts[k] = t
        t += d
    return starts


def expected_readback(steps: list[dict], cells: list[str], window_ticks: int) -> tuple[dict[str, PinStats], list[str]]:
    """pin -> expected PinStats for every sig cell in `cells` that step 0 sets, and notes."""
    notes: list[str] = []
    starts = step_starts(steps, window_ticks)
    if starts is None:
        return {}, ["more than one step waits for a condition: their lengths can't be told "
                    "apart, so the readback is shown, not judged"]
    set0 = (steps[0] or {}).get("set") or {}
    names = [c for c in cells if c in set0]
    waves = sequence_waves(steps, starts, window_ticks * TICK_NS, names)
    out = {n: stats_from_segments(waves[n], _initial(set0[n]), window_ticks) for n in names}
    return out, notes


def expected_sipo(steps: list[dict], cell: str = "sipo_in") -> tuple[int, int] | None:
    """(bits, frame as sent MSB first) of the last step that sets `cell` to SERIAL, or None."""
    for s in reversed(steps):
        raw = ((s or {}).get("set") or {}).get(cell)
        if raw and str(raw.get("type", "")).upper() == "SERIAL":
            bits = int(raw.get("bits") or 0)
            v = raw.get("data")
            value = int(v, 0) if isinstance(v, str) else int(v)
            if not raw.get("msb_first", True):          # sent LSB first: as received, reversed
                value = int(format(value, f"0{bits}b")[::-1], 2)
            return bits, value
    return None


def _close(a: int, b: int) -> bool:
    return abs(a - b) <= PERIOD_TOL_TICKS


def check_readback(steps: list[dict], cells: list[str], rb: dict | None,
                   sipo_cell: str = "sipo_in", sipo_clock: str = "clk_sipo") -> list[Row]:
    """Rows (verify.Row, kind "readback"): one per output pin, then the sipo_in frame.
    `rb` is SeqLink.read_readback()'s answer (None = this bitstream has no readback)."""
    if rb is None:
        return [Row("(readback)", "readback", "-", "-", None,
                     "this bitstream has no pad readback (rebuild chip_top, Step 2)")]
    where = "at the pads" if rb["pad"] else "from the output registers (no pads: vchip_top)"
    rows = [Row("(readback)", "readback", "-", f"{len(rb['cells'])} pins {where}, window "
                f"{rb['window']} ticks ({rb['window'] * TICK_NS / 1000:g} us)", None)]
    try:
        exp, notes = expected_readback(steps, cells, rb["window"])
    except (SeqWaveError, UnitsError, ValueError, TypeError, KeyError) as exc:
        return rows + [Row("(readback)", "readback", "-", "-", False, f"can't derive the expected readback: {exc}")]
    for pin in cells:
        got = rb["cells"].get(pin)
        if got is None:
            continue
        g = PinStats(got["edges"], got["period"], got["high"], got["saw0"], got["saw1"], got["end"])
        e = exp.get(pin)
        if e is None:
            rows.append(Row(pin, "readback", "-", g.text(), None, "; ".join(notes) or "not set in step 0"))
            continue
        diffs = [k for k in ("edges", "saw0", "saw1", "end") if getattr(g, k) != getattr(e, k)]
        diffs += [k for k in ("period", "high") if not _close(getattr(g, k), getattr(e, k))]
        rows.append(Row(pin, "readback", e.text(), g.text(), not diffs,
                        "" if not diffs else "differs: " + ", ".join(diffs)))
    want = expected_sipo(steps, sipo_cell)
    if want and rb.get("sipo_width"):
        bits, frame = want
        n_exp = exp[sipo_clock].edges if sipo_clock in exp else None
        width = rb["sipo_width"]
        got = rb["sipo"] & ((1 << min(bits, width)) - 1)
        ok_n = n_exp is None or rb["sipo_bits"] == n_exp
        ok_v = bits > width or rb["sipo_bits"] < bits or got == frame & ((1 << bits) - 1)
        note = []
        if not ok_n:
            note.append(f"{rb['sipo_bits']} bits sampled, {n_exp} expected")
        if not ok_v:
            d = got ^ frame
            note.append(f"{bin(d).count('1')} bit(s) wrong")
        rows.append(Row(f"{sipo_cell} frame", "readback", f"{bits} bits 0x{frame:0{(bits + 3) // 4}X}",
                        f"{rb['sipo_bits']} bits 0x{got:0{(min(bits, width) + 3) // 4}X}",
                        ok_n and ok_v, "; ".join(note)))
    return rows
