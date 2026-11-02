"""Verification plan Step 1 (docs/plan_2026-11-01_verification.md): run a mode on chip_top
and check every capture against what the config says it should be.

The expected value is part of the CAPTURE setting itself, next to its mode:

    sipo_out:  {type: CAPTURE, mode: level, expect: 0}
    dft1_buff: {type: CAPTURE, mode: period, expect: 1us, tolerance: 1%}
    piso_out:  {type: CAPTURE, mode: serial, clock: clk_piso, bits: 168, edge: falling,
                expect: "0x...", mask: "0x..."}

What each kind compares (cap_cell.sv, read back by mode_seq.run_table after the run):
  level   the pin's level when read, i.e. after the run (0/1, LOW/HIGH)
  period  the last measured rising-to-rising period; expect a time or a frequency;
          tolerance "1%" (relative), a time ("20ns") or a number of ticks (default 1 tick)
  serial  the captured bits; mask (1 = checked, default all `bits`); a 168-bit piso_out
          mismatch is named per PISO stage and field (sipo_piso.decode_piso_frame)
  edge_count  NOT checkable: cap_cell.sv clears its edge count when RUN drops, and the
          captures are read after the run, so it always reads 0. An expect there is
          refused (docs/issues.md 2026-11-02); use period (a clock) or serial instead.

A capture without `expect` is still read and shown, but not judged. mode_seq.py ignores
these fields, so a mode with expectations runs exactly like one without.

A step sequence (sequence.py YAML, target chip_top) can carry the same fields on a step's
`capture:` entry; `cli verify --seq <file>` runs it (EXP-08's PISO readback needs `shift`
raised between the load and the read, which a single editor mode can't do).
"""
from __future__ import annotations

import csv
import io
from dataclasses import dataclass, field

from .config import Config
from .units import TICK_NS, UnitsError, parse_duration_ns, parse_freq_hz

EXPECT_KEYS = ("expect", "tolerance", "mask")
_KINDS = {"level": "level", "edge_count": "edges", "edges": "edges",
          "period": "period", "frequency": "period", "serial": "serial"}
PISO_PIN, PISO_BITS = "piso_out", 168
EDGES_NOT_CHECKABLE = ("an edge_count capture can't be checked: the cell clears its count when "
                       "the run ends, and verify reads after the run, so it always reads 0 "
                       "(use mode period for a clock, or serial)")


class VerifyError(ValueError):
    pass


@dataclass(frozen=True)
class Expectation:
    pin: str
    block: str
    kind: str            # level / period / serial (edge_count is refused, see EDGES_NOT_CHECKABLE)
    value: int | float   # level 0/1, period in ticks, serial bits as int
    tol: float = 0.0     # period: absolute, in ticks; level / serial: unused
    bits: int = 0        # serial width
    mask: int = 0        # serial: 1 = checked
    msb_first: bool = True
    text: str = ""       # what the config said, for the table

    def expected_text(self) -> str:
        if self.kind == "serial":
            t = _hex(self.value, self.bits)
            return t if self.mask == (1 << self.bits) - 1 else f"{t} mask {_hex(self.mask, self.bits)}"
        if self.kind == "period":
            return f"{self.text} ({self.value:g} +- {self.tol:g} ticks)"
        return str(self.value)


def _hex(v: int, bits: int) -> str:
    return f"0x{v:0{max(1, (bits + 3) // 4)}X}"


def _int(raw, what: str) -> int:
    if isinstance(raw, bool):
        raise VerifyError(f"{what} {raw!r} is not a number")
    if isinstance(raw, int):
        return raw
    try:
        return int(str(raw).strip().replace("_", ""), 0)
    except ValueError:
        raise VerifyError(f"{what} {raw!r} is not a number (e.g. 136, 0xA5, 0b101)") from None


def _period_ticks(raw) -> float:
    s = str(raw).strip()
    try:
        if s.lower().endswith("hz"):
            hz = parse_freq_hz(s)
            if hz <= 0:
                raise VerifyError(f"expect {raw!r}: frequency must be > 0")
            return 1e9 / hz / TICK_NS
        ns = parse_duration_ns(raw)
    except UnitsError as exc:
        raise VerifyError(f"expect {raw!r}: not a time or a frequency ({exc})") from None
    if ns <= 0:
        raise VerifyError(f"expect {raw!r}: period must be > 0")
    return ns / TICK_NS


