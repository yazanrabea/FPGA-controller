"""Phase 7 (generic_controller_prompt.md §3): a mode as an ordered list of steps.

Each step = new settings for some cells + an end condition:
    until: {after: 1s}                                   -- fixed duration
    until: {done: <sig cell>, timeout: 5s}               -- that sig_cell's `done` strobe
    until: {captured: <cap cell>, timeout: 5s}           -- that cap_cell's SERIAL `done`
    until: {edges: {cell: <cap cell>, count: 8}, timeout: 5s}
    until: {level: {cell: <cap cell>, value: 1}, timeout: 5s}

What the hardware (fpga/src/seq_engine.sv) does with the compiled table:
  * After reset it applies step 0 to every cell with RUN low, so every pin sits at
    step 0's idle level before anything starts.
  * START applies step 0 to every cell, then raises RUN.
  * At each later step boundary it APPLYs only the cells that step lists. A cell that
    isn't listed keeps running untouched (a free-running clock doesn't restart). A listed
    cell restarts at that tick, so its `delay` counts from the step's start.
  * A fixed-duration step lasts exactly `after` ticks, from its APPLY to the next one.
    A wait step ends the tick after its condition is seen; if `timeout` passes first,
    the engine FAULTs: RUN low (every pin to idle), then step 0 re-applied.
  * After the last step: RUN low, step 0 re-applied (same as STOP).

A *target* describes the cells a top level actually has (names, index order, SERIAL
widths, the hard-wired strobe sources, the table entry size). PHASE7_LOOPBACK is the one for
fpga/src/phase7_seq_loopback_top.sv; its wiring must match that file. CHIP (chip_target())
is the real chip's 22 inputs + 4 outputs, for the chip top (chip pipeline C2-C4).

The program-verify loop (pulse -> read -> compare -> repeat) is `program_verify()`,
written against the small `Sequencer` protocol so it runs the same over a real link
(Phase 7 round 2, link v2) or a mock (tests).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol, Sequence

import yaml

from .units import UnitsError, parse_duration_ns, parse_freq_hz, parse_duty, TIMEBASE_HZ, TICK_NS

TICK_W = 32
MAX_STEPS = 16  # seq_engine.sv STEP_W = 4

# Must match sig_cell.sv / cap_cell.sv (also asserted in the tests against gen_svh.py).
SIG_TYPE = {"LOW": 0, "HIGH": 1, "PULSE": 2, "CLOCK": 3, "SERIAL": 4}
CAP_MODE = {"LEVEL": 0, "EDGE_COUNT": 1, "PERIOD": 2, "SERIAL": 3}
# Must match seq_engine.sv COND_*.
COND = {"after": 0, "done": 1, "captured": 2, "edges": 3, "level": 4}

GENERIC_CLOCK_WARN_HZ = 10e6
GENERIC_CLOCK_HARD_LIMIT_HZ = 50e6


class SequenceError(ValueError):
    pass


# ======================================================================================
# Targets
# ======================================================================================

@dataclass(frozen=True)
class SigCellSpec:
    name: str
    serial_w: int = 1
    strobe: tuple[str, str] | None = None  # (clock sig cell, "rising"/"falling") if SERIAL-capable


@dataclass(frozen=True)
class CapCellSpec:
    name: str
    cap_w: int = 1
    strobe: tuple[str, str] | None = None


@dataclass(frozen=True)
class Target:
    name: str
    sig_cells: tuple[SigCellSpec, ...]
    cap_cells: tuple[CapCellSpec, ...]
    entry_bytes: int = 256   # table RAM stride per step (power of 2); the RTL uses the same

    def sig_index(self, name: str) -> int:
        return [c.name for c in self.sig_cells].index(name)

    def cap_index(self, name: str) -> int:
        return [c.name for c in self.cap_cells].index(name)


# fpga/src/phase7_seq_loopback_top.sv: sig cell i drives LA pair i (FMC pin i), cap cell
# i reads its loopback (FMC pin i+16). `data` shifts on clk's falling edge; `data_in`
# samples on clk's rising edge (half a period after data changed).
PHASE7_LOOPBACK = Target(
    name="phase7_seq_loopback_top",
    sig_cells=(
        SigCellSpec("clk"),
        SigCellSpec("rst"),
        SigCellSpec("data", serial_w=16, strobe=("clk", "falling")),
        SigCellSpec("cs"),
        SigCellSpec("en"),
    ),
    cap_cells=(
        CapCellSpec("clk_in"),
        CapCellSpec("rst_in"),
        CapCellSpec("data_in", cap_w=16, strobe=("clk", "rising")),
        CapCellSpec("cs_in"),
        CapCellSpec("en_in"),
    ),
)


def chip_target(sipo_data_edge: str = "falling", piso_sample_edge: str = "falling") -> Target:
    """The real chip as a sequencer target (chip pipeline step C2, 2026-10-26).

    One sig cell per chip **input** (22, FPGA outputs) and one cap cell per chip **output**
    (4, FPGA inputs), named exactly as the chip signals, in pin_db order (the order the
    generated chip package and chip_top.sv use; the FMC pin of each comes from the config's
    pin_map, C3).
    - `sipo_in`: SERIAL, SIPO_BITS (136) wide, shifted on `clk_sipo`'s `sipo_data_edge`;
    - `piso_out`: SERIAL capture, PISO_BITS (168), sampled on `clk_piso`'s `piso_sample_edge`;
    - every other cell 1 bit.
    The defaults are Phase 6's (docs/session1, sipo_piso.py); both edges are UNCONFIRMED
    until Dima answers, so they stay parameters. A step entry is ~534 bytes, so entry_bytes
    is 1024 (the next power of 2).
    """
    from .pins import load_pin_db
    from .sipo_piso import PISO_BITS, SIPO_BITS
    for e in (sipo_data_edge, piso_sample_edge):
        if e not in ("rising", "falling"):
            raise SequenceError(f"edge must be 'rising' or 'falling', got {e!r}")
    db = load_pin_db()
    sig, cap = [], []
    for p in db.values():
        if p.direction == "in":
            sig.append(SigCellSpec(p.name, SIPO_BITS, ("clk_sipo", sipo_data_edge))
                       if p.name == "sipo_in" else SigCellSpec(p.name))
        else:
            cap.append(CapCellSpec(p.name, PISO_BITS, ("clk_piso", piso_sample_edge))
                       if p.name == "piso_out" else CapCellSpec(p.name))
    return Target(name="chip_top", sig_cells=tuple(sig), cap_cells=tuple(cap), entry_bytes=1024)


# ======================================================================================
# Quantized cell configs
# ======================================================================================

@dataclass(frozen=True)
class SigCfg:
    type: int = 0
    idle: int = 0
    delay: int = 0
    param_a: int = 0
    param_b: int = 0
    cycles: int = 0
    msb_first: int = 1
    data: int = 0  # already justified for sig_cell (MSB-first: left-justified in serial_w)
    bits: int = 0
    done_capable: bool = False  # does sig_cell ever raise `done` with this config?


@dataclass(frozen=True)
class CapCfg:
    mode: int = 0
    msb_first: int = 1
    bits: int = 0


def _ticks(value, scale: float) -> int:
    ns = parse_duration_ns(value if value is not None else 0) * scale
    return max(0, round(ns / TICK_NS))


def quantize_sig(name: str, s: dict, spec: SigCellSpec, scale: float = 1.0,
                 warns: list | None = None) -> SigCfg:
    """One sig setting dict -> sig_cell register values. `scale` multiplies every time
    (and divides every frequency): the simulation uses a scaled copy of a human-speed
    hardware config, same structure, fewer ticks."""
    warns = warns if warns is not None else []
    t = s.get("type")
    if t not in SIG_TYPE:
        raise SequenceError(f"{name}: unknown type {t!r}")
    idle_default = int(t == "HIGH" or (t == "PULSE" and s.get("polarity") == "active_low"))
    idle = int(s.get("idle", idle_default))
    delay = _ticks(s.get("delay"), scale)
    if t in ("LOW", "HIGH"):
        return SigCfg(type=SIG_TYPE[t], idle=idle, delay=delay)
    if t == "CLOCK":
        hz = parse_freq_hz(s["freq"])
        if hz > GENERIC_CLOCK_HARD_LIMIT_HZ:
            raise SequenceError(f"{name}: {hz / 1e6:.3f} MHz exceeds the 50 MHz hard limit")
        if hz > GENERIC_CLOCK_WARN_HZ:
            warns.append(f"{name}: {hz / 1e6:.3f} MHz is above 10 MHz (jumper-wire signal integrity)")
        period = max(2, round(TIMEBASE_HZ / hz * scale))
        high = min(max(round(period * parse_duty(s.get("duty", "50%"))), 1), period - 1)
        cycles = int(s.get("cycles", 0))
        return SigCfg(type=SIG_TYPE[t], idle=idle, delay=delay, param_a=period, param_b=high,
                      cycles=cycles, done_capable=cycles > 0)
    if t == "PULSE":
        width = _ticks(s["width"], scale)
        if width < 1:
            raise SequenceError(f"{name}: PULSE width quantizes to 0 ticks")
        repeat = int(s.get("repeat", 1))
        period = 0
        if repeat > 1:
            period = _ticks(s["period"], scale)
            if period <= width:
                raise SequenceError(f"{name}: repeat period must be longer than the width")
        return SigCfg(type=SIG_TYPE[t], idle=idle, delay=delay, param_a=width, param_b=period,
                      cycles=repeat, done_capable=True)
    # SERIAL
    if spec.strobe is None or spec.serial_w < 2:
        raise SequenceError(f"{name}: this cell can't do SERIAL on this target")
    clock, edge = spec.strobe
    if s.get("clock", clock) != clock or s.get("data_edge", edge) != edge:
        raise SequenceError(f"{name}: SERIAL is hard-wired to {clock}'s {edge} edge on this target")
    bits = int(s["bits"])
    if not 1 <= bits <= spec.serial_w:
        raise SequenceError(f"{name}: bits={bits} must be 1..{spec.serial_w}")
    raw = int(s["data"], 0) if isinstance(s["data"], str) else int(s["data"])
    if not 0 <= raw < (1 << bits):
        raise SequenceError(f"{name}: data {raw:#x} doesn't fit {bits} bits")
    msb = 1 if s.get("msb_first", True) else 0
    data = raw << (spec.serial_w - bits) if msb else raw  # sig_cell.sv justification rule
    return SigCfg(type=SIG_TYPE[t], idle=idle, delay=delay, msb_first=msb, data=data,
                  bits=bits, done_capable=True)


def quantize_cap(name: str, s: dict, spec: CapCellSpec) -> CapCfg:
    mode = s.get("mode")
    if mode not in CAP_MODE:
        raise SequenceError(f"{name}: unknown capture mode {mode!r}")
    if mode != "SERIAL":
        return CapCfg(mode=CAP_MODE[mode])
    if spec.strobe is None or spec.cap_w < 2:
        raise SequenceError(f"{name}: this cell can't do SERIAL capture on this target")
    bits = int(s["bits"])
    if not 1 <= bits <= spec.cap_w:
        raise SequenceError(f"{name}: bits={bits} must be 1..{spec.cap_w}")
    return CapCfg(mode=CAP_MODE[mode], msb_first=1 if s.get("msb_first", True) else 0, bits=bits)


# ======================================================================================
# Steps
# ======================================================================================

@dataclass(frozen=True)
class Step:
    name: str
    sig_mask: tuple[bool, ...]  # cells (re)applied at this step's start
    cap_mask: tuple[bool, ...]
    sig: tuple[SigCfg, ...]  # every cell's config *in effect* during this step
    cap: tuple[CapCfg, ...]
    cond: int
    cond_cell: int
    cond_arg: int  # after: ticks; edges: count; level: 0/1
    timeout: int  # ticks, 0 = none (only for `after`)


@dataclass(frozen=True)
class StepTable:
    target: Target
    steps: tuple[Step, ...]
    warnings: tuple[str, ...] = ()

    def summary(self) -> list[str]:
        """One line per step: start tick (exact while every earlier step is a fixed
        duration), what's applied, how it ends."""
        lines, t, exact = [], 0, True
        for k, st in enumerate(self.steps):
            sigs = [c.name for c, m in zip(self.target.sig_cells, st.sig_mask) if m]
            caps = [c.name for c, m in zip(self.target.cap_cells, st.cap_mask) if m]
            start = f"t={t} ticks ({t * TICK_NS / 1e3:g} us)" if exact else "t=after previous wait"
            if st.cond == COND["after"]:
                end = f"after {st.cond_arg} ticks"
            else:
                kind = [k_ for k_, v in COND.items() if v == st.cond][0]
                cells = self.target.sig_cells if kind == "done" else self.target.cap_cells
                end = f"{kind} {cells[st.cond_cell].name}"
                if kind == "edges":
                    end += f" >= {st.cond_arg}"
                elif kind == "level":
                    end += f" == {st.cond_arg}"
                end += f", timeout {st.timeout} ticks"
            lines.append(f"{k} {st.name}: {start}; applies {sigs + caps}; ends {end}")
            if st.cond == COND["after"] and exact:
                t += st.cond_arg
            else:
                exact = False
        return lines


