"""Phase 5 runtime link: the framed PC<->FPGA protocol from docs/link_register_map.md,
plus a thin Python client (`Link`) on top of it.

**Scope note** (do not overclaim): `phase5_link_top.sv` wires this protocol to exactly
5 fixed debug cells -- the same test_clock/test_pulse/test_serial/test_low/test_high
pairs Phase 4 used (see DEBUG_CELL_NAMES below) -- not the full generic per-pin config
from config.py/nemo_config.yaml. That generic RTL (one sig_cell/cap_cell per real pin,
driven from an arbitrary `mode`) has not been built or wired to the link yet. So
`Link.send_config()` here takes a `{cell_name: SigCellConfig}` mapping keyed by
DEBUG_CELL_NAMES, not a `Config`/mode object from config.py.

Transport: anything with `write(bytes) -> None` and `read(size, timeout=None) -> bytes`
(duck-typed, see the `Transport` Protocol below) works -- `open_serial()` returns one
backed by a real serial port (pyserial, imported lazily so the rest of this module, and
every test, works without it installed). Tests use an in-memory fake instead; see
tools/nemo_ctl/tests/test_link.py.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

# ---- frame format: SOF(0xAA) CMD ADDR_LO ADDR_HI LEN DATA[LEN] CHECKSUM ----
# CHECKSUM is the XOR of CMD..DATA (not SOF). See docs/link_register_map.md.
SOF = 0xAA

CMD_WRITE_REG = 0x01
CMD_READ_REG = 0x02
CMD_LOAD_MODE = 0x03  # unimplemented on hardware -- always NACKed
CMD_APPLY = 0x04
CMD_RUN = 0x05
CMD_STOP = 0x06
CMD_STATUS = 0x07
CMD_READ_CAPTURE = 0x08
CMD_NACK = 0xFF

# ---- register map (docs/link_register_map.md) ----
RUN_CTRL_ADDR = 0x0001
APPLY_CTRL_ADDR = 0x0002
STATUS_ADDR = 0x0003

SIG_BASE = 0x0010
SIG_STRIDE = 24
CAP_BASE = 0x0100
CAP_STRIDE = 24

# phase5_link_top.sv's generate-loop order (gi = 0..4): the 5 debug cells this
# phase's hardware actually implements, in register-map order.
DEBUG_CELL_NAMES = ("test_clock", "test_pulse", "test_serial", "test_low", "test_high")

SIG_TYPES = {"LOW": 0, "HIGH": 1, "PULSE": 2, "CLOCK": 3, "SERIAL": 4}
CAP_MODES = {"LEVEL": 0, "EDGE_COUNT": 1, "PERIOD": 2, "SERIAL": 3}


class LinkError(Exception):
    """Base class for every link-level failure (bad frame, NACK, or timeout)."""


class FrameError(LinkError):
    """A byte sequence isn't a well-formed frame (bad SOF, short, or bad checksum)."""


class NackError(LinkError):
    """The device explicitly NACKed the last command (bad checksum or unimplemented CMD)."""


class LinkTimeoutError(LinkError):
    """The transport didn't deliver the expected bytes within its timeout."""


def _u16(value: int) -> bytes:
    return int(value).to_bytes(2, "little")


def _u32(value: int) -> bytes:
    return int(value).to_bytes(4, "little")


def checksum(cmd: int, addr: int, data: bytes) -> int:
    cksum = cmd ^ (addr & 0xFF) ^ ((addr >> 8) & 0xFF) ^ (len(data) & 0xFF)
    for b in data:
        cksum ^= b
    return cksum


def build_frame(cmd: int, addr: int, data: bytes = b"") -> bytes:
    if len(data) > 255:
        raise ValueError(f"frame payload too long: {len(data)} bytes (max 255)")
    return (
        bytes([SOF, cmd & 0xFF, addr & 0xFF, (addr >> 8) & 0xFF, len(data)])
        + bytes(data)
        + bytes([checksum(cmd, addr, data)])
    )


