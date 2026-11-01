"""Verification plan Step 3 (docs/plan_2026-11-01_verification.md): the PC side of
fpga/src/sample_cell.sv, the in-FPGA logic analyser.

  setup   what to record: pins, rate, length, pre-trigger samples, trigger. Checked against
          the cell's buffer (DEPTH samples) and quantized to its config ports (cfg_div ...).
  decode  the words read back (one per sample, bit k = setup.pins[k]) -> per-pin waveforms
          on the same time axis as waves.py (ns from RUN), using the cell's trig_idx /
          trig_count.
  compare a decoded pin against the expected waves.py lane: every expected edge inside the
          record must be seen within the tolerance (default: one sample period plus the
          input synchronizer), and every seen edge must be expected.

Time of sample i (sample_cell.sv header): (trig_count - trig_idx + i) * div + 1 ticks after
the cell's run rose; the pin value it holds is SYNC_TICKS older (2-FF synchronizer).
Measured in fpga/tb/sample_loopback_top_tb.sv (2026-11-01): every word read over the link
is the cell's input on exactly that tick, and the input is the pins 2 ticks earlier, so the
formula holds with "after the cell's run rose" = the tick the sequencer's run goes high
(step 0's APPLY is one tick before). `offset_ticks` moves the axis (e.g. to a step's start).

Wiring: a top level records a fixed list of pins (LOOPBACK_PINS for sample_loopback_top:
bit k = LOOPBACK_PINS[k]); a setup picks which of them to decode and show. Link side:
link.SeqLink.sampler_* (registers 0x0020.., samples 0x4000.., docs/link_register_map.md).
Not on hardware yet.
"""
from __future__ import annotations

from dataclasses import dataclass

from .units import TICK_NS, UnitsError, parse_duration_ns, parse_freq_hz

DEPTH = 4096          # sample_cell DEPTH in the planned test top
SYNC_TICKS = 2        # 2-FF input synchronizer in front of the cell
TRIGGERS = {"now": 0, "ext": 1, "rise": 2, "fall": 3, "high": 4, "low": 5}
# sample_loopback_top (phase7_link_top SAMPLER=1): bits 0-4 the outputs, 5-9 the inputs
LOOPBACK_PINS = ("clk", "rst", "data", "cs", "en", "clk_in", "rst_in", "data_in", "cs_in", "en_in")
EDGE_TRIGGERS = ("rise", "fall", "high", "low")


class SampleError(ValueError):
    pass


@dataclass(frozen=True)
class SampleSetup:
    pins: tuple[str, ...]   # the pins to decode / show
    bits: tuple[int, ...]   # bit of each of them in a sample word (the top's wiring)
    div: int                # ticks per sample (cfg_div)
    n: int                  # samples (cfg_n)
    pre: int                # pre-trigger samples (cfg_pre)
    trigger: str            # TRIGGERS key
    trig_pin: str | None    # for rise / fall / high / low
    trig_bit: int = 0       # its bit in the word (cfg_trig_pin)
    trig_step: int = 0      # for ext: the step whose start triggers

    @property
    def period_ns(self) -> float:
        return self.div * TICK_NS

    @property
    def span_ns(self) -> float:
        return self.n * self.period_ns

    def cfg(self) -> dict:
        """The cell's config port values."""
        return {"cfg_div": self.div, "cfg_n": self.n, "cfg_pre": self.pre,
                "cfg_trig": TRIGGERS[self.trigger], "cfg_trig_pin": self.trig_bit,
                "trig_step": self.trig_step}

    def summary(self) -> str:
        t = {"now": "now", "ext": f"at the start of step {self.trig_step}"}.get(
            self.trigger, f"{self.trigger} on {self.trig_pin}")
        return (f"{len(self.pins)} pins, every {_fmt(self.period_ns)} ({1e3 / self.period_ns:g} MHz), "
                f"{self.n} samples = {_fmt(self.span_ns)}, {self.pre} before the trigger ({t})")


def _fmt(ns: float) -> str:
    for unit, scale in (("ms", 1e6), ("us", 1e3)):
        if abs(ns) >= scale:
            return f"{ns / scale:g} {unit}"
    return f"{ns:g} ns"


