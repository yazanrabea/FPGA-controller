"""Verification plan Step 3 (2026-11-01): seqwaves.py, the expected waves of a step sequence
and the check of a sampler record against them. Records are built here the way a good
board would record them (the RTL's own records are checked by scripts/run_sample_sim.sh,
through scripts/check_sample_dump.py)."""
from pathlib import Path

import pytest
import yaml

from nemo_ctl import cli
from nemo_ctl.samples import (LOOPBACK_PAIRS, LOOPBACK_PINS, Record, make_setup, sample_times_ns,
                              to_vcd, STEP_FIELD)
from nemo_ctl.sequence import PHASE7_LOOPBACK, compile_steps
from nemo_ctl.seqwaves import (LATENCY_TICKS, SeqWaveError, check_record, expected_for, scale_steps,
                               sequence_waves, step_starts)

SEQ = Path(__file__).resolve().parents[3] / "config" / "phase7_seq_loopback.yaml"
STEPS = yaml.safe_load(SEQ.read_text())["steps"]
# the real sequence's step starts (ns): 0 one tick before RUN, then 1 s each; step 2 is a
# wait (8 clocks at 4 Hz from 10 ms, ends on the 8th captured bit), step 3 waits for cs_in
S = {0: -10.0, 1: 1e9 - 10, 2: 2e9 - 10, 3: 4.01e9 + 100, 4: 4.51e9, 5: 4.5101e9}


def _level(segs, t):
    lvl = segs[0][1] if segs else 0
    for ts, v in segs:
        if ts <= t:
            lvl = v
    return int(lvl)


def _board_at(setup, first_sample):
    """_board, with the record starting `first_sample` samples after RUN."""
    rec = Record(tuple([0] * setup.n), 0, first_sample)
    exp = sequence_waves(STEPS, S, 8e9)
    words = []
    for t in sample_times_ns(setup, rec):
        w = 0
        for k, pin in enumerate(LOOPBACK_PINS):
            w |= _level(exp[LOOPBACK_PAIRS.get(pin, pin)], t) << k
        w |= max(k for k, a in S.items() if a <= t) << STEP_FIELD[0]
        words.append(w)
    return Record(tuple(words), 0, first_sample)


# ---- expected waves ----

def test_the_phase7_sequence_waves():
    w = sequence_waves(STEPS, S, 6e9)
    lat = LATENCY_TICKS * 10
    assert w["rst"] == [[-10 + lat, 1], [1e9 - 10 + lat, 0], [1.5e9 - 10 + lat, 1]]
    clk = w["clk"]
    assert clk[1] == [2e9 - 10 + lat + 10e6, 1] and len(clk) == 1 + 16     # 8 cycles from 10 ms
    assert clk[2][0] - clk[1][0] == pytest.approx(125e6)                 # 4 Hz, 50 %
    data = [v for _, v in w["data"]]
    # 0xA5 = 1010 0101 MSB first, then 0; equal neighbours merge (the two 0s are one segment)
    assert data == [0, 1, 0, 1, 0, 1, 0, 1, 0]
    t = [x for x, _ in w["data"]]
    assert t[5] - t[4] == pytest.approx(2 * 250e6)       # that segment lasts two clock periods
    assert w["cs"][1][0] == pytest.approx(S[3] + lat + 250e6) and w["cs"][2][1] == 0
    assert w["en"] == [[-10 + lat, 0], [S[3] + lat, 1]]                    # HIGH from step 3


def test_a_step_without_a_start_ends_the_waves_there():
    w = sequence_waves(STEPS, {0: -10.0, 1: 1e9 - 10}, 6e9)
    assert len(w["clk"]) == 1 and len(w["rst"]) == 3          # step 2 unknown: no clock


def test_a_wave_that_cant_be_drawn_is_an_error():
    bad = [dict(s) for s in STEPS]
    bad[2] = {**bad[2], "set": {**bad[2]["set"], "data": {"type": "SERIAL", "data": "0xA5", "bits": 8,
                                                          "clock": "nope"}}}
    with pytest.raises(SeqWaveError, match="step 2 .* data"):
        sequence_waves(bad, S, 6e9)


def test_scale_steps_matches_the_compilers_time_scale():
    a = compile_steps(scale_steps(STEPS, 1e-4), PHASE7_LOOPBACK)
    b = compile_steps(STEPS, PHASE7_LOOPBACK, scale=1e-4)
    assert a.summary() == b.summary()


# ---- step starts ----