def compile_steps(raw_steps: Sequence[dict], target: Target = PHASE7_LOOPBACK,
                  scale: float = 1.0) -> StepTable:
    """Validate + quantize a list of step dicts. Raises SequenceError listing every
    problem found, one per line."""
    errs: list[str] = []
    warns: list[str] = []
    if not raw_steps:
        raise SequenceError("a sequence needs at least one step")
    if len(raw_steps) > MAX_STEPS:
        errs.append(f"{len(raw_steps)} steps, the engine holds at most {MAX_STEPS}")

    sig_names = [c.name for c in target.sig_cells]
    cap_names = [c.name for c in target.cap_cells]
    cur_sig: list[SigCfg | None] = [None] * len(sig_names)
    cur_cap: list[CapCfg | None] = [None] * len(cap_names)
    names: set[str] = set()
    steps: list[Step] = []

    for k, raw in enumerate(raw_steps):
        name = str(raw.get("name", f"step{k}"))
        where = f"step {k} ({name})"
        if name in names:
            errs.append(f"{where}: duplicate step name")
        names.add(name)
        sets = raw.get("set") or {}
        caps = raw.get("capture") or {}
        for n in sets:
            if n not in sig_names:
                errs.append(f"{where}: unknown sig cell {n!r} (target has {sig_names})")
        for n in caps:
            if n not in cap_names:
                errs.append(f"{where}: unknown cap cell {n!r} (target has {cap_names})")
        if k == 0:
            missing = [n for n in sig_names if n not in sets] + [n for n in cap_names if n not in caps]
            if missing:
                errs.append(f"{where}: step 0 must set every cell (it is also the idle state); "
                            f"missing {missing}")

        sig_mask = tuple(n in sets for n in sig_names)
        cap_mask = tuple(n in caps for n in cap_names)
        for i, spec in enumerate(target.sig_cells):
            if spec.name in sets:
                try:
                    cur_sig[i] = quantize_sig(f"{where}/{spec.name}", sets[spec.name], spec,
                                              scale, warns)
                except (SequenceError, UnitsError, KeyError, TypeError, ValueError) as exc:
                    errs.append(f"{where}/{spec.name}: {exc}" if not str(exc).startswith(where)
                                else str(exc))
        for i, spec in enumerate(target.cap_cells):
            if spec.name in caps:
                try:
                    cur_cap[i] = quantize_cap(f"{where}/{spec.name}", caps[spec.name], spec)
                except (SequenceError, KeyError, TypeError, ValueError) as exc:
                    errs.append(str(exc))

        cond, cell, arg, timeout = _compile_until(raw.get("until"), where, target, sig_mask,
                                                  cap_mask, cur_sig, cur_cap, scale, errs, warns)
        steps.append(Step(
            name=name, sig_mask=sig_mask, cap_mask=cap_mask,
            sig=tuple(c or SigCfg() for c in cur_sig), cap=tuple(c or CapCfg() for c in cur_cap),
            cond=cond, cond_cell=cell, cond_arg=arg, timeout=timeout,
        ))

    for st in steps:
        for v in (st.cond_arg, st.timeout, *(x for c in st.sig for x in
                                              (c.delay, c.param_a, c.param_b, c.cycles))):
            if v >= 1 << TICK_W:
                errs.append(f"step {st.name}: a value ({v}) doesn't fit {TICK_W} bits")
                break
    if errs:
        raise SequenceError("\n".join(errs))  # one problem per line
    return StepTable(target=target, steps=tuple(steps), warnings=tuple(warns))


