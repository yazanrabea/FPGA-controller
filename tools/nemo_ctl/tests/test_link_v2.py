"""Phase 7 round 2: link v2 (SeqLink), the step-entry layout, the generated packages.

`_FakeV2` is an in-memory model of phase7_link_top.sv's register map (docs/
link_register_map.md, v2) at the frame level -- the same rules
fpga/tb/phase7_link_top_tb.sv checks on the real RTL over UART. It decodes the table
it receives with the layout offsets, and "runs" a sequence by making data_in grow by
the width of the `en` pulse in step 1 (a stand-in for a Y-Flash cell nudged by a
program pulse), so program_verify() can be exercised end to end. Not the hardware:
see docs/experiments/EXP-04 (pending) for that.
"""
from __future__ import annotations

import copy
import re
from pathlib import Path

import pytest
import yaml

from nemo_ctl import gen_svh, link
from nemo_ctl.sequence import (
    ENTRY_BYTES, PHASE7_LOOPBACK, SequenceError, compile_steps, encode_step, entry_layout,
    link_late_warnings, load_sequence, program_verify,
)

CONFIG = Path(__file__).resolve().parents[3] / "config" / "phase7_seq_loopback.yaml"
STEPS = yaml.safe_load(CONFIG.read_text())["steps"]
LAY = entry_layout()
STRIDE = link.v2_cap_stride(PHASE7_LOOPBACK)


def u32(b, off):
    return int.from_bytes(b[off:off + 4], "little")


class _FakeV2:
    def __init__(self, busy_polls=2, fault=False):
        self.table = bytearray(16 * ENTRY_BYTES)
        self.n_steps = 1
        self.scratch = 0
        self.busy = False
        self.done = self.faulted = self.aborted = self.rejected = False
        self.busy_polls, self.polls_left, self.fault_next = busy_polls, 0, fault
        self.last_step = 0
        self.data_in = 0
        self.runs = self.applies = 0
        self.writes: list[tuple[int, int]] = []

    def status(self):
        return (int(self.busy) << 1 | int(self.done) << 2 | int(self.faulted) << 3
                | int(self.aborted) << 4 | int(self.rejected) << 6)

    def step_field(self, k, cell, field, n=4):
        o = k * ENTRY_BYTES + LAY.sig_base[PHASE7_LOOPBACK.sig_index(cell)] + field
        return int.from_bytes(self.table[o:o + n], "little")

    def read_byte(self, a):
        if a == link.V2_SCRATCH:
            return self.scratch
        if a == link.V2_STATUS:
            return self.status()
        if a == link.V2_LAST_STEP:
            return self.last_step
        if a == link.V2_N_STEPS:
            return self.n_steps
        if link.V2_CAP_BASE <= a < link.V2_CAP_BASE + 5 * STRIDE:
            k, off = divmod(a - link.V2_CAP_BASE, STRIDE)
            if k == PHASE7_LOOPBACK.cap_index("data_in") and link.V2_CAP_DATA <= off < link.V2_CAP_DATA + 2:
                return (self.data_in >> 8 * (off - link.V2_CAP_DATA)) & 0xFF
        return 0

    def handle(self, frame):
        cmd, addr, data = link.parse_frame(frame)
        if cmd == link.CMD_WRITE_REG:
            for i, b in enumerate(data):
                a = addr + i
                self.writes.append((a, b))
                if a == link.V2_SCRATCH:
                    self.scratch = b
                elif a == link.V2_STATUS:
                    self.rejected = False
                elif a == link.V2_N_STEPS:
                    if self.busy:
                        self.rejected = True
                    else:
                        self.n_steps = min(max(b, 1), 16)
                elif link.V2_TABLE_BASE <= a < link.V2_TABLE_BASE + len(self.table):
                    if self.busy:
                        self.rejected = True
                    else:
                        self.table[a - link.V2_TABLE_BASE] = b
            return b""
        if cmd == link.CMD_READ_REG:
            return link.build_frame(cmd, addr, bytes(self.read_byte(addr + i) for i in range(len(data))))
        if cmd == link.CMD_READ_CAPTURE:
            return link.build_frame(cmd, addr, bytes(self.read_byte(link.V2_CAP_BASE + addr + i)
                                                    for i in range(len(data))))
        if cmd == link.CMD_STATUS:
            if self.busy:
                self.polls_left -= 1
                if self.polls_left <= 0:
                    self.busy = False
                    self.faulted = self.fault_next
                    self.done = not self.fault_next
                    self.last_step = 1 if self.fault_next else self.n_steps - 1
                    if self.done:  # the "cell": +width of step 1's en pulse
                        self.data_in += self.step_field(1, "en", LAY.SIG_PARAM_A)
            return link.build_frame(cmd, link.V2_STATUS, bytes([self.status()]))
        if cmd == link.CMD_RUN:
            if not self.busy:
                self.runs += 1
                self.busy, self.done, self.faulted, self.aborted = True, False, False, False
                self.polls_left = self.busy_polls
            return b""
        if cmd == link.CMD_STOP:
            if self.busy:
                self.busy, self.aborted = False, True
            return b""
        if cmd == link.CMD_APPLY:
            self.applies += 1
            return b""
        return link.build_frame(link.CMD_NACK, 0, b"")


