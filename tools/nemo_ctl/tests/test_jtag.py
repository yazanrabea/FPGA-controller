"""JTAG link step J4: nemo_ctl.jtag (scan format + JtagTransport), no hardware.

`_BridgeModel` is a ScanPort that models fpga/src/jtag_link_bridge.sv's rules (the
same ones fpga/tb/jtag_link_bridge_tb.sv checks on the real RTL): a scan is accepted
iff its own reply says ready; accepting takes its down bytes and consumes the up
bytes offered in that reply; `free` = down FIFO space. Behind it, the system side
cuts the down byte stream into link frames and feeds them to the existing frame-level
fakes (test_link._FakeDevice for Phase 5, test_link_v2._FakeV2 for Phase 7), so Link /
SeqLink run end to end over the JTAG transport. On the board: step J5.
"""
from __future__ import annotations

import pytest

from nemo_ctl import jtag, link
from nemo_ctl.jtag import DR_BYTES, MAXD, MAXU, JtagLinkError, JtagTransport
from nemo_ctl.tests.test_link import _FakeDevice
from nemo_ctl.tests.test_link_v2 import CONFIG, _FakeV2
from nemo_ctl.sequence import load_sequence


class _BridgeModel:
    def __init__(self, device, fifo=256, busy_after_accept=0, drain_per_scan=None):
        self.dev = device
        self.fifo = fifo
        self.busy_after_accept = busy_after_accept
        self.drain_per_scan = drain_per_scan     # None = the system side drains everything
        self.down = bytearray()                   # down FIFO
        self.up = bytearray()                     # up FIFO
        self.stream = bytearray()                 # system side: bytes not yet a whole frame
        self.busy = 0
        self.overflow = False
        self.n_acc = 0
        self.max_down = 0

    def scan(self, dr: bytes) -> bytes:
        assert len(dr) == DR_BYTES
        # ---- Capture: the reply, from the state before this scan ----
        ready = self.busy == 0
        offered = bytes(self.up[:MAXU]) if ready else b""
        rep = bytearray(DR_BYTES)
        rep[0:2] = b"jl"
        rep[2] = int(ready) | (int(self.overflow) << 1)
        rep[3] = len(offered)
        rep[4] = min(255, self.fifo - len(self.down))
        rep[5] = self.n_acc & 0xFF
        rep[8:8 + len(offered)] = offered
        # ---- Update ----
        valid = dr[0:2] == b"JL" and dr[2] <= MAXD
        if ready and valid:
            n = dr[2]
            for b in dr[4:4 + n]:
                if len(self.down) < self.fifo:
                    self.down.append(b)
                else:
                    self.overflow = True
            self.max_down = max(self.max_down, len(self.down))
            del self.up[:len(offered)]
            self.n_acc += 1
            self.busy = self.busy_after_accept
        elif self.busy:
            self.busy -= 1
        # ---- system side, between scans ----
        k = len(self.down) if self.drain_per_scan is None else min(self.drain_per_scan, len(self.down))
        self.stream += self.down[:k]
        del self.down[:k]
        while len(self.stream) >= 5:
            if self.stream[0] != link.SOF:
                del self.stream[0]
                continue
            total = 6 + self.stream[4]
            if len(self.stream) < total:
                break
            frame = bytes(self.stream[:total])
            del self.stream[:total]
            self.up += self.dev.handle(frame)
        return bytes(rep)


class _Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 0.001                           # every look at the clock = 1 ms (one scan)
        return self.t


def _link(model, timeout=1.0):
    return link.Link(JtagTransport(model, timeout=timeout, clock=_Clock()))


# ---------------------------------------------------------------------------
# scan format
# ---------------------------------------------------------------------------
def test_pack_down_layout():
    dr = jtag.pack_down(b"\x01\x02\x03")
    assert len(dr) == DR_BYTES
    assert dr[0:4] == b"JL\x03\x00" and dr[4:7] == b"\x01\x02\x03" and dr[7:] == bytes(DR_BYTES - 7)


def test_pack_down_rejects_too_much():
    with pytest.raises(ValueError):
        jtag.pack_down(bytes(MAXD + 1))


def test_parse_up_fields():
    rep = bytearray(DR_BYTES)
    rep[0:8] = b"jl\x03\x02\x40\x07\x00\x00"
    rep[8:10] = b"\xAA\xBB"
    up = jtag.parse_up(bytes(rep))
    assert up.ready and up.overflow and up.free == 0x40 and up.n_accepted == 7 and up.data == b"\xAA\xBB"


def test_parse_up_no_magic_explains():
    with pytest.raises(JtagLinkError, match="JTAG link top"):
        jtag.parse_up(bytes(DR_BYTES))            # e.g. the board runs another design


def test_parse_up_too_many_up_bytes():
    rep = bytearray(DR_BYTES)
    rep[0:4] = b"jl\x01" + bytes([MAXU + 1])
    with pytest.raises(JtagLinkError):
        jtag.parse_up(bytes(rep))