def _compile_until(u, where, target, sig_mask, cap_mask, cur_sig, cur_cap, scale, errs, warns):
    if not isinstance(u, dict):
        errs.append(f"{where}: needs an 'until' mapping")
        return 0, 0, 0, 0
    kinds = [k for k in u if k != "timeout"]
    if len(kinds) != 1 or kinds[0] not in COND:
        errs.append(f"{where}: 'until' needs exactly one of {list(COND)}, got {kinds}")
        return 0, 0, 0, 0
    kind = kinds[0]
    if kind == "after":
        ticks = _ticks(u["after"], scale)
        if ticks < 1:
            errs.append(f"{where}: 'after' must be at least 1 tick (10 ns)")
        if "timeout" in u:
            warns.append(f"{where}: 'timeout' is ignored on a fixed-duration step")
        return COND["after"], 0, ticks, 0

    timeout = _ticks(u.get("timeout"), scale)
    if timeout < 1:
        errs.append(f"{where}: a wait step needs a 'timeout' (it FAULTs the sequence safely "
                    f"instead of hanging)")
    sig_names = [c.name for c in target.sig_cells]
    cap_names = [c.name for c in target.cap_cells]

    if kind == "done":
        n = u["done"]
        if n not in sig_names:
            errs.append(f"{where}: 'done' needs a sig cell, got {n!r}")
            return COND[kind], 0, 0, timeout
        i = sig_names.index(n)
        if not sig_mask[i]:
            errs.append(f"{where}: waits for {n} done, but {n} isn't set in this step "
                        f"(its done strobe would have fired already, or never)")
        elif cur_sig[i] is not None and not cur_sig[i].done_capable:
            errs.append(f"{where}: {n}'s setting never finishes (free-running CLOCK or LOW/HIGH), "
                        f"so 'done' can't happen")
        return COND[kind], i, 0, timeout

    if kind == "captured":
        n = u["captured"]
        if n not in cap_names:
            errs.append(f"{where}: 'captured' needs a cap cell, got {n!r}")
            return COND[kind], 0, 0, timeout
        i = cap_names.index(n)
        if not cap_mask[i]:
            errs.append(f"{where}: waits for {n} captured, but {n} isn't (re)armed in this step")
        elif cur_cap[i] is not None and cur_cap[i].mode != CAP_MODE["SERIAL"]:
            errs.append(f"{where}: 'captured' needs {n} in SERIAL mode")
        return COND[kind], i, 0, timeout

    spec = u[kind]
    n = spec.get("cell") if isinstance(spec, dict) else None
    if n not in cap_names:
        errs.append(f"{where}: '{kind}' needs {{cell: <cap cell>, ...}}, got {spec!r}")
        return COND[kind], 0, 0, timeout
    i = cap_names.index(n)
    if kind == "edges":
        count = int(spec.get("count", 0))
        if count < 1:
            errs.append(f"{where}: edges count must be >= 1")
        if cur_cap[i] is not None and cur_cap[i].mode != CAP_MODE["EDGE_COUNT"]:
            errs.append(f"{where}: 'edges' needs {n} in EDGE_COUNT mode")
        if not cap_mask[i]:
            warns.append(f"{where}: {n} isn't re-armed in this step, so its count includes "
                         f"edges from earlier steps")
        return COND[kind], i, count, timeout
    value = int(spec.get("value", -1))
    if value not in (0, 1):
        errs.append(f"{where}: level value must be 0 or 1")
    return COND[kind], i, max(value, 0), timeout


