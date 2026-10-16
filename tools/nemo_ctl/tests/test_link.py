"""Tests for nemo_ctl.link (Phase 5 runtime link).

No real serial port or hardware involved. `_FakeDevice`/`_FakeTransport` below are an
in-memory model of link_ctrl.sv's own parsing/register-file/dispatch rules (mirrored
from docs/link_register_map.md and link_ctrl.sv, the same rules fpga/tb/link_ctrl_tb.sv
and fpga/tb/phase5_link_top_tb.sv already verify in simulation) -- they exist purely so
Link's framing/encoding logic gets exercised against a protocol-accurate stand-in
without needing iverilog or a board. They are not a claim that this *is* the hardware;
see docs/experiments/EXP-02 (pending) for the actual [measured on board] result.
"""
from __future__ import annotations

import pytest

from nemo_ctl import link


# ---------------------------------------------------------------------------
# in-memory stand-in for the hardware link_ctrl.sv, for protocol-level testing
# ---------------------------------------------------------------------------
_REG_BYTES = link.CAP_BASE + len(link.DEBUG_CELL_NAMES) * link.CAP_STRIDE


class _FakeDevice:
    def __init__(self):
        self.regs = bytearray(_REG_BYTES)
        self.run = False
        self.apply_count = 0
        self.write_log: list[tuple[int, bytes]] = []
        self.cap_status = {
            name: dict(
                level_out=False, period_valid=False, done=False,
                edge_count=0, period_ticks=0, high_ticks=0, capture_reg=0,
            )
            for name in link.DEBUG_CELL_NAMES
        }

    def _read_byte(self, addr: int) -> int:
        if addr in (link.RUN_CTRL_ADDR, link.STATUS_ADDR):
            return 1 if self.run else 0
        if addr == link.APPLY_CTRL_ADDR:
            return 0
        if link.CAP_BASE <= addr < link.CAP_BASE + len(link.DEBUG_CELL_NAMES) * link.CAP_STRIDE:
            idx = (addr - link.CAP_BASE) // link.CAP_STRIDE
            off = (addr - link.CAP_BASE) % link.CAP_STRIDE
            st = self.cap_status[link.DEBUG_CELL_NAMES[idx]]
            if off == 5:
                return (4 if st["done"] else 0) | (2 if st["period_valid"] else 0) | (1 if st["level_out"] else 0)
            if 6 <= off <= 9:
                return (st["edge_count"] >> (8 * (off - 6))) & 0xFF
            if 10 <= off <= 13:
                return (st["period_ticks"] >> (8 * (off - 10))) & 0xFF
            if 14 <= off <= 17:
                return (st["high_ticks"] >> (8 * (off - 14))) & 0xFF
            if 18 <= off <= 19:
                return (st["capture_reg"] >> (8 * (off - 18))) & 0xFF
        if addr < len(self.regs):
            return self.regs[addr]
        return 0

    def handle(self, frame_bytes: bytes) -> bytes:
        try:
            cmd, addr, data = link.parse_frame(frame_bytes)
        except link.FrameError:
            return link.build_frame(link.CMD_NACK, 0, b"")

        if cmd == link.CMD_WRITE_REG:
            for i, b in enumerate(data):
                a = addr + i
                if a < len(self.regs):
                    self.regs[a] = b
                if a == link.RUN_CTRL_ADDR:
                    self.run = bool(b & 1)
                if a == link.APPLY_CTRL_ADDR:
                    self.apply_count += 1
            self.write_log.append((addr, bytes(data)))
            return b""
        if cmd == link.CMD_READ_REG:
            resp = bytes(self._read_byte(addr + i) for i in range(len(data)))
            return link.build_frame(link.CMD_READ_REG, addr, resp)
        if cmd == link.CMD_APPLY:
            self.apply_count += 1
            return b""
        if cmd == link.CMD_RUN:
            self.run = True
            return b""
        if cmd == link.CMD_STOP:
            self.run = False
            return b""
        if cmd == link.CMD_STATUS:
            return link.build_frame(link.CMD_STATUS, link.STATUS_ADDR, bytes([1 if self.run else 0]))
        if cmd == link.CMD_READ_CAPTURE:
            resp = bytes(self._read_byte(link.CAP_BASE + addr + i) for i in range(len(data)))
            return link.build_frame(link.CMD_READ_CAPTURE, addr, resp)
        return link.build_frame(link.CMD_NACK, 0, b"")  # CMD_LOAD_MODE or unknown


class _FakeTransport:
    """write() feeds a whole frame to the fake device and buffers its response (if
    any); read() drains that buffer. starve_response, if set, truncates the next
    read() short (simulating a timeout)."""

    def __init__(self, device: _FakeDevice):
        self.device = device
        self._buf = bytearray()
        self.starve_response = False

    def write(self, data: bytes) -> None:
        self._buf += self.device.handle(bytes(data))

    def read(self, size: int, timeout: float | None = None) -> bytes:
        if self.starve_response:
            return b""
        got = bytes(self._buf[:size])
        del self._buf[:size]
        return got

    def close(self) -> None:
        pass


