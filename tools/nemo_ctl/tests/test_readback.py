"""Verification plan Step 2 (pad readback, 2026-11-02): readback.py (expected values from a
run's steps, the check) and link.SeqLink.read_readback (parsing chip_top's RB_* region)."""
from pathlib import Path

import pytest
import yaml

from nemo_ctl.link import V2_RB_BASE, V2_RB_INFO, V2_RB_SIPO, V2_RB_STRIDE, SeqLink
from nemo_ctl.readback import (PinStats, check_readback, expected_readback, expected_sipo,
                               stats_from_segments, step_starts)
from nemo_ctl.sequence import chip_target, compile_steps
from nemo_ctl.verify import verify_table

REPO = Path(__file__).resolve().parents[3]
CHIP = chip_target()
OUTS = [c.name for c in CHIP.sig_cells]
STEPS = yaml.safe_load((REPO / "config" / "chip_sim_test.yaml").read_text())["steps"]
FRAME = 0x5AA55A0FF0123456789ABCDEF0C3C3E7E7
WINDOW = 31953          # what chip_top_tb's RTL reported for this sequence (xsim, 2026-11-02)

# what chip_top's readback cells produced for config/chip_sim_test.yaml in fpga/tb/chip_top_tb.sv
# (xsim 2026-11-02, check 7, without the forced s0_p pad): edges, period, high, saw0, saw1, end
RTL = {"clk_sipo": (136, 100, 50, 1, 1, 0), "clk_piso": (168, 100, 50, 1, 1, 0),
       "cs": (1, 0, 100, 1, 1, 0), "shift": (1, 0, 0, 1, 1, 1), "sipo_in": (32, 800, 300, 1, 1, 0),
       "reset": (0, 0, 0, 0, 1, 1), "rst_sipo": (0, 0, 0, 0, 1, 1), "rst_piso": (0, 0, 0, 0, 1, 1)}


def _rtl(pin):
    return PinStats(*(RTL.get(pin) or (0, 0, 0, 1, 0, 0)))


def test_python_expectation_equals_what_the_rtl_produced():
    exp, notes = expected_readback(STEPS, OUTS, WINDOW)
    assert not notes and set(exp) == set(OUTS)
    for pin in OUTS:
        assert exp[pin] == _rtl(pin), pin


def test_expected_sipo_frame():
    assert expected_sipo(STEPS) == (136, FRAME)
    lsb = [{"set": {"sipo_in": {"type": "SERIAL", "bits": 4, "data": "0x1", "msb_first": False}}}]
    assert expected_sipo(lsb) == (4, 0b1000)       # sent LSB first: arrives reversed


@pytest.mark.parametrize("segs, initial, window, want", [
    ([], 0, 100, PinStats(0, 0, 0, True, False, 0)),                         # static low
    ([], 1, 100, PinStats(0, 0, 0, False, True, 1)),                         # static high
    ([[0, 1], [500, 0]], 0, 100, PinStats(1, 0, 50, True, True, 0)),         # rise on the first tick
    ([[100, 1], [170, 0], [300, 1], [370, 0]], 0, 100, PinStats(2, 20, 7, True, True, 0)),
    ([[100, 0], [130, 1]], 1, 100, PinStats(1, 0, 0, True, True, 1)),        # active-low pulse: no high time
    ([[100, 1], [2000, 0]], 0, 100, PinStats(1, 0, 0, True, True, 1)),       # the fall after the window
])
def test_stats_follow_readback_cell(segs, initial, window, want):
    assert stats_from_segments(segs, initial, window) == want


def test_step_starts_one_wait_step_takes_the_rest_of_the_window():
    s = step_starts(STEPS, WINDOW)
    assert s[0] == -10 and s[1] == 4990 and s[2] == 149990          # 5 us idle, 145 us load
    two = STEPS + [{"name": "w2", "set": {}, "until": {"captured": "piso_out", "timeout": "1ms"}}]
    assert step_starts(two, WINDOW) is None
    exp, notes = expected_readback(two, OUTS, WINDOW)
    assert exp == {} and "can't be told apart" in notes[0]


def _rb(stats: dict, window=WINDOW, sipo=FRAME, sipo_bits=136, pad=True):
    return {"pad": pad, "window": window, "sipo": sipo, "sipo_bits": sipo_bits, "sipo_width": 136,
            "cells": {p: {"edges": s.edges, "period": s.period, "high": s.high, "saw0": s.saw0,
                          "saw1": s.saw1, "end": s.end} for p, s in stats.items()}}


def test_check_all_pass_and_one_wrong_pin():
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    rows = check_readback(STEPS, OUTS, _rb(exp))
    assert rows[0].pin == "(readback)" and "at the pads" in rows[0].measured
    judged = [r for r in rows if r.ok is not None]
    assert len(judged) == 22 + 1 and all(r.ok for r in judged)          # 22 pins + the frame
    bad = dict(exp)
    bad["s0_p"] = PinStats(0, 0, 0, False, True, 1)                      # pad stuck high
    rows = check_readback(STEPS, OUTS, _rb(bad))
    fails = [r for r in rows if r.ok is False]
    assert [r.pin for r in fails] == ["s0_p"] and "saw0" in fails[0].note and "saw1" in fails[0].note