def load_sequence(path: Path, target: Target = PHASE7_LOOPBACK, scale: float = 1.0) -> StepTable:
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    if doc.get("target", target.name) != target.name:
        raise SequenceError(f"{path}: target {doc.get('target')!r}, expected {target.name!r}")
    return compile_steps(doc.get("steps") or [], target, scale)


# ======================================================================================
# Program-verify loop (driven from Python, per the brief)
# ======================================================================================

@dataclass(frozen=True)
class SeqResult:
    done: bool
    fault: bool
    step: int  # last step reached (fault step if fault)


class Sequencer(Protocol):
    """What program_verify needs from the hardware (or a mock)."""
    def load(self, table: StepTable) -> None: ...
    def start(self) -> None: ...
    def wait(self, timeout_s: float) -> SeqResult: ...
    def read_capture(self, cap_cell: str) -> int: ...


@dataclass
class VerifyResult:
    passed: bool
    iterations: int
    history: list[int] = field(default_factory=list)  # value read after each iteration


def program_verify(seq: Sequencer, build: Callable[[int], StepTable], read_cell: str,
                   check: Callable[[int], bool], max_iters: int,
                   timeout_s: float = 1.0) -> VerifyResult:
    """pulse -> read -> compare -> repeat. `build(i)` makes iteration i's step table
    (e.g. a longer or repeated pulse each time); `check(value)` says when the read-back
    value is good enough. Stops on the first pass, after `max_iters`, or raises on a
    sequencer FAULT (never keeps pulsing a chip after something went wrong)."""
    history: list[int] = []
    for i in range(max_iters):
        seq.load(build(i))
        seq.start()
        r = seq.wait(timeout_s)
        if r.fault or not r.done:
            raise SequenceError(f"iteration {i}: sequence {'faulted' if r.fault else 'timed out'} "
                                f"at step {r.step}; stopping")
        value = seq.read_capture(read_cell)
        history.append(value)
        if check(value):
            return VerifyResult(True, i + 1, history)
    return VerifyResult(False, max_iters, history)