def test_step_starts_seen_and_derived():
    setup = make_setup({"pins": ["rst"], "rate": "1kHz", "samples": 500, "trigger": "ext", "step": 1,
                        "pre": 100}, list(LOOPBACK_PINS), n_bits=16)
    rec = _board_at(setup, 900)                # samples 900.. since RUN: 0.9 s .. 1.4 s
    seen = step_starts(setup, rec)
    assert set(seen) == {0, 1} and seen[1] == pytest.approx(1e9, abs=1e6)
    full = step_starts(setup, rec, STEPS)
    assert full[2] == pytest.approx(seen[1] + 1e9)     # step 1 is "after: 1s"
    assert 3 not in full                              # step 2 is a wait: unknown from here


def test_a_step_already_running_at_the_record_start_is_not_seen():
    setup = make_setup({"pins": ["rst"], "rate": "1kHz", "samples": 200, "trigger": "ext", "step": 1},
                       list(LOOPBACK_PINS), n_bits=16)
    rec = _board_at(setup, 1200)               # 1.2 s .. 1.4 s: inside step 1
    assert step_starts(setup, rec) == {0: -10.0}
    assert step_starts(setup, rec, STEPS)[1] == pytest.approx(1e9 - 10)   # from step 0's 1 s


# ---- the check ----

def _setup(**kw):
    p = {"pins": list(LOOPBACK_PINS), "rate": "1kHz", "samples": 4000, "trigger": "ext", "step": 1, "pre": 100}
    p.update(kw)
    return make_setup(p, list(LOOPBACK_PINS), n_bits=16)


def test_a_good_board_passes_every_pin():
    setup = _setup()
    rows = check_record(STEPS, setup, _board_at(setup, 900))
    assert [r.pin for r in rows if r.ok is False] == []
    assert sum(1 for r in rows if r.ok) == 10
    clk = [r for r in rows if r.pin == "clk"][0]
    assert clk.expected == "16 edges" and clk.measured == "16 edges"


def test_a_pulled_jumper_and_a_late_clock_fail():
    setup = _setup()
    rec = _board_at(setup, 900)
    pulled = Record(tuple(w & ~(1 << LOOPBACK_PINS.index("data_in")) for w in rec.words), 0, 900)
    fails = [r.pin for r in check_record(STEPS, setup, pulled) if r.ok is False]
    assert fails == ["data_in"]
    # the clock one sample-period late is still inside 2 samples + sync; 5 periods is not
    for shift, ok in ((1, True), (5, False)):
        late = list(rec.words)
        b = 1 << LOOPBACK_PINS.index("clk")
        clk = [(w & b) for w in late]
        late = [(w & ~b) | (clk[i - shift] if i >= shift else 0) for i, w in enumerate(late)]
        r = [x for x in check_record(STEPS, setup, Record(tuple(late), 0, 900)) if x.pin == "clk"][0]
        assert r.ok is ok, (shift, r.note)


def test_vcd_with_expected_and_steps():
    setup = _setup(pins=["clk", "clk_in"], samples=3000)
    rec = _board_at(setup, 1900)
    v = to_vcd(setup, rec, expected=expected_for(STEPS, setup, rec), step_field=STEP_FIELD)
    assert "$var wire 1 # clk_exp $end" in v and "$var wire 1 $ clk_in_exp $end" in v
    assert "$var wire 4 % step $end" in v and "b0010 %" in v


def test_cli_check_on_a_fake_board(tmp_path, monkeypatch, capsys):
    from nemo_ctl.tests.test_samples import _BoardLink
    setup = _setup()
    rec = _board_at(setup, 900)
    board = _BoardLink(words=rec.words, status=(0b110, 0, 900))
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: board)
    out = tmp_path / "r.vcd"
    args = ["seq", "sample", "--jtag", "--rate", "1kHz", "--samples", "4000", "--pre", "100",
            "--trigger", "ext", "--step", "1", "--read-only", "--check", str(SEQ), "--out", str(out)]
    assert cli.main(args) == 0
    text = capsys.readouterr().out
    assert "PASS: 10 pass, 0 fail" in text and "clk_exp" in out.read_text()
    pulled = tuple(w & ~(1 << LOOPBACK_PINS.index("cs_in")) for w in rec.words)
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _BoardLink(words=pulled, status=(0b110, 0, 900)))
    assert cli.main(args) == 1
    assert "FAIL: 9 pass, 1 fail" in capsys.readouterr().out