def _period_tol(raw, period_ticks: float) -> float:
    if raw is None:
        return 1.0
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        return float(raw)                                  # ticks
    s = str(raw).strip()
    try:
        if s.endswith("%"):
            return period_ticks * float(s[:-1]) / 100.0
        if s.replace(".", "", 1).isdigit():
            return float(s)                                # ticks
        return parse_duration_ns(s) / TICK_NS
    except (UnitsError, ValueError):
        raise VerifyError(f"tolerance {raw!r}: use a percentage (1%), a time (20ns) or ticks") from None


def parse_expect(pin: str, block: str, params: dict) -> Expectation | None:
    """The expectation of one CAPTURE setting, or None if it has no `expect`.
    Raises VerifyError with a message for the editor / validator."""
    if params.get("expect") is None or params.get("expect") == "":
        for k in ("tolerance", "mask"):
            if params.get(k) not in (None, ""):
                raise VerifyError(f"{k} without expect")
        return None
    raw = params["expect"]
    kind = _KINDS.get(str(params.get("mode", "level")).lower())
    if kind is None:
        raise VerifyError(f"unknown capture mode {params.get('mode')!r}")
    tol_raw = params.get("tolerance")
    if tol_raw == "":
        tol_raw = None
    if kind == "level":
        s = str(raw).strip().upper()
        lvl = {"0": 0, "1": 1, "LOW": 0, "HIGH": 1, "FALSE": 0, "TRUE": 1}.get(s)
        if lvl is None:
            raise VerifyError(f"expect {raw!r}: a level is 0 / 1 (or LOW / HIGH)")
        if tol_raw is not None:
            raise VerifyError("a level has no tolerance")
        return Expectation(pin, block, kind, lvl, text=str(raw))
    if kind == "edges":
        raise VerifyError(EDGES_NOT_CHECKABLE)
    if kind == "period":
        ticks = _period_ticks(raw)
        tol = _period_tol(tol_raw, ticks)
        if tol < 0:
            raise VerifyError("tolerance must be >= 0")
        return Expectation(pin, block, kind, ticks, tol=tol, text=str(raw))
    # serial
    bits = params.get("bits")
    try:
        bits = int(bits)
    except (TypeError, ValueError):
        raise VerifyError("a serial expect needs the capture's `bits`") from None
    if bits <= 0:
        raise VerifyError("bits must be > 0")
    value = _int(raw, "expect")
    full = (1 << bits) - 1
    mask = full if params.get("mask") in (None, "") else _int(params["mask"], "mask")
    if not 0 <= value <= full:
        raise VerifyError(f"expect {raw!r} doesn't fit in {bits} bits")
    if not 0 <= mask <= full:
        raise VerifyError(f"mask {params['mask']!r} doesn't fit in {bits} bits")
    if tol_raw is not None:
        raise VerifyError("a serial capture has no tolerance (use mask for don't-care bits)")
    return Expectation(pin, block, kind, value, bits=bits, mask=mask,
                       msb_first=bool(params.get("msb_first", True)), text=str(raw))


def mode_expectations(config: Config, mode: str) -> dict[str, Expectation]:
    """pin -> expectation for every CAPTURE in `mode` that has an `expect`."""
    out: dict[str, Expectation] = {}
    for block, key, s in config.iter_settings(mode):
        if s.type != "CAPTURE":
            continue
        try:
            e = parse_expect(key, block, s.params)
        except VerifyError as exc:
            raise VerifyError(f"{mode}/{block}/{key}: {exc}") from None
        if e is not None:
            out[key] = e
    return out


def sequence_expectations(raw_steps: list[dict]) -> dict[str, Expectation]:
    """pin -> expectation from a step sequence (sequence.py YAML `steps`): `expect` sits on
    a step's `capture:` entry, e.g. `piso_out: {mode: SERIAL, bits: 168, expect: "0x..."}`.
    The value read after the run is the one armed by the *last* step that captures that cell,
    so an expect on an earlier step that a later step re-arms is an error."""
    out: dict[str, Expectation] = {}
    last: dict[str, str] = {}
    for k, raw in enumerate(raw_steps or []):
        name = (raw or {}).get("name", f"step {k}")
        for pin, s in ((raw or {}).get("capture") or {}).items():
            if pin in out and out[pin].block != name:
                raise VerifyError(f"step {name!r} re-arms {pin}, so the expect on step "
                                  f"{out[pin].block!r} is never what is read back: put it on {name!r}")
            last[pin] = name
            try:
                e = parse_expect(pin, name, dict(s or {}))
            except VerifyError as exc:
                raise VerifyError(f"step {name!r} / {pin}: {exc}") from None
            if e is not None:
                out[pin] = e
    return out