class _T:
    def __init__(self, dev):
        self.dev, self.buf = dev, bytearray()

    def write(self, data):
        self.buf += self.dev.handle(bytes(data))

    def read(self, size, timeout=None):
        got = bytes(self.buf[:size])
        del self.buf[:size]
        return got


def _seqlink(dev):
    t = [0.0]
    return link.SeqLink(_T(dev), clock=lambda: t[0], sleep=lambda s: t.__setitem__(0, t[0] + s))


def _table(edit=None):
    s = copy.deepcopy(STEPS)
    if edit:
        edit(s)
    return compile_steps(s)


# ---------------------------------------------------------------- layout + packages

def test_layout_is_148_bytes_with_the_planned_offsets():
    assert (LAY.hdr_bytes, LAY.used_bytes) == (12, 148)
    assert LAY.sig_base == (12, 34, 56, 79, 101)  # data cell is 2 bytes wider (SERIAL_W 16)
    assert LAY.cap_base == (123, 128, 133, 138, 143)


def test_generated_link_package_matches_the_layout():
    text = gen_svh.generate_phase7_link()

    def lp(name):
        m = re.search(rf"localparam int {name} = (\d+);", text)
        assert m, name
        return int(m.group(1))
    assert lp("USED_BYTES") == LAY.used_bytes and lp("HDR_BYTES") == LAY.hdr_bytes
    assert lp("ENTRY_BYTES") == ENTRY_BYTES and lp("CAP_STRIDE") == STRIDE
    for i, c in enumerate(PHASE7_LOOPBACK.sig_cells):
        assert lp(f"{c.name.upper()}_BASE") == LAY.sig_base[i]
    for i, c in enumerate(PHASE7_LOOPBACK.cap_cells):
        assert lp(f"{c.name.upper()}_BASE") == LAY.cap_base[i]
    assert lp("H_COND_ARG") == LAY.cond_arg and lp("F_SIG_DATA") == LAY.SIG_DATA
    assert "localparam logic [15:0] TABLE_BASE = 16'h1000;" in text


def test_encode_step_fields():
    t = load_sequence(CONFIG)
    e = encode_step(t.steps[2], LAY)  # 'load'
    assert e[LAY.sig_mask] == 0b00101 and e[LAY.cap_mask] == 0b00101
    assert e[LAY.cond] == 2 and e[LAY.cond_cell] == 2 and u32(e, LAY.timeout) == 500_000_000
    clk = LAY.sig_base[0]
    assert e[clk] == 3 | 1 << 4 and u32(e, clk + LAY.SIG_PARAM_A) == 25_000_000 and u32(e, clk + LAY.SIG_CYCLES) == 8
    data = LAY.sig_base[2]
    assert e[data] == 4 | 1 << 4 and int.from_bytes(e[data + 21:data + 23], "little") == 0xA500
    assert e[LAY.cap_base[2]] == 3 | 1 << 2 and u32(e, LAY.cap_base[2] + 1) == 8


def test_table_package_holds_the_encoded_steps():
    text = gen_svh.phase7_table_package(scale=1e-4)
    assert "SIMULATION ONLY" in text and "N_STEPS = 6;" in text
    v = int(re.search(r"TABLE = \d+'h([0-9a-f]+);", text).group(1), 16)
    img = v.to_bytes(6 * ENTRY_BYTES, "little")
    t = load_sequence(CONFIG, scale=1e-4)
    for k in range(6):
        assert img[k * ENTRY_BYTES:k * ENTRY_BYTES + LAY.used_bytes] == encode_step(t.steps[k], LAY)


def test_link_late_warning_for_a_short_fixed_step():
    t = _table(lambda s: s[1].update(until={"after": "200ns"}))  # 20 ticks < ~40
    w = link_late_warnings(t)
    assert len(w) == 1 and "step 2 (load) will start late" in w[0]
    assert link_late_warnings(load_sequence(CONFIG)) == []


def test_cli_table_out_only_with_phase7_link(tmp_path):
    with pytest.raises(SystemExit):
        gen_svh.main(["--phase7", "--table-out", str(tmp_path / "x.sv")])
    with pytest.raises(SystemExit):
        gen_svh.main(["--phase7-link", "--time-scale", "1e-4"])  # scale without a table


def test_v2_status_decode():
    s = link.V2Status.decode(0b0110_0110)
    assert (s.run, s.busy, s.done, s.fault, s.aborted, s.late, s.table_rejected, s.rx_overflow) == \
        (False, True, True, False, False, True, True, False)


# ---------------------------------------------------------------- SeqLink