@pytest.fixture
def fake():
    device = _FakeDevice()
    transport = _FakeTransport(device)
    return link.Link(transport), device


# ---------------------------------------------------------------------------
# frame encode/decode
# ---------------------------------------------------------------------------

def test_build_and_parse_frame_roundtrip():
    frame = link.build_frame(link.CMD_WRITE_REG, 0x0010, bytes([1, 2, 3, 4]))
    cmd, addr, data = link.parse_frame(frame)
    assert (cmd, addr, data) == (link.CMD_WRITE_REG, 0x0010, bytes([1, 2, 3, 4]))


def test_build_frame_matches_sof_and_checksum_by_hand():
    frame = link.build_frame(0x02, 0x0015, bytes([4]))
    assert frame[0] == 0xAA
    assert frame[1] == 0x02
    assert frame[2:4] == bytes([0x15, 0x00])
    assert frame[4] == 1
    expect_cksum = 0x02 ^ 0x15 ^ 0x00 ^ 1 ^ 4
    assert frame[-1] == expect_cksum


def test_parse_frame_rejects_bad_sof():
    frame = bytearray(link.build_frame(link.CMD_STATUS, 0, b""))
    frame[0] = 0x00
    with pytest.raises(link.FrameError):
        link.parse_frame(bytes(frame))


def test_parse_frame_rejects_bad_checksum():
    frame = bytearray(link.build_frame(link.CMD_STATUS, 0, b""))
    frame[-1] ^= 0xFF
    with pytest.raises(link.FrameError):
        link.parse_frame(bytes(frame))


def test_parse_frame_rejects_truncated_frame():
    frame = link.build_frame(link.CMD_WRITE_REG, 0x10, bytes([1, 2, 3]))
    with pytest.raises(link.FrameError):
        link.parse_frame(frame[:-2])


def test_checksum_excludes_sof():
    # changing the hypothetical SOF byte alone must not change the checksum
    assert link.checksum(link.CMD_STATUS, 0, b"") == link.checksum(link.CMD_STATUS, 0, b"")


# ---------------------------------------------------------------------------
# SigCellConfig / CapCellConfig / CapCellStatus encode/decode
# ---------------------------------------------------------------------------

def test_sig_cell_config_encode_clock():
    cfg = link.SigCellConfig(type="CLOCK", idle_level=False, msb_first=True, param_a=20, param_b=10)
    encoded = cfg.encode()
    assert len(encoded) == 23  # CTRL(1)+DELAY(4)+PARAM_A(4)+PARAM_B(4)+CYCLES(4)+DATA(2)+BITS(4)
    assert encoded[0] == 0b0001_0011  # msb_first=1, idle=0, type=CLOCK(3)=011
    assert encoded[1:5] == bytes(4)  # delay=0
    assert encoded[5:9] == (20).to_bytes(4, "little")  # param_a
    assert encoded[9:13] == (10).to_bytes(4, "little")  # param_b


def test_sig_cell_config_rejects_unknown_type():
    with pytest.raises(ValueError):
        link.SigCellConfig(type="BOGUS")


def test_cap_cell_config_encode_period():
    cfg = link.CapCellConfig(mode="PERIOD", msb_first=True, bits=16)
    encoded = cfg.encode()
    assert encoded[0] == 0b0000_0110  # msb_first=1, mode=PERIOD(2)=10
    assert encoded[1:5] == (16).to_bytes(4, "little")


def test_cap_cell_config_rejects_unknown_mode():
    with pytest.raises(ValueError):
        link.CapCellConfig(mode="BOGUS")


def test_cap_cell_status_decode():
    flags = 0b101  # done=1, period_valid=0, level_out=1
    raw = (
        bytes([flags])
        + (0x11111111).to_bytes(4, "little")
        + (20).to_bytes(4, "little")
        + (10).to_bytes(4, "little")
        + (0xBEEF).to_bytes(2, "little")
    )
    status = link.CapCellStatus.decode(raw)
    assert status.level_out is True
    assert status.period_valid is False
    assert status.done is True
    assert status.edge_count == 0x11111111
    assert status.period_ticks == 20
    assert status.high_ticks == 10
    assert status.capture_reg == 0xBEEF


def test_cap_cell_status_decode_rejects_wrong_length():
    with pytest.raises(ValueError):
        link.CapCellStatus.decode(bytes(14))


# ---------------------------------------------------------------------------
# Link, against the fake device
# ---------------------------------------------------------------------------

def test_link_write_reg_then_read_reg_roundtrip(fake):
    lnk, _device = fake
    lnk.write_reg(link.SIG_BASE + 5, (0x12345678).to_bytes(4, "little"))
    got = lnk.read_reg(link.SIG_BASE + 5, 4)
    assert int.from_bytes(got, "little") == 0x12345678


def test_link_run_stop_status(fake):
    lnk, _device = fake
    assert lnk.status() is False
    lnk.run()
    assert lnk.status() is True
    lnk.stop()
    assert lnk.status() is False


