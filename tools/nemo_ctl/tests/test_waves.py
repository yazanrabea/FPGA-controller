"""waves.py: real edge times per pin, the same rules as sig_cell.sv (1 tick = 10 ns)."""
import pytest

from nemo_ctl import gui
from nemo_ctl.config import config_from_dict, config_to_dict, load_config
from nemo_ctl.waves import MAX_EDGES, WaveError, mode_waves


def _cfg(block):
    return config_from_dict({"modes": {"M": {"B": block}}})


def _lane(w, key):
    return next(ln for ln in w["lanes"] if ln["key"] == key)


def test_clock_starts_high_with_its_delay_and_stops_after_cycles():
    w = mode_waves(_cfg({"c": {"type": "CLOCK", "freq": "1MHz", "cycles": 3, "delay": "2us"}}), "M")
    seg = _lane(w, "c")["segments"]
    assert seg == [[0, 0], [2000, 1], [2500, 0], [3000, 1], [3500, 0], [4000, 1], [4500, 0]]
    assert w["end"] == 5000 and _lane(w, "c")["idle"] == 0


def test_active_low_pulse_idles_high_and_repeats():
    w = mode_waves(_cfg({"r": {"type": "PULSE", "width": "100ns", "delay": "1us", "polarity": "active_low",
                               "repeat": 2, "period": "1us"}}), "M")
    ln = _lane(w, "r")
    assert ln["idle"] == 1
    assert ln["segments"] == [[0, 1], [1000, 0], [1100, 1], [2000, 0], [2100, 1]]


def test_serial_shifts_each_bit_on_its_clock_edge():
    w = mode_waves(_cfg({
        "k": {"type": "CLOCK", "freq": "1MHz", "cycles": 8},
        "d": {"type": "SERIAL", "clock": "k", "data": "0xA5", "bits": 8, "msb_first": True, "data_edge": "falling"},
    }), "M", 0, 12000)
    # 0xA5 = 1010 0101, MSB first; the bit changes 20 ns (2 ticks, sig_cell's registered strobe +
    # shift, measured in xsim 2026-10-26) after each falling edge (500, 1500, ...); after bit 0, back to 0
    assert _lane(w, "d")["segments"] == [[0, 1], [520, 0], [1520, 1], [2520, 0], [4520, 1],
                                         [5520, 0], [6520, 1], [7520, 0]]


def test_lsb_first_and_rising_edge():
    w = mode_waves(_cfg({
        "k": {"type": "CLOCK", "freq": "1MHz", "cycles": 4},
        "d": {"type": "SERIAL", "clock": "k", "data": "0b0011", "bits": 4, "msb_first": False,
              "data_edge": "rising", "delay": "100ns"},
    }), "M", 0, 6000)
    # LSB first: 1,1,0,0; rising edges after 100 ns: 1000, 2000, 3000 (+20 ns each), back to 0 after
    # the 4th bit. The first bit is on the pin from its delay, with no lag (it isn't strobe-driven)
    seg = _lane(w, "d")["segments"]
    assert seg[:3] == [[0, 0], [100, 1], [2020, 0]]


def test_constants_buses_and_outputs():
    w = mode_waves(_cfg({
        "lo": {"type": "LOW"}, "hi": {"type": "HIGH"},
        "s_p": {"type": "BUS", "value": 5},
        "o": {"type": "CAPTURE", "mode": "level"},
    }), "M")
    assert _lane(w, "lo")["segments"] == [[0, 0]] and _lane(w, "hi")["segments"] == [[0, 1]]
    assert _lane(w, "s_p")["kind"] == "bus" and _lane(w, "s_p")["segments"][0][1] == "0b101"
    assert _lane(w, "o")["kind"] == "output"


def test_window_returns_only_its_part_and_dense_clock_is_flagged():
    cfg = _cfg({"c": {"type": "CLOCK", "freq": "10MHz"}})
    part = _lane(mode_waves(cfg, "M", 1000, 1300), "c")["segments"]
    assert part[0] == [1000, 1] and all(1000 <= t <= 1300 for t, _ in part)
    wide = _lane(mode_waves(cfg, "M", 0, 1e9), "c")
    assert wide["kind"] == "dense" and len(wide["segments"]) == 1
    assert len(_lane(mode_waves(cfg, "M", 0, 1000 * (MAX_EDGES // 4)), "c")["segments"]) <= MAX_EDGES + 2


def test_bad_settings_become_error_lanes_not_crashes():
    w = mode_waves(_cfg({
        "c": {"type": "CLOCK", "freq": "fast"},
        "d": {"type": "SERIAL", "clock": "nope", "data": "0x1", "bits": 1},
        "e": {"type": "SERIAL", "clock": "c", "data": "0x", "bits": 4},
    }), "M")
    assert all(_lane(w, k)["kind"] == "error" for k in ("c", "d", "e"))
    assert "isn't a CLOCK" in _lane(w, "d")["label"]


def test_bad_window_is_an_error():
    with pytest.raises(WaveError):
        mode_waves(_cfg({"lo": {"type": "LOW"}}), "M", 500, 100)


def test_example_inference_mode():
    w = mode_waves(load_config(), "INFERENCE")
    keys = [ln["key"] for ln in w["lanes"]]
    assert "clk_sipo" in keys and "cs" in keys
    cs = _lane(w, "cs")["segments"]
    assert [140000, 1] in cs and [141000, 0] in cs         # cs: 1 us pulse at 140 us
    assert w["end"] == 150000 + 168 * 1000                  # clk_piso: 168 cycles from 150 us


def test_waves_payload_uses_the_unsaved_edit_and_reports_errors():
    d = config_to_dict(load_config())
    d["modes"]["INFERENCE"]["SIPO"]["cs"]["delay"] = "10us"
    w = gui.waves_payload(dict(d, mode="INFERENCE"))
    assert [10000, 1] in _lane(w, "cs")["segments"]
    assert "error" in gui.waves_payload(dict(d, mode="INFERENCE", t0=5, t1=1))


def test_dft_lane_label_uses_the_configured_adc_and_4_s_bits():
    # review 2026-10-26: the label printed b_value as the ADC number and s as 3 bits
    # (s drives 4 pins, s0..s3_dft)
    w = mode_waves(_cfg({"dft_select": {"type": "DFT_HELPER", "adc": 3, "signal": "phi1"}}), "M")
    ln = _lane(w, "dft_select")
    assert ln["kind"] == "bus" and ln["label"].startswith("ADC 3, phi1")
    assert "s=0001" in ln["label"] and ln["segments"][0][1].endswith("s=0001")