def test_load_writes_every_entry_n_steps_and_applies():
    dev = _FakeV2()
    t = load_sequence(CONFIG)
    _seqlink(dev).load(t)
    for k, st in enumerate(t.steps):
        assert bytes(dev.table[k * ENTRY_BYTES:k * ENTRY_BYTES + LAY.used_bytes]) == encode_step(st, LAY)
    assert dev.n_steps == 6 and dev.applies == 1
    assert dev.step_field(1, "rst", LAY.SIG_PARAM_A) == 50_000_000  # decoded back: 500 ms


def test_load_refused_while_running():
    dev = _FakeV2()
    sl = _seqlink(dev)
    sl.load(load_sequence(CONFIG))
    sl.start()
    with pytest.raises(link.LinkError, match="refused the table"):
        sl.load(load_sequence(CONFIG))
    assert not dev.rejected  # cleared by the client


def test_load_rejects_wrong_target_and_size():
    from dataclasses import replace
    t = load_sequence(CONFIG)
    with pytest.raises(link.LinkError, match="table is for"):
        _seqlink(_FakeV2()).load(replace(t, target=replace(PHASE7_LOOPBACK, name="other")))


def test_wait_polls_until_done_and_reads_last_step():
    dev = _FakeV2(busy_polls=5)
    sl = _seqlink(dev)
    sl.load(load_sequence(CONFIG))
    sl.start()
    r = sl.wait(timeout_s=1.0)
    assert r.done and not r.fault and r.step == 5


def test_wait_times_out_while_still_busy():
    dev = _FakeV2(busy_polls=10_000)
    sl = _seqlink(dev)
    sl.load(load_sequence(CONFIG))
    sl.start()
    r = sl.wait(timeout_s=0.05)  # fake clock: 5 polls of 10 ms
    assert not r.done and not r.fault


def test_read_capture_is_little_endian_data_in():
    dev = _FakeV2()
    dev.data_in = 0x12A5
    assert _seqlink(dev).read_capture("data_in") == 0x12A5


def _pulse_table(i):
    s = copy.deepcopy(STEPS)[:2]
    s[1] = {"name": "pulse", "set": {"en": {"type": "PULSE", "width": f"{10 * (i + 1)}ns"}},
            "until": {"after": "1us"}}
    return compile_steps(s)


def test_program_verify_over_the_v2_link():
    dev = _FakeV2()
    r = program_verify(_seqlink(dev), _pulse_table, "data_in", check=lambda v: v >= 6, max_iters=10)
    assert r.passed and r.iterations == 3 and r.history == [1, 3, 6] and dev.runs == 3


def test_program_verify_over_the_link_stops_on_fault():
    dev = _FakeV2(fault=True)
    with pytest.raises(SequenceError, match="faulted at step 1"):
        program_verify(_seqlink(dev), _pulse_table, "data_in", check=lambda v: False, max_iters=10)
    assert dev.runs == 1


# ---------------------------------------------------------------- CLI `seq`

def test_cli_seq_load_run_read_status_stop(monkeypatch, capsys):
    from nemo_ctl import cli
    dev = _FakeV2(busy_polls=3)
    dev.data_in = 0xA5
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _seqlink(dev))
    base = ["--port", "FAKE"]
    assert cli.main(["seq", "load", str(CONFIG)] + base) == 0
    assert dev.n_steps == 6 and dev.applies == 1
    assert cli.main(["seq", "run", "--wait", "1"] + base) == 0
    out = capsys.readouterr().out
    assert "loaded 6 steps" in out and "STATUS: done" in out and "last step 5" in out
    assert cli.main(["seq", "read", "data_in"] + base) == 0
    assert "data_in: capture 0x" in capsys.readouterr().out
    assert cli.main(["seq", "status"] + base) == 0
    assert "STATUS: done" in capsys.readouterr().out
    assert cli.main(["seq", "run"] + base) == 0 and dev.busy
    assert cli.main(["seq", "stop"] + base) == 0 and dev.aborted


def test_cli_seq_load_refuses_a_bad_sequence_before_touching_the_port(monkeypatch, tmp_path, capsys):
    from nemo_ctl import cli
    opened = []
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: opened.append(1))
    doc = yaml.safe_load(CONFIG.read_text())
    doc["steps"][0]["set"].pop("cs")
    bad = tmp_path / "bad.yaml"
    bad.write_text(yaml.safe_dump(doc))
    assert cli.main(["seq", "load", str(bad), "--port", "FAKE"]) == 1
    assert "step 0 must set every cell" in capsys.readouterr().err and not opened


def test_cli_seq_run_wait_returns_1_on_fault(monkeypatch):
    from nemo_ctl import cli
    dev = _FakeV2(fault=True)
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: _seqlink(dev))
    cli.main(["seq", "load", str(CONFIG), "--port", "FAKE"])
    assert cli.main(["seq", "run", "--wait", "1", "--port", "FAKE"]) == 1
