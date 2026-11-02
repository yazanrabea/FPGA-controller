"""The sampler in chip_top / vchip_top (SAMPLER = 1, decided 2026-11-02 after EXP-11): the
PC side (samples.chip_layout, SeqLink.read_samples with 4-byte samples at 0x8000, `cli seq
sample --target chip_top`). The RTL's own record is checked in fpga/tb/chip_top_tb.sv check 8
(every sample = the pins at the tick samples.sample_times_ns gives)."""
from pathlib import Path

import yaml

from nemo_ctl import cli
from nemo_ctl.samples import CHIP_SAMPLES_BASE, LOOPBACK_LAYOUT, Record, chip_layout, make_setup, sample_times_ns
from nemo_ctl.sequence import chip_target
from nemo_ctl.seqwaves import sequence_waves
from nemo_ctl.tests.test_samples import _BoardLink

SEQ = Path(__file__).resolve().parents[3] / "config" / "chip_sim_test.yaml"
STEPS = yaml.safe_load(SEQ.read_text())["steps"]
CHIP = chip_target()
L = chip_layout()
# step starts (ns from RUN): step 0 one tick before RUN, idle 5 us, sipo_load 145 us
S = {0: -10.0, 1: 4990.0, 2: 149990.0}


def test_chip_layout_is_chip_tops_wiring():
    outs = [c.name for c in CHIP.sig_cells]
    ins = [c.name for c in CHIP.cap_cells]
    assert L.pins == tuple(outs + ins) and len(outs) == 22 and len(ins) == 4
    assert L.step_field == (26, 4) and L.bits == 32 and L.samples_base == CHIP_SAMPLES_BASE == 0x8000
    assert L.pairs == {} and LOOPBACK_LAYOUT.bits == 16 and LOOPBACK_LAYOUT.samples_base == 0x4000


def _level(segs, t):
    lvl = segs[0][1] if segs else 0
    for ts, v in segs:
        if ts <= t:
            lvl = v
    return int(lvl)


def _good_record(setup, first_sample=0):
    """What a good chip_top records: every output on its expected wave, the chip outputs 0
    (no chip), the step number in bits 26-29."""
    rec = Record(tuple([0] * setup.n), 0, first_sample)
    exp = sequence_waves(STEPS, S, 400e3)
    words = []
    for t in sample_times_ns(setup, rec):
        w = 0
        for k, pin in enumerate(L.pins[:22]):
            w |= _level(exp[pin], t) << k
        w |= max(k for k, a in S.items() if a <= t) << L.step_field[0]
        words.append(w)
    return Record(tuple(words), 0, first_sample)


def _setup():
    return make_setup({"pins": list(L.pins), "rate": "10MHz", "samples": 3300}, list(L.pins), n_bits=32)


def test_read_samples_four_bytes_at_0x8000_in_short_frames():
    words = tuple((i * 0x01010101 * 7) & 0xFFFFFFFF for i in range(130))
    ln = _BoardLink(words=words, status=(0b110, 0, 0), bits=32, base=0x8000)
    assert ln.sampler_info() == (32, 4096)
    rec = ln.read_samples(32, 0x8000)
    assert rec.words == words
    reads = [r for r in ln.reads if r[0] >= 0x8000]
    assert reads == [(0x8000, 252), (0x8000 + 252, 252), (0x8000 + 504, 16)]   # 63 samples a frame


def test_cli_chip_top_record_passes_and_a_stuck_pin_fails(tmp_path, monkeypatch, capsys):
    rec = _good_record(_setup())
    board = _BoardLink(words=rec.words, status=(0b110, 0, 0), bits=32, base=0x8000)
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: board)
    out = tmp_path / "c.vcd"
    # no --target: taken from the --check file's `target: chip_top`
    args = ["seq", "sample", "--jtag", "--rate", "10MHz", "--samples", "3300", "--read-only",
            "--check", str(SEQ), "--out", str(out)]
    assert cli.main(args) == 0
    text = capsys.readouterr().out
    assert "sampler (chip_top)" in text and "inputs: shown, not judged" in text
    assert "PASS: 22 pass, 0 fail, 5 not judged" in text          # (steps) + the 4 chip outputs
    assert "step 1 at" not in text and "starts: 1 at 0.00499 ms, 2 at 0.14999 ms" in text
    v = out.read_text()
    assert "$var wire 4" in v and "clk_sipo_exp" in v and "piso_out " in v
    stuck = tuple(w & ~(1 << L.pins.index("clk_sipo")) for w in rec.words)
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _BoardLink(words=stuck, status=(0b110, 0, 0),
                                                                         bits=32, base=0x8000))
    assert cli.main(args) == 1
    text = capsys.readouterr().out
    assert "FAIL: 21 pass, 1 fail" in text
    assert [l.split()[0] for l in text.splitlines() if l.rstrip().endswith("FAIL") or " FAIL " in l] == ["clk_sipo"]


def test_cli_refuses_a_target_whose_layout_doesnt_match(monkeypatch, capsys):
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _BoardLink(bits=16))      # a loopback bitstream
    assert cli.main(["seq", "sample", "--jtag", "--target", "chip_top", "--rate", "1MHz", "--read-only"]) == 1
    assert "16-bit samples, chip_top's layout is 32 bits: wrong --target?" in capsys.readouterr().err