def parse_frame(buf: bytes) -> tuple[int, int, bytes]:
    """Parse one complete frame. Returns (cmd, addr, data); raises FrameError if
    `buf` isn't exactly one well-formed frame (wrong SOF, wrong length, or bad
    checksum)."""
    if len(buf) < 6:
        raise FrameError(f"frame too short: {len(buf)} bytes (need at least 6)")
    if buf[0] != SOF:
        raise FrameError(f"bad SOF: got 0x{buf[0]:02X}, expected 0x{SOF:02X}")
    cmd = buf[1]
    addr = buf[2] | (buf[3] << 8)
    length = buf[4]
    if len(buf) != 5 + length + 1:
        raise FrameError(f"frame length mismatch: LEN={length} but got {len(buf)} total bytes")
    data = bytes(buf[5 : 5 + length])
    recv_cksum = buf[5 + length]
    expect_cksum = checksum(cmd, addr, data)
    if recv_cksum != expect_cksum:
        raise FrameError(f"bad checksum: got 0x{recv_cksum:02X}, expected 0x{expect_cksum:02X}")
    return cmd, addr, data


class Transport(Protocol):
    def write(self, data: bytes) -> None: ...
    def read(self, size: int, timeout: float | None = None) -> bytes: ...


class SerialTransport:
    """Real hardware transport over a USB-UART adapter, via pyserial.

    pyserial is only imported here (lazily), so nothing else in this module or
    its tests needs it installed -- it's only required when actually talking
    to a board. Install with `pip install pyserial` first.
    """

    def __init__(self, port: str, baud: int = 115_200, timeout: float = 1.0):
        import serial  # noqa: PLC0415 -- intentionally lazy, see class docstring

        self._ser = serial.Serial(port, baudrate=baud, timeout=timeout)

    def write(self, data: bytes) -> None:
        self._ser.write(data)

    def read(self, size: int, timeout: float | None = None) -> bytes:
        if timeout is not None:
            self._ser.timeout = timeout
        return self._ser.read(size)

    def close(self) -> None:
        self._ser.close()


def open_serial(port: str, baud: int = 115_200, timeout: float = 1.0) -> "Link":
    """Convenience: open a real serial port and wrap it in a Link. Baud must match
    uart_tx.sv/uart_rx.sv's BAUD parameter on the bitstream currently loaded (115200
    by default); the adapter's own pin/voltage are still TBD, see link.py's module
    docstring and docs/USER_MANUAL.md's Phase 5 section."""
    return Link(SerialTransport(port, baud=baud, timeout=timeout))


@dataclass(frozen=True)
class SigCellConfig:
    """A sig_cell's writable config (docs/link_register_map.md's sig_cell CTRL/DELAY/
    PARAM_A/PARAM_B/CYCLES/DATA/BITS fields). `type` is one of SIG_TYPES's keys.
    `data`/`bits` are only meaningful for type="SERIAL"; the hardware's test_serial
    cell is SERIAL_W=16 bits wide, every other debug cell is SERIAL_W=1 (data/bits
    are ignored there)."""

    type: str
    idle_level: bool = False
    msb_first: bool = False
    delay: int = 0
    param_a: int = 0
    param_b: int = 0
    cycles: int = 0
    data: int = 0
    bits: int = 0

    def __post_init__(self):
        if self.type not in SIG_TYPES:
            raise ValueError(f"unknown sig_cell type {self.type!r}; expected one of {sorted(SIG_TYPES)}")

    def encode(self) -> bytes:
        ctrl = (SIG_TYPES[self.type] & 0x7) | (0x08 if self.idle_level else 0) | (0x10 if self.msb_first else 0)
        return (
            bytes([ctrl])
            + _u32(self.delay)
            + _u32(self.param_a)
            + _u32(self.param_b)
            + _u32(self.cycles)
            + _u16(self.data)
            + _u32(self.bits)
        )


@dataclass(frozen=True)
class CapCellConfig:
    """A cap_cell's writable config (CTRL + BITS). `mode` is one of CAP_MODES's keys."""

    mode: str
    msb_first: bool = False
    bits: int = 0

    def __post_init__(self):
        if self.mode not in CAP_MODES:
            raise ValueError(f"unknown cap_cell mode {self.mode!r}; expected one of {sorted(CAP_MODES)}")

    def encode(self) -> bytes:
        ctrl = (CAP_MODES[self.mode] & 0x3) | (0x04 if self.msb_first else 0)
        return bytes([ctrl]) + _u32(self.bits)