def make_setup(params: dict, available: list[str], n_bits: int = 32,
               depth: int = DEPTH) -> SampleSetup:
    """params: {pins: [...], rate: "10MHz" | period: "100ns", samples: 2048, pre: 0,
    trigger: now|ext|rise|fall|high|low, on: <pin> (edge / level), step: <k> (ext)}.
    `available`: the pins the top wires to the cell, in bit order (bit k = available[k])."""
    pins = params.get("pins") or []
    if isinstance(pins, str):
        pins = [p.strip() for p in pins.split(",") if p.strip()]
    if not pins:
        raise SampleError("pick at least one pin to sample")
    unknown = [p for p in pins if p not in available]
    if unknown:
        raise SampleError(f"can't sample {unknown}: not wired to the sample cell ({available})")
    if len(set(pins)) != len(pins):
        raise SampleError("a pin is listed twice")
    if len(available) > n_bits:
        raise SampleError(f"{len(available)} pins wired, the cell records {n_bits}")
    has_rate, has_period = params.get("rate") not in (None, ""), params.get("period") not in (None, "")
    if has_rate == has_period:
        raise SampleError("give either rate (e.g. 10MHz) or period (e.g. 100ns)")
    try:
        ns = 1e9 / parse_freq_hz(params["rate"]) if has_rate else parse_duration_ns(params["period"])
    except (UnitsError, ZeroDivisionError) as exc:
        raise SampleError(f"bad sample rate: {exc}") from None
    div = round(ns / TICK_NS)
    if div < 1:
        raise SampleError(f"{_fmt(ns)} per sample is faster than the 100 MHz tick (max 100 MHz)")
    if abs(div * TICK_NS - ns) > 1e-6 * ns:
        raise SampleError(f"{_fmt(ns)} per sample isn't a whole number of 10 ns ticks "
                          f"(nearest: {_fmt(div * TICK_NS)})")
    try:
        n = int(params.get("samples", depth))
        pre = int(params.get("pre") or 0)
    except (TypeError, ValueError):
        raise SampleError("samples and pre must be whole numbers") from None
    if not 1 <= n <= depth:
        raise SampleError(f"samples={n}: the buffer holds 1..{depth}")
    if not 0 <= pre < n:
        raise SampleError(f"pre={pre} must be 0..samples-1 ({n - 1})")
    trig = str(params.get("trigger", "now")).lower()
    if trig not in TRIGGERS:
        raise SampleError(f"trigger {trig!r}: one of {', '.join(TRIGGERS)}")
    on = params.get("on")
    step = params.get("step")
    if trig == "ext":
        try:
            step = int(step)
        except (TypeError, ValueError):
            raise SampleError("trigger ext needs `step: <k>` (the step whose start triggers)") from None
        if not 0 <= step <= 255:
            raise SampleError(f"step {step} must be 0..255")
    elif step not in (None, ""):
        raise SampleError(f"`step` is only for trigger ext, not {trig}")
    if trig in EDGE_TRIGGERS:
        if not on:
            raise SampleError(f"trigger {trig} needs `on: <pin>`")
        if on not in available:
            raise SampleError(f"trigger pin {on!r} is not wired to the sample cell ({list(available)})")
    elif on:
        raise SampleError(f"trigger {trig} has no pin (`on` is only for {', '.join(EDGE_TRIGGERS)})")
    if trig == "now" and pre:
        raise SampleError("trigger now has no samples before it: set pre to 0")
    edge = trig in EDGE_TRIGGERS
    return SampleSetup(tuple(pins), tuple(available.index(p) for p in pins), div, n, pre, trig,
                       on if edge else None, available.index(on) if edge else 0,
                       step if trig == "ext" else 0)


@dataclass(frozen=True)
class Record:
    """What the cell returns: the words (logical order) and its status."""
    words: tuple[int, ...]
    trig_idx: int
    trig_count: int
    done: bool = True
    triggered: bool = True


def sample_times_ns(setup: SampleSetup, rec: Record, offset_ticks: int = 0) -> list[float]:
    """Time (ns from RUN) of the pin values in each sample of the record."""
    base = rec.trig_count - rec.trig_idx
    return [((base + i) * setup.div + 1 - SYNC_TICKS + offset_ticks) * TICK_NS
            for i in range(len(rec.words))]


def decode(setup: SampleSetup, rec: Record, offset_ticks: int = 0) -> dict[str, list[list]]:
    """pin -> [[t_ns, level], ...] (one entry per change, the first at the first sample),
    the same shape as a waves.py `bit` lane's segments."""
    times = sample_times_ns(setup, rec, offset_ticks)
    out: dict[str, list[list]] = {}
    for pin, bit in zip(setup.pins, setup.bits):
        segs: list[list] = []
        for t, w in zip(times, rec.words):
            v = (w >> bit) & 1
            if not segs or segs[-1][1] != v:
                segs.append([t, v])
        out[pin] = segs
    return out


def words_from_bytes(data: bytes, n_bits: int = 32) -> list[int]:
    """Little-endian words as the link would return them (n_bits rounded up to bytes)."""
    w = (n_bits + 7) // 8
    if len(data) % w:
        raise SampleError(f"{len(data)} bytes isn't a whole number of {w}-byte samples")
    return [int.from_bytes(data[i:i + w], "little") for i in range(0, len(data), w)]