def test_link_apply_reaches_device(fake):
    lnk, device = fake
    lnk.apply()
    assert device.apply_count == 1


def test_link_send_cell_config_writes_the_right_address(fake):
    lnk, device = fake
    cfg = link.SigCellConfig(type="CLOCK", param_a=20, param_b=10)
    lnk.send_cell_config("test_clock", cfg)
    addr, data = device.write_log[-1]
    assert addr == link.SIG_BASE + 0 * link.SIG_STRIDE
    assert data == cfg.encode()

    lnk.send_cell_config("test_pulse", cfg)
    addr, _data = device.write_log[-1]
    assert addr == link.SIG_BASE + 1 * link.SIG_STRIDE


def test_link_send_config_multiple_cells(fake):
    lnk, device = fake
    cfg_clock = link.SigCellConfig(type="CLOCK", param_a=20, param_b=10)
    cfg_pulse = link.SigCellConfig(type="PULSE", param_a=5)
    lnk.send_config({"test_clock": cfg_clock, "test_pulse": cfg_pulse})
    written = dict(device.write_log)
    assert written[link.SIG_BASE + 0 * link.SIG_STRIDE] == cfg_clock.encode()
    assert written[link.SIG_BASE + 1 * link.SIG_STRIDE] == cfg_pulse.encode()


def test_link_send_config_rejects_unknown_cell_name(fake):
    lnk, _device = fake
    with pytest.raises(ValueError):
        lnk.send_cell_config("not_a_real_cell", link.SigCellConfig(type="LOW"))


def test_link_send_cap_config(fake):
    lnk, device = fake
    cfg = link.CapCellConfig(mode="PERIOD")
    lnk.send_cap_config("test_clock", cfg)
    addr, data = device.write_log[-1]
    assert addr == link.CAP_BASE + 0 * link.CAP_STRIDE
    assert data == cfg.encode()


def test_link_read_captures_all_cells(fake):
    lnk, device = fake
    device.cap_status["test_pulse"]["done"] = True
    device.cap_status["test_pulse"]["edge_count"] = 7
    statuses = lnk.read_captures()
    assert set(statuses) == set(link.DEBUG_CELL_NAMES)
    assert statuses["test_pulse"].done is True
    assert statuses["test_pulse"].edge_count == 7
    assert statuses["test_clock"].done is False


def test_link_nack_raises(fake):
    lnk, _device = fake
    lnk._send(link.CMD_LOAD_MODE, 0x0000, b"")  # unimplemented -> NACK
    with pytest.raises(link.NackError):
        lnk._recv()


def test_link_read_reg_times_out_cleanly(fake):
    lnk, _device = fake
    lnk._t.starve_response = True
    with pytest.raises(link.LinkTimeoutError):
        lnk.read_reg(link.SIG_BASE, 4)


def test_link_close_calls_transport_close():
    closed = []

    class _T:
        def write(self, data):
            pass

        def read(self, size, timeout=None):
            return b""

        def close(self):
            closed.append(True)

    link.Link(_T()).close()
    assert closed == [True]


def test_link_close_tolerates_transport_without_close():
    class _T:
        def write(self, data):
            pass

        def read(self, size, timeout=None):
            return b""

    link.Link(_T()).close()  # must not raise


def test_phase5_exit_criterion_change_frequency_without_reapply_of_other_state(fake):
    """Mirrors fpga/tb/phase5_link_top_tb.sv's centerpiece test at the protocol
    level: write a new PARAM_A/PARAM_B while RUNning, APPLY, and read it back --
    no STOP/re-RUN needed. (The actual on-pin frequency change is simulated/
    measured in the RTL testbench and EXP-02, not re-verified here.)"""
    lnk, device = fake
    lnk.send_cell_config("test_clock", link.SigCellConfig(type="CLOCK", param_a=20, param_b=10))
    lnk.apply()
    lnk.run()
    assert lnk.status() is True

    lnk.send_cell_config("test_clock", link.SigCellConfig(type="CLOCK", param_a=40, param_b=20))
    lnk.apply()
    assert lnk.status() is True  # never stopped

    readback = lnk.read_reg(link.SIG_BASE + 5, 4)
    assert int.from_bytes(readback, "little") == 40
    assert device.apply_count == 2


# ---------------------------------------------------------------------------
# SerialTransport / open_serial: lazy pyserial import
# ---------------------------------------------------------------------------

def test_module_imports_without_pyserial_installed():
    # importing nemo_ctl.link must not require pyserial -- only SerialTransport.__init__ does.
    assert hasattr(link, "SerialTransport")
    assert hasattr(link, "open_serial")


def test_open_serial_error_when_pyserial_missing_is_the_plain_import_error():
    try:
        import serial  # noqa: F401
    except ImportError:
        pass
    else:
        pytest.skip("pyserial is installed in this environment; nothing to assert here")
    with pytest.raises(ModuleNotFoundError):
        link.open_serial("/dev/ttyUSB0")