def test_hex_is_byte0_first():
    # EXP-05: xsdb -hex strings are byte-little-endian, each byte a normal pair
    assert jtag.to_hex(b"\xC1\x02") == "C102"
    assert jtag.from_hex("c102\n") == b"\xC1\x02"


# ---------------------------------------------------------------------------
# Link (Phase 5 map) over JTAG
# ---------------------------------------------------------------------------
def test_link_status_run_stop_over_jtag():
    dev = _FakeDevice()
    lk = _link(_BridgeModel(dev))
    assert lk.status() is False
    lk.run()
    assert lk.status() is True
    lk.stop()
    assert lk.status() is False


def test_link_write_read_over_jtag():
    dev = _FakeDevice()
    lk = _link(_BridgeModel(dev))
    lk.write_reg(0x0010, b"\x03\x00\x00\x00\x00\x14\x00\x00\x00")
    assert lk.read_reg(0x0010, 9) == b"\x03\x00\x00\x00\x00\x14\x00\x00\x00"
    assert dev.regs[0x0015] == 0x14


def test_frame_longer_than_one_scan():
    dev = _FakeDevice()
    model = _BridgeModel(dev)
    t = JtagTransport(model, clock=_Clock())
    lk = link.Link(t)
    payload = bytes(range(120))                   # frame = 126 bytes > MAXD = 124
    lk.write_reg(0x0010, payload)
    assert bytes(dev.regs[0x0010:0x0010 + 120]) == payload
    assert t.n_scans >= 2


def test_not_ready_scans_are_retried():
    dev = _FakeDevice()
    model = _BridgeModel(dev, busy_after_accept=1)    # every scan right after an accepted one: ready=0
    t = JtagTransport(model, clock=_Clock())
    lk = link.Link(t)
    lk.write_reg(0x0000, b"\x5A")
    assert lk.read_reg(0x0000, 1) == b"\x5A"
    assert t.n_rejected > 0


def test_credit_never_overflows_a_slow_fifo():
    dev = _FakeDevice()
    model = _BridgeModel(dev, fifo=40, drain_per_scan=7)
    lk = _link(model, timeout=10.0)
    for k in range(6):
        lk.write_reg(0x0010, bytes([k]) * 30)      # 36-byte frames into a 40-byte FIFO
    assert not model.overflow and model.max_down <= 40
    # write() returns once the bridge has ACCEPTED the bytes (like a UART send); the last
    # frame may still sit in the slow FIFO. A request behind it is answered only after it.
    lk.status()
    assert dev.regs[0x0010:0x0010 + 30] == bytes([5]) * 30


def test_overflow_flag_raises():
    model = _BridgeModel(_FakeDevice())
    model.overflow = True
    with pytest.raises(JtagLinkError, match="overflow"):
        _link(model).status()


def test_board_without_bridge_raises_clearly():
    class _Zeros:
        def scan(self, dr):
            return bytes(DR_BYTES)
    with pytest.raises(JtagLinkError, match="JTAG link top"):
        _link(_Zeros()).status()


def test_no_response_times_out():
    class _Silent(_FakeDevice):
        def handle(self, frame):
            return b""                            # swallows every request
    with pytest.raises(link.LinkTimeoutError):
        _link(_BridgeModel(_Silent()), timeout=0.05).status()


def test_write_times_out_if_never_ready():
    model = _BridgeModel(_FakeDevice(), busy_after_accept=10**9)
    model.busy = 10**9
    t = JtagTransport(model, timeout=0.05, clock=_Clock())
    with pytest.raises(link.LinkTimeoutError):
        t.write(b"\xAA")


# ---------------------------------------------------------------------------
# SeqLink (Phase 7 v2 map) over JTAG
# ---------------------------------------------------------------------------
def test_seqlink_load_and_run_over_jtag():
    dev = _FakeV2()
    clock = _Clock()
    sl = link.SeqLink(JtagTransport(_BridgeModel(dev, busy_after_accept=1), timeout=5.0, clock=clock),
                      clock=clock, sleep=lambda s: None)
    sl.load(load_sequence(CONFIG))                # a whole step table: many frames, many scans
    assert dev.n_steps == 6 and dev.applies == 1
    sl.start()
    assert dev.runs == 1


# ---------------------------------------------------------------------------
# XsdbScanPort's process handling (review 2026-10-26), with a fake xsdb
# ---------------------------------------------------------------------------
def test_xsdb_port_survives_a_chatty_server():
    import sys
    from pathlib import Path
    fake = Path(__file__).with_name("_fake_xsdb_server.py")
    port = jtag.XsdbScanPort(server_cmd=[sys.executable, str(fake)], start_timeout=20)
    try:
        dr = bytes(range(DR_BYTES))
        assert port.scan(dr) == bytes(b ^ 0xFF for b in dr)   # answered: the flood didn't block it
        assert any("noise line" in ln for ln in port.output)   # and its output was kept, bounded
        assert len(port.output) <= 50
    finally:
        port.close()
