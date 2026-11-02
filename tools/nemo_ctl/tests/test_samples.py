"""Verification plan Step 3 (2026-11-01): samples.py, the PC side of sample_cell.sv, and
SeqLink's sampler methods. Records are made here by sampling the expected wave at the
cell's sample times, so a correct board would give exactly these words."""
import pytest
import yaml

from nemo_ctl.config import config_from_dict
from nemo_ctl.link import LinkError, SeqLink, V2_SAMPLER, V2_SAMPLES
from nemo_ctl.samples import (LOOPBACK_PINS, Record, SampleError, compare, decode, default_tol_ns,
                              make_setup, record_window, sample_times_ns, to_csv, to_vcd,
                              words_from_bytes)
from nemo_ctl.waves import mode_waves

PINS = ["clk_sipo", "sipo_in", "cs", "clk_piso"]      # a made-up wiring: bit k = PINS[k]


def _level(segs, t):
    lvl = segs[0][1]
    for ts, v in segs:
        if ts <= t:
            lvl = v
    return int(lvl)


def _record(setup, lanes, trig_count=0, shift_ns=0.0):
    """What the cell would hold: each sampled pin's expected level at its sample time."""
    rec = Record(words=tuple([0] * setup.n), trig_idx=setup.pre, trig_count=trig_count)
    words = []
    for t in sample_times_ns(setup, rec):
        w = 0
        for pin, bit in zip(setup.pins, setup.bits):
            w |= _level(lanes[pin], t - shift_ns) << bit
        words.append(w)
    return Record(tuple(words), setup.pre, trig_count)


CLOCK = [[0, 1]] + [[500 * k, (k + 1) % 2] for k in range(1, 40)]   # 1 MHz from 0, high first


# ---- setup ----

def test_setup_quantizes_and_reports():
    s = make_setup({"pins": ["cs", "clk_sipo"], "rate": "10MHz", "samples": 2000, "pre": 100,
                    "trigger": "rise", "on": "clk_piso"}, PINS)
    assert (s.div, s.n, s.pre, s.trig_pin, s.bits) == (10, 2000, 100, "clk_piso", (2, 0))
    assert s.cfg() == {"cfg_div": 10, "cfg_n": 2000, "cfg_pre": 100, "cfg_trig": 2,
                       "cfg_trig_pin": 3, "trig_step": 0}
    assert s.span_ns == 200_000 and "every 100 ns (10 MHz), 2000 samples = 200 us" in s.summary()
    assert make_setup({"pins": "cs, clk_sipo", "period": "10ns"}, PINS).div == 1
    e = make_setup({"pins": ["cs"], "rate": "1MHz", "trigger": "ext", "step": 2, "pre": 5}, PINS)
    assert e.cfg()["trig_step"] == 2 and "at the start of step 2" in e.summary()


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
    ({"pins": ["cs"], "rate": "1MHz", "samples": 10, "pre": 10, "trigger": "ext", "step": 1}, "pre=10"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "rise"}, "needs `on"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "rise", "on": "shift"}, "not wired to the sample cell"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "ext", "step": 1, "on": "cs"}, "has no pin"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "ext"}, "needs `step"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "ext", "step": 300}, "0..255"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "rise", "on": "cs", "step": 1}, "only for trigger ext"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "now", "pre": 3}, "set pre to 0"),
    ({"pins": ["cs"], "rate": "1MHz", "trigger": "soon"}, "one of now"),
])
def test_setup_errors(params, msg):
    with pytest.raises(SampleError, match=msg):
        make_setup(params, PINS)


def test_more_pins_wired_than_the_cell_has():
    with pytest.raises(SampleError, match="4 pins wired, the cell records 2"):
        make_setup({"pins": PINS[:1], "rate": "1MHz"}, PINS, n_bits=2)


def test_the_trigger_pin_need_not_be_shown():
    s = make_setup({"pins": ["cs"], "rate": "1MHz", "trigger": "fall", "on": "clk_sipo"}, PINS)
    assert s.trig_bit == 0 and s.pins == ("cs",)


# ---- decode / compare ----

def test_sample_times_follow_the_cell():
    s = make_setup({"pins": ["cs"], "rate": "10MHz", "samples": 4, "pre": 2, "trigger": "ext", "step": 1}, PINS)
    # trigger was sample 7 since arming and sits at index 2: the record starts with sample 5
    rec = Record((0, 0, 0, 0), trig_idx=2, trig_count=7)
    assert sample_times_ns(s, rec) == [(k * 10 + 1 - 2) * 10 for k in (5, 6, 7, 8)]


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


def test_bits_follow_the_wiring_not_the_list_order():
    s = make_setup({"pins": ["cs", "clk_sipo"], "rate": "10MHz", "samples": 3}, PINS)
    d = decode(s, Record((0b0100, 0b0001, 0b0101), 0, 0))     # cs = bit 2, clk_sipo = bit 0
    assert [v for _, v in d["cs"]] == [1, 0, 1] and [v for _, v in d["clk_sipo"]] == [0, 1]
    assert words_from_bytes(bytes([1, 0, 0, 0, 2, 0, 0, 0])) == [1, 2]
    assert words_from_bytes(bytes([1, 0, 2, 0]), 16) == [1, 2]
    with pytest.raises(SampleError):
        words_from_bytes(b"\x01\x02\x03")