def main(argv: list[str] | None = None) -> None:
    import argparse
    import sys
    ap = argparse.ArgumentParser(
        prog="python -m nemo_ctl.sequence",
        description="Check a Phase 7 step sequence and print its step-by-step summary "
                    "(USER_MANUAL §8). Prints every problem and exits 1 if it is invalid.")
    ap.add_argument("config", type=Path, nargs="?",
                    default=Path(__file__).resolve().parents[2] / "config" / "phase7_seq_loopback.yaml",
                    help="sequence YAML (default: config/phase7_seq_loopback.yaml)")
    args = ap.parse_args(argv)
    try:
        table = load_sequence(args.config)
    except (SequenceError, OSError) as exc:
        for part in str(exc).splitlines():
            print(f"error: {part}", file=sys.stderr)
        sys.exit(1)
    for line in table.summary():
        print(line)
    for w in table.warnings:
        print(f"warning: {w}", file=sys.stderr)


if __name__ == "__main__":
    main()


# ======================================================================================
# Phase 7 round 2: step-table entry layout (link v2, seq_bank.sv)
# ======================================================================================

ENTRY_BYTES = 256  # PHASE7_LOOPBACK's stride per step in the table RAM (Target.entry_bytes)


@dataclass(frozen=True)
class EntryLayout:
    """Byte offsets of one step's entry in the link-written table (little-endian
    fields). The single source for the PC encoder (`encode_step`), the generated
    phase7_link_pkg (FPGA field extraction) and the tests' fake device.

    Header: SIG_MASK (ceil(N_SIG/8) B), CAP_MASK (ceil(N_CAP/8) B), COND (1), COND_CELL (1),
            COND_ARG (4), TIMEOUT (4).
    Per sig cell, in target order: CTRL (1: type[2:0], idle[3], msb_first[4]), DELAY,
            PARAM_A, PARAM_B, CYCLES, BITS (4 each), DATA (ceil(serial_w/8) bytes, already
            justified the way sig_cell expects).
    Per cap cell: CTRL (1: mode[1:0], msb_first[2]), BITS (4).
    """
    target: Target
    sig_mask: int
    cap_mask: int
    cond: int
    cond_cell: int
    cond_arg: int
    timeout: int
    hdr_bytes: int
    sig_base: tuple[int, ...]
    cap_base: tuple[int, ...]
    used_bytes: int

    SIG_CTRL, SIG_DELAY, SIG_PARAM_A, SIG_PARAM_B, SIG_CYCLES, SIG_BITS, SIG_DATA = 0, 1, 5, 9, 13, 17, 21
    CAP_CTRL, CAP_BITS = 0, 1
    CAP_SIZE = 5

    def sig_size(self, i: int) -> int:
        return self.SIG_DATA + (self.target.sig_cells[i].serial_w + 7) // 8