def _edges(segs: list[list]) -> list[tuple[float, int]]:
    """(time, new level) of every change after the first segment."""
    return [(t, int(v)) for t, v in segs[1:]]


def _level_at(segs: list[list], t: float) -> int | None:
    """Level of a lane at t; before its first segment, its first level (waves.py lanes start
    at the window start, and a record may start a tick or two before RUN)."""
    if not segs:
        return None
    lvl = int(segs[0][1])
    for ts, v in segs:
        if ts <= t + 1e-9:
            lvl = int(v)
        else:
            break
    return lvl


def record_window(setup: SampleSetup, rec: Record, offset_ticks: int = 0) -> tuple[float, float]:
    """(first, last) sample time of the record, ns from RUN."""
    if not rec.words:
        raise SampleError("empty record")
    t = sample_times_ns(setup, rec, offset_ticks)
    return t[0], t[-1]


def compare(expected: list[list], seen: list[list], tol_ns: float,
            window: tuple[float, float]) -> list[str]:
    """Mismatches between an expected waves.py bit lane and a decoded pin, inside the
    record's window (record_window: its first and last SAMPLE, not its last change, so a
    pin that never moved is still judged over the whole record). Empty list = they agree."""
    if not seen:
        return ["nothing recorded"]
    lo, hi = window
    out: list[str] = []
    want_start = _level_at(expected, lo)
    if want_start is not None and want_start != int(seen[0][1]):
        # a start level next to an expected edge is that edge's tolerance, not a mismatch
        if not any(abs(t - lo) <= tol_ns for t, _ in _edges(expected)):
            out.append(f"at {_fmt(lo)} (record start): {seen[0][1]}, expected {want_start}")
    # edges within one tolerance of either end can't be judged (the matching edge may lie
    # just outside the record), for expected and seen edges alike
    exp_e = [(t, v) for t, v in _edges(expected) if lo + tol_ns < t < hi - tol_ns]
    got_e = [(t, v) for t, v in _edges(seen) if lo <= t <= hi]   # all of them can match
    used = set()
    for t, v in exp_e:
        k = next((i for i, (tg, vg) in enumerate(got_e)
                  if i not in used and vg == v and abs(tg - t) <= tol_ns), None)
        if k is None:
            out.append(f"{'rising' if v else 'falling'} edge expected at {_fmt(t)} not seen "
                       f"within {_fmt(tol_ns)}")
        else:
            used.add(k)
    for i, (t, v) in enumerate(got_e):
        if i not in used and lo + tol_ns < t < hi - tol_ns:
            out.append(f"unexpected {'rising' if v else 'falling'} edge at {_fmt(t)}")
    return out


def to_csv(setup: SampleSetup, rec: Record, offset_ticks: int = 0) -> str:
    """One row per sample: time in ns from RUN, then one 0/1 column per pin."""
    lines = ["t_ns," + ",".join(setup.pins)]
    for t, w in zip(sample_times_ns(setup, rec, offset_ticks), rec.words):
        lines.append(f"{t:g}," + ",".join(str((w >> b) & 1) for b in setup.bits))
    return "\n".join(lines) + "\n"


def to_vcd(setup: SampleSetup, rec: Record, offset_ticks: int = 0, module: str = "fpga") -> str:
    """The record as a VCD file (GTKWave / PulseView / Vivado's waveform viewer), 1 ns
    timescale, time 0 = the first sample (its time from RUN is in the header comment)."""
    if not rec.words:
        raise SampleError("empty record")
    times = sample_times_ns(setup, rec, offset_ticks)
    ids = [chr(33 + k) for k in range(len(setup.pins))]
    out = [f"$comment sample_cell record: {setup.summary()}; first sample at {times[0]:g} ns "
           f"from RUN $end", "$timescale 1ns $end", f"$scope module {module} $end"]
    out += [f"$var wire 1 {i} {p} $end" for i, p in zip(ids, setup.pins)]
    out += ["$upscope $end", "$enddefinitions $end"]
    prev: list[int | None] = [None] * len(setup.pins)
    for t, w in zip(times, rec.words):
        vals = [(w >> b) & 1 for b in setup.bits]
        ch = [f"{v}{i}" for v, i, pv in zip(vals, ids, prev) if v != pv]
        if ch:
            out.append(f"#{round(t - times[0])}")
            out += ch
        prev = vals
    out.append(f"#{round(times[-1] - times[0] + setup.period_ns)}")
    return "\n".join(out) + "\n"


def default_tol_ns(setup: SampleSetup) -> float:
    """One sample period plus the synchronizer, the cell's time resolution."""
    return setup.period_ns + SYNC_TICKS * TICK_NS
