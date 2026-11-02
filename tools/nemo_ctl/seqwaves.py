"""Verification plan Step 3: the expected waveforms of a step *sequence* (sequence.py YAML),
on the same time axis as a sampler record (samples.py: ns from RUN), and the check of a
record against them.

A sequence's timing after a wait step (`until: {captured: ...}` etc.) isn't known in
advance, so the step starts come from the record itself: sample_loopback_top records the
step number in bits 13:10 (samples.STEP_FIELD). Then, per sig cell:
  - step 0 is applied one tick before RUN (seen in fpga/tb/sample_loopback_top_tb.sv);
  - a step re-applies only the cells in its `set:`; the others keep running;
  - a cell's pin follows its new setting from APPLY + LATENCY_TICKS (sig_cell.sv's output
    latency), using waves.py's rules for that setting (same fields as an editor mode).
A step's start is read from the record only where the record shows the change into it
(to one sample: the first sample after it). A step that began before the record, or after
it, gets its start from its neighbours when they are fixed-length (`until: {after: T}`),
which the sequencer runs tick-exact. The check allows two sample periods plus the
synchronizer.
"""
from __future__ import annotations

from .config import PinSetting
from .samples import (LOOPBACK_PAIRS, Record, SampleSetup, STEP_FIELD, compare, decode,
                      record_window, sample_times_ns)
from .units import TICK_NS, UnitsError
from .verify import Row
from .waves import WaveError, _lane

LATENCY_TICKS = 2        # sig_cell: applied at tick A, its pin changes at A + 2 (+ delay)
STEP0_APPLY_NS = -TICK_NS


class SeqWaveError(ValueError):
    pass


def _after_ns(step: dict) -> float | None:
    """A fixed-length step's duration (ns), None for a wait step."""
    from .units import parse_duration_ns
    u = step.get("until") or {}
    return parse_duration_ns(u["after"]) if "after" in u else None


def step_starts(setup: SampleSetup, rec: Record, steps: list[dict] | None = None,
                field=STEP_FIELD) -> dict[int, float]:
    """step -> its APPLY time (ns from RUN). Seen in the record: the first sample after a
    change into it. Step 0: one tick before RUN. With `steps`, the starts not seen are filled
    in from known neighbours across fixed-length steps."""
    lo, n = field
    out: dict[int, float] = {0: STEP0_APPLY_NS}
    prev = None
    for t, w in zip(sample_times_ns(setup, rec), rec.words):
        k = (w >> lo) & ((1 << n) - 1)
        if prev is not None and k != prev and k not in out:
            out[k] = t
        prev = k
    if steps:
        changed = True
        while changed:
            changed = False
            for k in range(len(steps) - 1):
                d = _after_ns(steps[k])
                if d is None:
                    continue
                if k in out and k + 1 not in out:
                    out[k + 1] = out[k] + d
                    changed = True
                elif k + 1 in out and k not in out:
                    out[k] = out[k + 1] - d
                    changed = True
    return dict(sorted(out.items()))


def _setting(name: str, raw: dict) -> PinSetting:
    raw = dict(raw or {})
    t = str(raw.pop("type", "")).upper()
    if not t:
        raise SeqWaveError(f"{name}: no type")
    return PinSetting(key=name, type=t, params=raw)