def entry_layout(target: Target = PHASE7_LOOPBACK) -> EntryLayout:
    sm = (len(target.sig_cells) + 7) // 8
    cm = (len(target.cap_cells) + 7) // 8
    sig_mask, cap_mask = 0, sm
    cond = sm + cm
    cond_cell, cond_arg = cond + 1, cond + 2
    timeout = cond_arg + 4
    hdr = timeout + 4
    sig_base, off = [], hdr
    for c in target.sig_cells:
        sig_base.append(off)
        off += EntryLayout.SIG_DATA + (c.serial_w + 7) // 8
    cap_base = []
    for _ in target.cap_cells:
        cap_base.append(off)
        off += EntryLayout.CAP_SIZE
    if off > target.entry_bytes:
        raise SequenceError(f"{target.name}: a step entry needs {off} bytes, more than {target.entry_bytes}")
    return EntryLayout(target, sig_mask, cap_mask, cond, cond_cell, cond_arg, timeout, hdr,
                       tuple(sig_base), tuple(cap_base), off)


def encode_step(st: Step, lay: EntryLayout) -> bytes:
    """One compiled Step -> its entry bytes (lay.used_bytes long)."""
    b = bytearray(lay.used_bytes)

    def put(off: int, value: int, n: int) -> None:
        b[off:off + n] = int(value).to_bytes(n, "little")

    tg = lay.target
    put(lay.sig_mask, sum(int(m) << i for i, m in enumerate(st.sig_mask)), lay.cap_mask - lay.sig_mask)
    put(lay.cap_mask, sum(int(m) << i for i, m in enumerate(st.cap_mask)), lay.cond - lay.cap_mask)
    put(lay.cond, st.cond, 1)
    put(lay.cond_cell, st.cond_cell, 1)
    put(lay.cond_arg, st.cond_arg, 4)
    put(lay.timeout, st.timeout, 4)
    for i, c in enumerate(st.sig):
        o = lay.sig_base[i]
        put(o + lay.SIG_CTRL, (c.type & 7) | (c.idle << 3) | (c.msb_first << 4), 1)
        put(o + lay.SIG_DELAY, c.delay, 4)
        put(o + lay.SIG_PARAM_A, c.param_a, 4)
        put(o + lay.SIG_PARAM_B, c.param_b, 4)
        put(o + lay.SIG_CYCLES, c.cycles, 4)
        put(o + lay.SIG_BITS, c.bits, 4)
        put(o + lay.SIG_DATA, c.data, (tg.sig_cells[i].serial_w + 7) // 8)
    for i, c in enumerate(st.cap):
        o = lay.cap_base[i]
        put(o + lay.CAP_CTRL, (c.mode & 3) | (c.msb_first << 2), 1)
        put(o + lay.CAP_BITS, c.bits, 4)
    return bytes(b)


def link_late_warnings(table: StepTable, lay: EntryLayout | None = None) -> list[str]:
    """Fixed-duration steps too short for the link top's bank (seq_bank.sv) to copy the
    next step in time (ceil(used/4) + 3 ticks): the next step will start LATE (the
    STATUS LATE bit shows it). A WAIT step can cause the same if its condition is met
    within that time, e.g. a level that is already right (ends on tick 3); that can't
    be known before running, so it isn't warned about here; LATE reports it."""
    lay = lay or entry_layout(table.target)
    copy_ticks = (lay.used_bytes + 3) // 4 + 3
    return [
        f"step {k + 1} ({table.steps[k + 1].name}) will start late over the link: step {k} "
        f"({st.name}) lasts {st.cond_arg} ticks, the bank needs ~{copy_ticks} to fetch the next one"
        for k, st in enumerate(table.steps[:-1])
        if st.cond == COND["after"] and st.cond_arg < copy_ticks
    ]