@dataclass(frozen=True)
class CapCellStatus:
    """A cap_cell's live, read-only status/results (docs/link_register_map.md's
    STATUS_FLAGS/EDGE_COUNT/PERIOD_TICKS/HIGH_TICKS/CAPTURE_REG fields)."""

    level_out: bool
    period_valid: bool
    done: bool
    edge_count: int
    period_ticks: int
    high_ticks: int
    capture_reg: int

    @classmethod
    def decode(cls, data: bytes) -> "CapCellStatus":
        if len(data) != 15:
            raise ValueError(f"expected 15 bytes of cap_cell status, got {len(data)}")
        flags = data[0]
        return cls(
            level_out=bool(flags & 0x1),
            period_valid=bool(flags & 0x2),
            done=bool(flags & 0x4),
            edge_count=int.from_bytes(data[1:5], "little"),
            period_ticks=int.from_bytes(data[5:9], "little"),
            high_ticks=int.from_bytes(data[9:13], "little"),
            capture_reg=int.from_bytes(data[13:15], "little"),
        )


# offset (within one cap_cell's 24-byte block) where the read-only status run starts,
# and how many bytes it spans -- STATUS_FLAGS(1) + EDGE_COUNT(4) + PERIOD_TICKS(4) +
# HIGH_TICKS(4) + CAPTURE_REG(2) = 15 bytes, at +0x05..+0x13.
_CAP_STATUS_OFFSET = 5
_CAP_STATUS_LEN = 15


class Link:
    """Client for the Phase 5 framed protocol. See docs/link_register_map.md for the
    byte-level register map this talks to, and link_ctrl.sv for the hardware side."""

    def __init__(self, transport: Transport):
        self._t = transport

    def close(self) -> None:
        close = getattr(self._t, "close", None)
        if close is not None:
            close()

    # ---- raw frame I/O ----
    def _send(self, cmd: int, addr: int, data: bytes = b"") -> None:
        self._t.write(build_frame(cmd, addr, data))

    def _recv(self) -> tuple[int, int, bytes]:
        header = self._t.read(5)
        if len(header) < 5:
            raise LinkTimeoutError(f"timed out waiting for a response header (got {len(header)}/5 bytes)")
        if header[0] != SOF:
            raise FrameError(f"bad SOF: got 0x{header[0]:02X}, expected 0x{SOF:02X}")
        length = header[4]
        rest = self._t.read(length + 1)
        if len(rest) < length + 1:
            raise LinkTimeoutError(
                f"timed out waiting for response data+checksum (got {len(rest)}/{length + 1} bytes)"
            )
        cmd, addr, data = parse_frame(header + rest)
        if cmd == CMD_NACK:
            raise NackError(f"device NACKed (addr=0x{addr:04X})")
        return cmd, addr, data

    # ---- register-level commands ----
    def write_reg(self, addr: int, data: bytes) -> None:
        self._send(CMD_WRITE_REG, addr, data)

    def read_reg(self, addr: int, length: int) -> bytes:
        # the request frame's data bytes are ignored by the hardware for a read, but
        # link_ctrl.sv's parser still expects LEN of them (and includes them in the
        # checksum) regardless of CMD -- see docs/link_register_map.md's frame format.
        self._send(CMD_READ_REG, addr, bytes(length))
        cmd, _addr, data = self._recv()
        if cmd != CMD_READ_REG:
            raise LinkError(f"expected a READ_REG response, got CMD 0x{cmd:02X}")
        return data

    def apply(self) -> None:
        self._send(CMD_APPLY, 0x0000)

    def run(self) -> None:
        self._send(CMD_RUN, 0x0000)

    def stop(self) -> None:
        self._send(CMD_STOP, 0x0000)

    def status(self) -> bool:
        """True if currently RUNning."""
        self._send(CMD_STATUS, 0x0000)
        cmd, _addr, data = self._recv()
        if cmd != CMD_STATUS or not data:
            raise LinkError(f"expected a 1-byte STATUS response, got CMD 0x{cmd:02X} / {len(data)} bytes")
        return bool(data[0] & 0x1)

    def read_capture_raw(self, cap_region_offset: int, length: int) -> bytes:
        self._send(CMD_READ_CAPTURE, cap_region_offset, bytes(length))
        cmd, _addr, data = self._recv()
        if cmd != CMD_READ_CAPTURE:
            raise LinkError(f"expected a READ_CAPTURE response, got CMD 0x{cmd:02X}")
        return data

    # ---- Phase 5 debug-harness helpers (DEBUG_CELL_NAMES only -- see module
    #      docstring for why this isn't the full generic per-pin config) ----
    def send_cell_config(self, cell: str, config: SigCellConfig) -> None:
        idx = DEBUG_CELL_NAMES.index(cell)
        self.write_reg(SIG_BASE + idx * SIG_STRIDE, config.encode())

    def send_cap_config(self, cell: str, config: CapCellConfig) -> None:
        idx = DEBUG_CELL_NAMES.index(cell)
        self.write_reg(CAP_BASE + idx * CAP_STRIDE, config.encode())

    def send_config(self, config: dict[str, SigCellConfig]) -> None:
        """Write every {cell_name: SigCellConfig} pair in `config` (keys must be in
        DEBUG_CELL_NAMES). Does NOT call apply() -- the new values only take effect
        on the next apply() (optionally while still run()ning), matching Phase 5's
        exit criterion ("change a clock frequency from the PC without re-synthesis
        and see it ... ")."""
        for cell, cfg in config.items():
            self.send_cell_config(cell, cfg)

    def read_captures(self) -> dict[str, CapCellStatus]:
        """Read every debug cell's live cap_cell status in one call."""
        out: dict[str, CapCellStatus] = {}
        for idx, cell in enumerate(DEBUG_CELL_NAMES):
            offset = idx * CAP_STRIDE + _CAP_STATUS_OFFSET
            out[cell] = CapCellStatus.decode(self.read_capture_raw(offset, _CAP_STATUS_LEN))
        return out


