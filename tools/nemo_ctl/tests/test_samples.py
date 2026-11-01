"""Verification plan Step 3 (2026-11-01): samples.py, the PC side of sample_cell.sv.
Records are made here by sampling the expected wave at the cell's sample times, so a
correct board would give exactly these words."""
import pytest
import yaml

from nemo_ctl.config import config_from_dict
from nemo_ctl.samples import (Record, SampleError, compare, decode, default_tol_ns, make_setup,
                              record_window, sample_times_ns, words_from_bytes)
from nemo_ctl.waves import mode_waves

PINS = ["clk_sipo", "sipo_in", "cs", "clk_piso"]


def _level(segs, t):
    lvl = segs[0][1]
    for ts, v in segs:
        if ts <= t:
            lvl = v
    return int(lvl)


def _record(setup, lanes, trig_count=0, shift_ns=0.0):
    """What the cell would hold: sample i = each pin's expected level at its sample time."""
    rec = Record(words=tuple([0] * setup.n), trig_idx=setup.pre, trig_count=trig_count)
    times = sample_times_ns(setup, rec)
    words = []
    for t in times:
        w = 0
        for k, pin in enumerate(setup.pins):
            w |= _level(lanes[pin], t - shift_ns) << k
        words.append(w)
    return Record(tuple(words), setup.pre, trig_count)


CLOCK = [[0, 1]] + [[500 * k, (k + 1) % 2] for k in range(1, 40)]   # 1 MHz from 0, high first


# ---- setup ----

def test_setup_quantizes_and_reports():
    s = make_setup({"pins": PINS, "rate": "10MHz", "samples": 2000, "pre": 100,
                    "trigger": "rise", "on": "cs"}, PINS)
    assert (s.div, s.n, s.pre, s.trig_pin) == (10, 2000, 100, "cs")
    assert s.cfg() == {"cfg_div": 10, "cfg_n": 2000, "cfg_pre": 100, "cfg_trig": 2, "cfg_trig_pin": 2}
    assert s.span_ns == 200_000 and "every 100 ns (10 MHz), 2000 samples = 200 us" in s.summary()
    assert make_setup({"pins": "cs, clk_sipo", "period": "10ns"}, PINS).div == 1


@pytest.mark.parametrize("params, msg", [
    ({"pins": [], "rate": "1MHz"}, "at least one pin"),
    ({"pins": ["shift"], "rate": "1MHz"}, "not wired"),
    ({"pins": ["cs", "cs"], "rate": "1MHz"}, "twice"),
    ({"pins": ["cs"]}, "either rate"),
    ({"pins": ["cs"], "rate": "1MHz", "period": "1us"}, "either rate"),
    ({"pins": ["cs"], "rate": "200MHz"}, "faster than the 100 MHz tick"),
    ({"pins": ["cs"], "rate": "3MHz"}, "whole number of 10 ns ticks"),
    ({"pins": ["cs"], "rate": "fast"}, "bad sample rate"),
    ({"pins": ["cs"], "rate": "1MHz", "samples": 5000}, "1..4096"),
    ({"pins": ["cs"], "rate": "1MHz", "samples": 10, "pre": 10, "trigger": "ext"}, "pre=10"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "rise"}, "needs `on"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "rise", "on": "sipo_in"}, "one of the sampled pins"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "ext", "on": "cs"}, "has no pin"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "now", "pre": 3}, "set pre to 0"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "soon"}, "one of now"),
])
def test_setup_errors(params, msg):
    with pytest.raises(SampleError, match=msg):
        make_setup(params, PINS)


def test_more_pins_than_the_cell_has():
    with pytest.raises(SampleError, match="the cell records 2"):
        make_setup({"pins": PINS[:3], "rate": "1MHz"}, PINS, n_bits=2)


# ---- decode / compare ----

def test_sample_times_follow_the_cell():
    s = make_setup({"pins": ["cs"], "rate": "10MHz", "samples": 4, "pre": 2, "trigger": "ext"}, PINS)
    # trigger was sample 7 since arming and sits at index 2: the record starts with sample 5
    rec = Record((0, 0, 0, 0), trig_idx=2, trig_count=7)
    assert sample_times_ns(s, rec) == [(5 * 10 + 1 - 2) * 10, (6 * 10 - 1) * 10, (7 * 10 - 1) * 10, (8 * 10 - 1) * 10]