def sequence_waves(steps: list[dict], starts_ns: dict[int, float], t_end_ns: float,
                   cells: list[str] | None = None) -> dict[str, list[list]]:
    """cell -> [[t_ns, level], ...] expected on its pin up to t_end_ns, for every sig cell
    set in step 0 (or just `cells`). Steps without a known start (not reached / outside
    the record) are left out, with the later ones."""
    known = []
    for k in range(len(steps)):
        if k not in starts_ns:
            break
        known.append(k)
    names = cells or list((steps[0].get("set") or {}).keys())
    out: dict[str, list[list]] = {}
    for name in names:
        pieces = [(starts_ns[k], k) for k in known if k == 0 or name in (steps[k].get("set") or {})]
        segs: list[list] = []
        for i, (a_ns, k) in enumerate(pieces):
            t_from = a_ns + LATENCY_TICKS * TICK_NS
            t_to = (pieces[i + 1][0] + LATENCY_TICKS * TICK_NS) if i + 1 < len(pieces) else t_end_ns
            if t_to <= t_from:
                continue
            sets = steps[k].get("set") or {}
            clocks = {}
            for cn, raw in sets.items():
                if str((raw or {}).get("type", "")).upper() == "CLOCK":
                    clocks[cn] = _setting(cn, raw)
            span = int((t_to - t_from) // TICK_NS) + 1
            try:
                lane = _lane(_setting(name, sets[name]), name, clocks, 0, span)
            except (WaveError, UnitsError, TypeError, ValueError, KeyError) as exc:
                raise SeqWaveError(f"step {k} ({steps[k].get('name', k)}) / {name}: {exc}") from None
            if lane["kind"] != "bit":
                raise SeqWaveError(f"step {k} / {name}: can't draw it ({lane['label']})")
            for t, v in lane["segments"]:
                tt = t_from + t * TICK_NS
                if tt < t_to and (not segs or segs[-1][1] != v):
                    segs.append([tt, v])
        out[name] = segs
    return out


def expected_for(steps: list[dict], setup: SampleSetup, rec: Record,
                 pairs: dict[str, str] | None = None) -> dict[str, list[list]]:
    """pin -> expected segments for every shown pin that has one (an input: its pair's)."""
    pairs = LOOPBACK_PAIRS if pairs is None else pairs
    starts = step_starts(setup, rec, steps)
    window = record_window(setup, rec)
    names = [n for n in sorted({pairs.get(p, p) for p in setup.pins}) if n in (steps[0].get("set") or {})]
    exp = sequence_waves(steps, starts, window[1] + setup.period_ns, names)
    return {p: exp[p if p in exp else pairs.get(p)] for p in setup.pins
            if p in exp or pairs.get(p) in exp}


def check_record(steps: list[dict], setup: SampleSetup, rec: Record,
                 pairs: dict[str, str] | None = None) -> list[Row]:
    """Rows (verify.Row): the steps seen, then each shown pin against its expected wave; an
    input is held to its paired output's expected wave (loopback, `pairs`)."""
    pairs = LOOPBACK_PAIRS if pairs is None else pairs
    if not rec.words:
        return [Row("(record)", "status", "samples", "none", False, "nothing recorded")]
    starts = step_starts(setup, rec, steps)
    window = record_window(setup, rec)
    seen = sorted(k for k in starts if k)
    rows = [Row("(steps)", "-", f"{len(steps)} steps", "starts: " +
                (", ".join(f"{k} at {starts[k] / 1e6:.6g} ms" for k in seen) or "none"), None,
                "seen in the record's step bits, or from the fixed-length steps")]
    need = sorted({pairs.get(p, p) for p in setup.pins})
    exp = sequence_waves(steps, starts, window[1] + setup.period_ns, [n for n in need if n in (steps[0].get("set") or {})])
    tol = 2 * setup.period_ns + 2 * TICK_NS
    got = decode(setup, rec)
    for pin in setup.pins:
        src = pin if pin in exp else pairs.get(pin)
        if src not in exp:
            rows.append(Row(pin, "-", "-", f"{len(got[pin]) - 1} edges", None, "no expected wave"))
            continue
        n_exp = sum(1 for t, _ in exp[src][1:] if window[0] < t < window[1])
        miss = compare(exp[src], got[pin], tol, window)
        what = f"{n_exp} edges" + ("" if src == pin else f" (as {src})")
        rows.append(Row(pin, "wave", what, f"{len(got[pin]) - 1} edges", not miss,
                        "; ".join(miss[:3]) + (f" (+{len(miss) - 3} more)" if len(miss) > 3 else "")))
    return rows


_TIME_KEYS = ("delay", "width", "period", "after", "timeout")


def scale_steps(steps: list[dict], scale: float) -> list[dict]:
    """A copy of raw steps with every time x scale and every frequency / scale: the same
    rule as sequence.compile_steps(scale=...), for the time-scaled simulation copies
    (gen_svh.py --time-scale)."""
    from copy import deepcopy
    from .units import parse_duration_ns, parse_freq_hz

    def fix(d: dict) -> None:
        for k, v in list(d.items()):
            if isinstance(v, dict):
                fix(v)
            elif k in _TIME_KEYS and v not in (None, ""):
                d[k] = f"{parse_duration_ns(v) * scale:.6g}ns"
            elif k == "freq" and v not in (None, ""):
                d[k] = f"{parse_freq_hz(v) / scale:.9g}Hz"
    out = deepcopy(steps)
    for st in out:
        fix(st)
    return out