# ======================================================================================
# Link v2 (Phase 7 round 2): phase7_link_top.sv. See docs/link_register_map.md, "v2".
# Same frame format and commands as Phase 5, a different register map behind them:
#   RUN = START the loaded sequence, STOP = ABORT it, APPLY = re-apply step 0 (idle state)
# ======================================================================================

V2_SCRATCH = 0x0000
V2_STATUS = 0x0003      # R: see V2Status; a write of any value clears TABLE_REJECTED
V2_STEP = 0x0004        # R: current step
V2_LAST_STEP = 0x0005   # R: step the last run ended on
V2_N_STEPS = 0x0006     # R/W: number of steps in the table (1..16); write ignored while busy
V2_CAP_BASE = 0x0100    # cap cell k's results at V2_CAP_BASE + k * stride (READ_CAPTURE offset)
V2_TABLE_BASE = 0x1000  # step k's entry at V2_TABLE_BASE + k * ENTRY_BYTES (write-only)
# byte offsets inside one cap cell's result block
V2_CAP_FLAGS, V2_CAP_EDGES, V2_CAP_PERIOD, V2_CAP_HIGH, V2_CAP_DATA = 0, 1, 5, 9, 13


def v2_cap_bytes(target) -> int:
    """Bytes of the widest capture register in the target."""
    return max((c.cap_w + 7) // 8 for c in target.cap_cells)


def v2_cap_stride(target) -> int:
    """Bytes per cap cell in the v2 capture region: flags + 3 counters + the widest
    capture register, rounded up to 8."""
    return -(-(V2_CAP_DATA + v2_cap_bytes(target)) // 8) * 8


@dataclass(frozen=True)
class V2Status:
    """The v2 STATUS byte, bit 0 first."""
    run: bool
    busy: bool
    done: bool
    fault: bool
    aborted: bool
    late: bool            # a step boundary had to wait for the bank (not tick-exact)
    table_rejected: bool  # a table / N_STEPS write arrived while busy and was ignored
    rx_overflow: bool     # the link's input FIFO dropped a byte (sticky until reset)

    @classmethod
    def decode(cls, b: int) -> "V2Status":
        return cls(*(bool(b >> i & 1) for i in range(8)))


class SeqLink(Link):
    """Client for link v2 (phase7_link_top.sv): load a compiled step table, run it, read
    the results. Implements sequence.Sequencer, so sequence.program_verify() runs over the
    real link with it. Frames, commands and errors are Phase 5's (Link)."""

    def __init__(self, transport: Transport, target=None, poll_s: float = 0.01,
                 clock=None, sleep=None):
        import time as _time
        from .sequence import PHASE7_LOOPBACK
        super().__init__(transport)
        self.target = target or PHASE7_LOOPBACK
        self.poll_s = poll_s
        self._clock = clock or _time.monotonic
        self._sleep = sleep or _time.sleep

    # ---- Sequencer protocol ----
    def load(self, table) -> None:
        """Write every step's entry and N_STEPS, then APPLY (pins go to the new step 0's
        idle state). Refuses a table for another target. Raises LinkError if the device
        reports the writes were refused (a sequence was still running)."""
        from .sequence import ENTRY_BYTES, MAX_STEPS, encode_step, entry_layout
        if table.target != self.target:
            raise LinkError(f"table is for {table.target.name}, this link drives {self.target.name}")
        if not 1 <= len(table.steps) <= MAX_STEPS:
            raise LinkError(f"{len(table.steps)} steps; the device holds 1..{MAX_STEPS}")
        lay = entry_layout(self.target)
        for k, st in enumerate(table.steps):
            self.write_reg(V2_TABLE_BASE + k * ENTRY_BYTES, encode_step(st, lay))
        self.write_reg(V2_N_STEPS, bytes([len(table.steps)]))
        st = self.seq_status()
        if st.table_rejected:
            self.write_reg(V2_STATUS, b"\x00")   # clear it for next time
            raise LinkError("device refused the table: a sequence was running (STOP it first)")
        self.apply()

    def start(self) -> None:
        self.run()

    def wait(self, timeout_s: float):
        """Poll STATUS until the sequence is no longer busy (or timeout_s passes)."""
        from .sequence import SeqResult
        t_end = self._clock() + timeout_s
        st = self.seq_status()
        while st.busy and self._clock() < t_end:
            self._sleep(self.poll_s)
            st = self.seq_status()
        last = self.read_reg(V2_LAST_STEP, 1)[0]
        return SeqResult(done=st.done and not st.busy, fault=st.fault, step=last)

    def read_capture(self, cap_cell: str) -> int:
        """The cap cell's capture register (SERIAL result), as an int."""
        k = self.target.cap_index(cap_cell)
        n = (self.target.cap_cells[k].cap_w + 7) // 8
        data = self.read_capture_raw(k * v2_cap_stride(self.target) + V2_CAP_DATA, n)
        return int.from_bytes(data, "little")

    # ---- extras ----
    def abort(self) -> None:
        self.stop()

    def preload(self) -> None:
        """Re-apply step 0 with RUN low (the idle state)."""
        self.apply()

    def seq_status(self) -> V2Status:
        self._send(CMD_STATUS, 0x0000)
        cmd, _addr, data = self._recv()
        if cmd != CMD_STATUS or len(data) != 1:
            raise LinkError(f"expected a 1-byte STATUS response, got CMD 0x{cmd:02X} / {len(data)} bytes")
        return V2Status.decode(data[0])

    def read_cap_counts(self, cap_cell: str) -> dict:
        """flags + edge count of a cap cell: {'level', 'done', 'edges'}."""
        k = self.target.cap_index(cap_cell)
        b = self.read_capture_raw(k * v2_cap_stride(self.target), V2_CAP_PERIOD)
        return {"level": bool(b[0] & 1), "done": bool(b[0] & 4),
                "edges": int.from_bytes(b[V2_CAP_EDGES:V2_CAP_EDGES + 4], "little")}