def test_a_clock_sampled_by_a_good_board_matches():
    s = make_setup({"pins": ["clk_sipo"], "rate": "50MHz", "samples": 1000}, PINS)
    rec = _record(s, {"clk_sipo": CLOCK})
    seen = decode(s, rec)["clk_sipo"]
    assert len(seen) > 30 and compare(CLOCK, seen, default_tol_ns(s), record_window(s, rec)) == []


def test_late_clock_beyond_the_tolerance_is_reported():
    s = make_setup({"pins": ["clk_sipo"], "rate": "50MHz", "samples": 1000}, PINS)
    w = record_window(s, _record(s, {"clk_sipo": CLOCK}))
    seen = decode(s, _record(s, {"clk_sipo": CLOCK}, shift_ns=100))["clk_sipo"]
    miss = compare(CLOCK, seen, default_tol_ns(s), w)
    assert miss and any("not seen within 40 ns" in m for m in miss)
    seen = decode(s, _record(s, {"clk_sipo": CLOCK}, shift_ns=20))["clk_sipo"]
    assert compare(CLOCK, seen, default_tol_ns(s), w) == []      # 20 ns late: inside 1 sample + sync


def test_missing_pulse_and_glitch():
    want = [[0, 0], [5000, 1], [6000, 0]]
    s = make_setup({"pins": ["cs"], "rate": "10MHz", "samples": 200}, PINS)
    rec = _record(s, {"cs": [[0, 0]]})
    w = record_window(s, rec)
    flat = decode(s, rec)["cs"]
    assert len(flat) == 1                               # a pin that never moved
    assert compare(want, flat, default_tol_ns(s), w) == [
        "rising edge expected at 5 us not seen within 120 ns",
        "falling edge expected at 6 us not seen within 120 ns"]
    glitch = decode(s, _record(s, {"cs": [[0, 0], [5000, 1], [6000, 0], [9000, 1], [9500, 0]]}))["cs"]
    m = compare(want, glitch, default_tol_ns(s), w)
    assert len(m) == 2 and all(x.startswith("unexpected") for x in m)


def test_wrong_level_at_the_record_start():
    s = make_setup({"pins": ["cs"], "rate": "10MHz", "samples": 50}, PINS)
    rec = _record(s, {"cs": [[0, 1]]})
    seen = decode(s, rec)["cs"]
    assert compare([[0, 0]], seen, default_tol_ns(s), record_window(s, rec)) == [
        "at -10 ns (record start): 1, expected 0"]


def test_bit_order_is_the_pin_list():
    s = make_setup({"pins": ["cs", "clk_sipo"], "rate": "10MHz", "samples": 3}, PINS)
    d = decode(s, Record((0b01, 0b10, 0b11), 0, 0))
    assert [v for _, v in d["cs"]] == [1, 0, 1] and [v for _, v in d["clk_sipo"]] == [0, 1]
    assert words_from_bytes(bytes([1, 0, 0, 0, 2, 0, 0, 0])) == [1, 2]
    with pytest.raises(SampleError):
        words_from_bytes(b"\x01\x02\x03")


def test_against_a_real_waves_lane():
    """The INFERENCE mode's clk_sipo / cs as waves.py draws them, recorded by a good board."""
    from pathlib import Path
    text = (Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml").read_text()
    cfg = config_from_dict(yaml.safe_load(text.replace('data: "0x" ,', 'data: "0x5A",')))
    lanes = {l["key"]: l["segments"] for l in mode_waves(cfg, "INFERENCE", 0, 160_000)["lanes"]
             if l["key"] in ("clk_sipo", "cs")}
    s = make_setup({"pins": ["clk_sipo", "cs"], "rate": "20MHz", "samples": 3200}, PINS)
    rec = _record(s, lanes)
    d, w, tol = decode(s, rec), record_window(s, rec), default_tol_ns(s)
    assert compare(lanes["clk_sipo"], d["clk_sipo"], tol, w) == []
    assert compare(lanes["cs"], d["cs"], tol, w) == []
    assert compare(lanes["cs"], [[w[0], 0]], tol, w) == [          # cs never pulsed on the board
        "rising edge expected at 140 us not seen within 70 ns",
        "falling edge expected at 141 us not seen within 70 ns"]
    assert len(d["clk_sipo"]) == 1 + 2 * 136     # 136 cycles, all inside the 160 us record