def test_period_tolerance_is_one_tick():
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    for d, ok in ((1, True), (2, False)):
        got = dict(exp)
        e = exp["clk_sipo"]
        got["clk_sipo"] = PinStats(e.edges, e.period + d, e.high, e.saw0, e.saw1, e.end)
        row = next(r for r in check_readback(STEPS, OUTS, _rb(got)) if r.pin == "clk_sipo")
        assert row.ok is ok


def test_sipo_frame_wrong_bit_and_wrong_count():
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    row = lambda rb: next(r for r in check_readback(STEPS, OUTS, rb) if r.pin == "sipo_in frame")
    assert row(_rb(exp)).ok
    r = row(_rb(exp, sipo=FRAME ^ (1 << 5)))
    assert not r.ok and "1 bit(s) wrong" in r.note
    r = row(_rb(exp, sipo_bits=135))
    assert not r.ok and "135 bits sampled, 136 expected" in r.note


def test_sipo_frame_is_never_passed_unchecked():
    """issues.md 2026-11-03: these used to PASS without a comparison."""
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    row = lambda steps, rb: next(r for r in check_readback(steps, OUTS, rb) if r.pin == "sipo_in frame")
    # two wait steps: no expectations, so the bit count can't be checked; 0 bits must not PASS
    two_waits = STEPS + [{"name": "wait2", "until": {"captured": "piso_out", "timeout": "300us"}}]
    r = row(two_waits, _rb(exp, sipo=0, sipo_bits=0))
    assert r.ok is None and "only 0 of 136 bits sampled" in r.note and "not checked" in r.note
    # with every bit there it is still compared, so a wrong bit still FAILs
    assert row(two_waits, _rb(exp)).ok
    assert row(two_waits, _rb(exp, sipo=FRAME ^ 1)).ok is False
    # a frame wider than the readback register
    r = row(STEPS, {**_rb(exp, sipo=0xE7), "sipo_width": 8})
    assert r.ok is None and "wider than the readback register" in r.note
    # one wait step (today's sequences): 0 bits is still a FAIL
    assert row(STEPS, _rb(exp, sipo=0, sipo_bits=0)).ok is False


def test_no_readback_in_the_bitstream_and_vchip():
    rows = check_readback(STEPS, OUTS, None)
    assert len(rows) == 1 and rows[0].ok is None and "no pad readback" in rows[0].note
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    assert "output registers" in check_readback(STEPS, OUTS, _rb(exp, pad=False))[0].measured


# ---- SeqLink.read_readback over a fake register file ----

class _Regs(SeqLink):
    """A SeqLink whose read_reg answers from a dict of address -> byte."""
    def __init__(self, mem):
        self.target, self.mem, self.reads = CHIP, mem, []

    def read_reg(self, addr, length):
        self.reads.append((addr, length))
        return bytes(self.mem.get(addr + i, 0) for i in range(length))


def _mem_for(stats: dict, window=WINDOW):
    mem = {V2_RB_INFO: 22, V2_RB_INFO + 1: 1, V2_RB_INFO + 2: 136, V2_RB_INFO + 4: 136}
    for i, b in enumerate(window.to_bytes(4, "little")):
        mem[V2_RB_INFO + 5 + i] = b
    for i, b in enumerate(FRAME.to_bytes(17, "little")):
        mem[V2_RB_SIPO + i] = b
    for k, name in enumerate(OUTS):
        s = stats[name]
        rec = bytes([s.saw0 | (s.saw1 << 1) | (s.end << 2)]) + s.edges.to_bytes(4, "little") \
            + s.period.to_bytes(4, "little") + s.high.to_bytes(4, "little")
        for i, b in enumerate(rec):
            mem[V2_RB_BASE + V2_RB_STRIDE * k + i] = b
    return mem


def test_read_readback_parses_chip_tops_region():
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)
    link = _Regs(_mem_for(exp))
    rb = link.read_readback()
    assert rb["pad"] and rb["window"] == WINDOW and rb["sipo"] == FRAME and rb["sipo_bits"] == 136
    for name in OUTS:
        c = rb["cells"][name]
        assert PinStats(c["edges"], c["period"], c["high"], c["saw0"], c["saw1"], c["end"]) == exp[name]
    assert all(n <= 255 for _, n in link.reads)                          # link frames <= 255 bytes
    assert _Regs({}).read_readback() is None                             # an old bitstream: RB_INFO 0


def test_verify_table_adds_the_readback_rows():
    exp, _ = expected_readback(STEPS, OUTS, WINDOW)

    class Board(_Regs):
        def load(self, table): pass
        def start(self): pass
        def wait(self, t):
            from types import SimpleNamespace
            return SimpleNamespace(done=True, fault=False, step=2)
        def read_cap_counts(self, n): return {"level": 0, "edges": 0}
        def read_cap_timing(self, n): return {"period": 0, "high": 0}
        def read_capture(self, n): return 0

    table = compile_steps(STEPS, CHIP)
    res = verify_table(Board(_mem_for(exp)), table, {}, mode="seq", steps=STEPS)
    rb_rows = [r for r in res.runs[0] if r.kind == "readback"]
    assert len(rb_rows) == 1 + 22 + 1 and all(r.ok is not False for r in rb_rows)
    assert res.ok
    res = verify_table(Board(_mem_for(exp)), table, {}, mode="seq")      # no steps: no readback rows
    assert not [r for r in res.runs[0] if r.kind == "readback"]