def load_verify_sequence(path):
    """(StepTable for chip_top, expectations, step-run margin in s) from a sequence YAML.
    The margin covers every wait step's timeout (run_table only adds the fixed steps)."""
    import yaml
    from .sequence import SequenceError, chip_target, compile_steps
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    if doc.get("target") != "chip_top":
        raise SequenceError(f"{path}: verify runs on chip_top / vchip_top; the file says "
                            f"target {doc.get('target')!r}")
    steps = doc.get("steps") or []
    expect = sequence_expectations(steps)
    table = compile_steps(steps, chip_target())
    waits = sum(st.timeout for st in table.steps if st.cond != 0) / 1e8
    return table, expect, 2.0 + waits


# ---- comparing ----

@dataclass
class Row:
    pin: str
    kind: str                # level / period / serial / status / "-" (not judged)
    expected: str
    measured: str
    ok: bool | None          # None = shown, not judged
    note: str = ""


def _serial_note(e: Expectation, got: int) -> str:
    diff = (got ^ e.value) & e.mask
    n = bin(diff).count("1")
    if e.pin == PISO_PIN and e.bits == PISO_BITS:
        from .sipo_piso import decode_piso_frame
        want, have = decode_piso_frame(e.value), decode_piso_frame(got)
        mask_st = decode_piso_frame(e.mask)
        parts = []
        for k, (w, h, m) in enumerate(zip(want, have, mask_st)):
            for f in ("out1", "tdc_out1", "out0", "tdc_out0"):
                d = (getattr(w, f) ^ getattr(h, f)) & getattr(m, f)
                if d:
                    idx = [i for i in range(d.bit_length()) if d >> i & 1]
                    parts.append(f"PISO{k} {f} bit{'s' if len(idx) > 1 else ''} "
                                 f"{','.join(map(str, idx[:6]))}{'...' if len(idx) > 6 else ''}")
        return f"{n} bit{'s' if n != 1 else ''} wrong: " + "; ".join(parts)
    idx = [i for i in range(diff.bit_length()) if diff >> i & 1]
    return (f"{n} bit{'s' if n != 1 else ''} wrong (bit {','.join(map(str, idx[:8]))}"
            f"{'...' if len(idx) > 8 else ''})")


def check_capture(e: Expectation, cap: dict, cap_w: int) -> Row:
    """One capture (a dict from mode_seq.run_table) against its expectation."""
    if e.kind == "level":
        got = int(cap["level"])
        return Row(e.pin, e.kind, e.expected_text(), str(got), got == e.value)
    if e.kind == "period":
        got = int(cap["period"])
        ok = got > 0 and abs(got - e.value) <= e.tol + 1e-9
        note = "" if got else "no period measured (fewer than 2 rising edges)"
        return Row(e.pin, e.kind, e.expected_text(), f"{got} ticks ({got * TICK_NS:g} ns)", ok, note)
    raw = cap.get("capture")
    if raw is None:
        return Row(e.pin, e.kind, e.expected_text(), "-", False, "no capture register read")
    reg = int(raw, 16) if isinstance(raw, str) else int(raw)
    if e.bits < cap_w and not e.msb_first:      # cap_cell.sv: lsb_first partial captures sit at the top
        reg >>= cap_w - e.bits
    got = reg & ((1 << e.bits) - 1)
    ok = (got ^ e.value) & e.mask == 0
    return Row(e.pin, e.kind, e.expected_text(), _hex(got, e.bits), ok, "" if ok else _serial_note(e, got))


def _shown_only(cap: dict) -> Row:
    m = f"level {cap['level']}, edges {cap['edges']}, period {cap['period']} ticks"
    if "capture" in cap:
        m += f", capture {cap['capture']}"
    return Row(cap["name"], "-", "-", m, None, "no expect set")


def check_run(expect: dict[str, Expectation], run: dict, cap_widths: dict[str, int]) -> list[Row]:
    """All rows of one run: the run's own status first, then one row per capture."""
    ok = bool(run["done"]) and not run["fault"]
    rows = [Row("(run)", "status", "done, no fault",
                f"{'done' if run['done'] else 'NOT done'}{', FAULT' if run['fault'] else ''}, "
                f"last step {run['step']}", ok)]
    caps = {c["name"]: c for c in run["captures"]}
    for pin, e in expect.items():
        if pin not in caps:
            rows.append(Row(pin, e.kind, e.expected_text(), "-", False, "not read back"))
        else:
            rows.append(check_capture(e, caps[pin], cap_widths.get(pin, e.bits)))
    rows += [_shown_only(c) for name, c in caps.items() if name not in expect]
    return rows