def test_against_a_real_waves_lane():
    """The INFERENCE mode's clk_sipo / cs as waves.py draws them, recorded by a good board."""
    from pathlib import Path
    text = (Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml").read_text()
    cfg = config_from_dict(yaml.safe_load(text.replace('data: "0x5AA55A0FF0123456789ABCDEF0C3C3E7E7",', 'data: "0x5A",')))
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


# ---- export ----

def test_csv_and_vcd():
    s = make_setup({"pins": ["cs", "clk_sipo"], "rate": "10MHz", "samples": 3}, PINS)
    rec = Record((0b0100, 0b0001, 0b0101), 0, 0)
    assert to_csv(s, rec) == "t_ns,cs,clk_sipo\n-10,1,0\n90,0,1\n190,1,1\n"
    v = to_vcd(s, rec)
    assert "$var wire 1 ! cs $end" in v and '$var wire 1 " clk_sipo $end' in v
    body = v.split("$enddefinitions $end\n")[1].split("\n")
    assert body[:7] == ["#0", "1!", '0"', "#100", "0!", '1"', "#200"] and body[7] == "1!"
    assert body[8] == "#300"             # end marker one sample after the last
    assert "first sample at -10 ns from RUN" in v


# ---- the link (SeqLink sampler_*, against a register image) ----

class _RegLink(SeqLink):
    """SeqLink whose read_reg / write_reg hit a dict (sample_loopback_top's map)."""
    def __init__(self, has_sampler=True, words=(), status=(0b110, 0, 0)):
        self.regs = {}
        self.target = None
        if has_sampler:
            self.regs[V2_SAMPLER + 20], self.regs[V2_SAMPLER + 21] = 16, 12
        st, idx, cnt = status
        self.regs[V2_SAMPLER + 11] = st
        for i, b in enumerate(len(words).to_bytes(2, "little") + idx.to_bytes(2, "little") + cnt.to_bytes(4, "little")):
            self.regs[V2_SAMPLER + 12 + i] = b
        for i, w in enumerate(words):
            self.regs[V2_SAMPLES + 2 * i], self.regs[V2_SAMPLES + 2 * i + 1] = w & 0xFF, w >> 8
        self.reads = []

    def read_reg(self, addr, length):
        assert length <= 255
        self.reads.append((addr, length))
        return bytes(self.regs.get(addr + i, 0) for i in range(length))

    def write_reg(self, addr, data):
        for i, b in enumerate(data):
            self.regs[addr + i] = b


def test_link_info_and_setup_bytes():
    ln = _RegLink()
    assert ln.sampler_info() == (16, 4096)
    s = make_setup({"pins": ["clk", "rst_in"], "rate": "5MHz", "samples": 400, "pre": 50,
                    "trigger": "ext", "step": 1}, list(LOOPBACK_PINS))
    ln.sampler_setup(s)
    assert [ln.regs[V2_SAMPLER + i] for i in range(11)] == [20, 0, 0, 0, 0x90, 0x01, 50, 0, 1, 0, 1]
    with pytest.raises(LinkError, match="no sampler"):
        _RegLink(has_sampler=False).sampler_info()


def test_link_reads_the_record_in_frames():
    words = tuple((i * 37) & 0x3FF for i in range(250))
    ln = _RegLink(words=words, status=(0b110, 50, 499))
    st = ln.sampler_status()
    assert st == {"armed": False, "triggered": True, "done": True, "n_valid": 250, "trig_idx": 50, "trig_count": 499}
    rec = ln.read_samples()
    assert rec.words == words and (rec.trig_idx, rec.trig_count, rec.done) == (50, 499, True)
    sample_reads = [r for r in ln.reads if r[0] >= V2_SAMPLES]
    assert sample_reads == [(V2_SAMPLES, 200), (V2_SAMPLES + 200, 200), (V2_SAMPLES + 400, 100)]


class _BoardLink(_RegLink):
    """_RegLink plus the sequence commands cmd_seq_sample uses."""
    def __init__(self, **kw):
        super().__init__(**kw)
        self.calls = []

    def start(self): self.calls.append("start")
    def wait(self, t):
        from nemo_ctl.sequence import SeqResult
        self.calls.append(("wait", t)); return SeqResult(done=True, fault=False, step=5)
    def seq_status(self):
        from nemo_ctl.link import V2Status
        return V2Status.decode(0b100)
    def close(self): self.calls.append("close")


def test_cli_seq_sample_on_a_fake_board(tmp_path, monkeypatch, capsys):
    from nemo_ctl import cli
    # clk (bit 0) toggling every sample, rst (bit 1) high then low; jumpers in -> bits 5, 6 follow
    words = tuple(((i & 1) | (int(i < 3) << 1)) * 0b100001 for i in range(8))
    board = _BoardLink(words=words, status=(0b110, 2, 40))
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: board)
    out = tmp_path / "r.vcd"
    rc = cli.main(["seq", "sample", "--jtag", "--rate", "10MHz", "--samples", "8", "--pre", "2",
                   "--trigger", "ext", "--step", "1", "--pins", "clk,rst,rst_in", "--run", "--wait", "3",
                   "--out", str(out)])
    text = capsys.readouterr().out
    assert rc == 0 and board.calls == ["start", ("wait", 3.0), "close"]
    assert [board.regs[V2_SAMPLER + i] for i in (0, 4, 6, 8, 10)] == [10, 8, 2, 1, 1]
    assert "record: 8 samples, trigger at index 2 (sample 40 since the start); triggered done" in text
    assert "rst      starts 1, 1 edges: fall" in text and "rst_in   starts 1, 1 edges" in text
    assert out.read_text().startswith("$comment sample_cell record")
    capsys.readouterr()
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _BoardLink(has_sampler=False))
    assert cli.main(["seq", "sample", "--jtag", "--rate", "1MHz"]) == 1
    assert "no sampler" in capsys.readouterr().err