@dataclass
class VerifyResult:
    mode: str
    runs: list[list[Row]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.runs) and all(r.ok is not False for run in self.runs for r in run)

    def table(self) -> list[Row]:
        """One row per pin over all runs: the first failing run's row, else the last run's;
        with more than one run the result says passes out of runs."""
        if not self.runs:
            return []
        out = []
        for i, last in enumerate(self.runs[-1]):
            col = [run[i] for run in self.runs]
            fail = next((r for r in col if r.ok is False), None)
            r = fail or last
            passes = sum(1 for x in col if x.ok)
            if len(col) == 1 or r.ok is None:
                note = r.note
            else:
                note = f"{passes}/{len(col)} pass" + (f"; first fail: {r.note}" if fail and r.note else "")
            out.append(Row(r.pin, r.kind, r.expected, r.measured, False if fail else r.ok, note))
        return out

    def counts(self) -> tuple[int, int, int]:
        """(pass, fail, not judged) over the pin table."""
        t = self.table()
        return (sum(r.ok is True for r in t), sum(r.ok is False for r in t), sum(r.ok is None for r in t))


def verify_table(link, table, expect: dict[str, Expectation], mode: str = "",
                 repeat: int = 1, margin_s: float = 2.0) -> VerifyResult:
    """Run an already compiled table (mode_seq.mode_table, or load_verify_sequence) `repeat`
    times on `link` (a SeqLink to chip_top, opened and closed by the caller), check each run."""
    from .mode_seq import run_table
    widths = {c.name: c.cap_w for c in link.target.cap_cells}
    res = VerifyResult(mode=mode)
    for _ in range(max(1, repeat)):
        res.runs.append(check_run(expect, run_table(link, table, margin_s), widths))
    return res


# ---- output ----

def _result(r: Row) -> str:
    return {True: "PASS", False: "FAIL", None: "-"}[r.ok]


def format_text(res: VerifyResult) -> list[str]:
    rows = res.table()
    head = ("pin", "check", "expected", "measured", "result", "note")
    cells = [head] + [(r.pin, r.kind, r.expected, r.measured, _result(r), r.note) for r in rows]
    w = [max(len(c[i]) for c in cells) for i in range(5)]
    lines = ["  ".join(c[i].ljust(w[i]) for i in range(5)) + ("  " + c[5] if c[5] else "") for c in cells]
    p, f, n = res.counts()
    lines.append(f"{'PASS' if res.ok else 'FAIL'}: {p} pass, {f} fail, {n} not judged, "
                 f"{len(res.runs)} run{'s' if len(res.runs) != 1 else ''}")
    return lines


def format_markdown(res: VerifyResult, header: dict | None = None) -> str:
    out = [f"# Verify: mode {res.mode}", ""]
    for k, v in (header or {}).items():
        out.append(f"- {k}: {v}")
    p, f, n = res.counts()
    out += [f"- result: **{'PASS' if res.ok else 'FAIL'}** ({p} pass, {f} fail, {n} not judged, "
            f"{len(res.runs)} runs)", "",
            "| pin | check | expected | measured | result | note |", "|---|---|---|---|---|---|"]
    for r in res.table():
        out.append(f"| {r.pin} | {r.kind} | `{r.expected}` | `{r.measured}` | {_result(r)} | {r.note} |")
    return "\n".join(out) + "\n"


def format_csv(res: VerifyResult) -> str:
    """Every run, every row (for spreadsheets)."""
    buf = io.StringIO()
    wr = csv.writer(buf, lineterminator="\n")
    wr.writerow(["run", "pin", "check", "expected", "measured", "result", "note"])
    for i, run in enumerate(res.runs, 1):
        for r in run:
            wr.writerow([i, r.pin, r.kind, r.expected, r.measured, _result(r), r.note])
    return buf.getvalue()


def rows_json(rows: list[Row]) -> list[dict]:
    return [{"pin": r.pin, "kind": r.kind, "expected": r.expected, "measured": r.measured,
             "ok": r.ok, "note": r.note} for r in rows]
