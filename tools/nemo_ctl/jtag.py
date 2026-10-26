"""JTAG transport for the PC link (JTAG link step J4).

The link's byte stream (frames, `link.py`) normally rides a UART. With the JTAG
transport (docs/decisions.md, 2026-10-22) it rides BSCANE2 USER4 scans over the
ZedBoard's J17 PROG cable instead: `fpga/src/jtag_link_bridge.sv` on the FPGA side,
this module on the PC side. `Link` / `SeqLink` don't change: `JtagTransport` has the
same `write()` / `read()` as `SerialTransport`.

Layers:
  ScanPort      one full 128-byte scan in, one 128-byte reply out
                (`XsdbScanPort`: via Vivado's xsdb running scripts/jtag_server.tcl)
  JtagTransport the transport rules (docs/link_register_map.md, "Transport: JTAG
                over J17"): a scan counts only if its own reply says ready; then
                its down bytes were taken and the offered up bytes are ours; never
                send more than the FPGA's last reported free space.

Byte i of a scan = bits [8i+7:8i]; xsdb's -hex strings are byte-little-endian with
each byte as a normal 2-digit pair (EXP-05), which is exactly `bytes.hex()`.

No hardware is needed to import or test this module (tests use a model of the
bridge); `XsdbScanPort` needs Vivado's xsdb and a board with a JTAG link top.
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

from .link import LinkError, LinkTimeoutError

DR_BYTES = 128                 # jtag_link_bridge DR_BITS = 1024
MAXD = DR_BYTES - 4            # down data bytes per scan
MAXU = DR_BYTES - 8            # up data bytes per scan
MAGIC_DN = b"JL"
MAGIC_UP = b"jl"
USER4_IR = 0x23                # 7-series USER4; USER1 is disturbed by hw_server (EXP-05)

REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_TCL = REPO_ROOT / "scripts" / "jtag_server.tcl"
DEFAULT_XSDB_WINDOWS = Path(r"C:\Xilinx\Vivado\2022.1\bin\xsdb.bat")


class JtagLinkError(LinkError):
    """The JTAG transport itself failed (no bridge reply, overflow, xsdb problem)."""


# ---------------------------------------------------------------------------
# scan format
# ---------------------------------------------------------------------------
def pack_down(data: bytes) -> bytes:
    """One PC -> FPGA scan carrying `data` (at most MAXD bytes)."""
    if len(data) > MAXD:
        raise ValueError(f"at most {MAXD} bytes per scan, got {len(data)}")
    dr = bytearray(DR_BYTES)
    dr[0:2] = MAGIC_DN
    dr[2] = len(data)
    dr[4:4 + len(data)] = data
    return bytes(dr)


@dataclass(frozen=True)
class UpReply:
    ready: bool          # this scan was accepted
    overflow: bool       # sticky: the PC once sent more than `free`
    free: int            # down FIFO space when this reply was built
    n_accepted: int      # accepted-scan counter (wraps at 256)
    data: bytes          # the offered up bytes (meaningful only if ready)


def parse_up(reply: bytes) -> UpReply:
    """Decode one FPGA -> PC scan. Raises JtagLinkError if it isn't a bridge reply."""
    if len(reply) != DR_BYTES:
        raise JtagLinkError(f"scan reply is {len(reply)} bytes, expected {DR_BYTES}")
    if reply[0:2] != MAGIC_UP:
        raise JtagLinkError(
            f"no bridge reply (magic {reply[0:2].hex()}, expected {MAGIC_UP.hex()}): is a JTAG "
            "link top (phase5_link_jtag_top / phase7_link_jtag_top) loaded on the board?")
    flags, n_up = reply[2], reply[3]
    if n_up > MAXU:
        raise JtagLinkError(f"bridge offered {n_up} up bytes, more than {MAXU}")
    return UpReply(ready=bool(flags & 1), overflow=bool(flags & 2), free=reply[4],
                   n_accepted=reply[5], data=bytes(reply[8:8 + n_up]))


def to_hex(dr: bytes) -> str:
    """Scan bytes -> xsdb -hex string (byte 0 first, EXP-05)."""
    return dr.hex().upper()


def from_hex(h: str) -> bytes:
    return bytes.fromhex(h.strip())


# ---------------------------------------------------------------------------
# scan ports
# ---------------------------------------------------------------------------
class ScanPort(Protocol):
    def scan(self, dr: bytes) -> bytes: ...


def find_xsdb() -> str:
    """xsdb from $XSDB, else PATH, else the lab PC's Vivado 2022.1 install."""
    env = os.environ.get("XSDB")
    if env:
        return env
    for name in ("xsdb", "xsdb.bat"):
        hit = shutil.which(name)
        if hit:
            return hit
    if DEFAULT_XSDB_WINDOWS.exists():
        return str(DEFAULT_XSDB_WINDOWS)
    raise JtagLinkError("xsdb not found: set XSDB=... or put Vivado 2022.1's bin folder on PATH")


class XsdbScanPort:
    """Full-length USER scans through a running xsdb (scripts/jtag_server.tcl).

    Starts xsdb as a subprocess, waits for its `READY <port>` line, then sends one
    `S <hex>` line per scan over 127.0.0.1. The server holds `jtag lock` for its whole
    life, so nothing else can scan the board while it runs (EXP-05). close() stops it.

    After READY a daemon thread keeps reading xsdb's output (the last lines are kept for
    error messages). Left unread, the pipe fills and xsdb freezes in its next print, so
    the link hangs (review 2026-10-26, reproduced by test_jtag.py's fake server).
    `server_cmd` replaces the xsdb command line (tests only).
    """

    def __init__(self, xsdb: str | None = None, ir: int = USER4_IR, start_timeout: float = 60.0,
                 server_cmd: list[str] | None = None):
        self.output: deque[str] = deque(maxlen=50)   # xsdb's latest output lines
        self._proc = subprocess.Popen(
            server_cmd or [xsdb or find_xsdb(), str(SERVER_TCL), f"{ir:02X}"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1)
        port = None
        lines: list[str] = []
        t_end = time.monotonic() + start_timeout
        while time.monotonic() < t_end:
            line = self._proc.stdout.readline()
            if not line:
                break                                   # xsdb exited
            lines.append(line.rstrip())
            if line.startswith("READY "):
                port = int(line.split()[1])
                break
            if line.startswith("ERROR"):
                break
        if port is None:
            self._proc.kill()
            raise JtagLinkError("jtag_server.tcl didn't start:\n  " + "\n  ".join(lines[-15:]))
        self.output.extend(lines)
        threading.Thread(target=self._drain, daemon=True).start()
        self._sock = socket.create_connection(("127.0.0.1", port), timeout=10.0)
        self._rfile = self._sock.makefile("r", encoding="ascii", newline="\n")

    def _drain(self) -> None:
        for line in self._proc.stdout:
            self.output.append(line.rstrip())

    def scan(self, dr: bytes) -> bytes:
        self._sock.sendall(f"S {to_hex(dr)}\n".encode("ascii"))
        line = self._rfile.readline()
        if not line:
            raise JtagLinkError("jtag_server.tcl closed the connection; its last output:\n  "
                                + "\n  ".join(list(self.output)[-10:]))
        if line.startswith("E "):
            raise JtagLinkError(f"xsdb: {line[2:].strip()}")
        return from_hex(line)

    def close(self) -> None:
        try:
            self._sock.sendall(b"Q\n")
            self._rfile.readline()
        except OSError:
            pass
        try:
            self._sock.close()
        finally:
            try:
                self._proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self._proc.kill()


# ---------------------------------------------------------------------------
# transport
# ---------------------------------------------------------------------------
class JtagTransport:
    """`write()` / `read()` over a ScanPort, by the bridge's rules.

    write() queues bytes and scans until the FPGA has accepted all of them; read()
    scans (down bytes first, if any) until `size` up bytes have arrived or `timeout`
    passes. Every scan is one round trip, ~1.3 ms with xsdb (EXP-05).
    """

    def __init__(self, port: ScanPort, timeout: float = 1.0, poll_s: float = 0.0,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep):
        self._port = port
        self._timeout = timeout
        self._poll_s = poll_s
        self._clock = clock
        self._sleep = sleep
        self._down = bytearray()
        self._up = bytearray()
        self._credit = 0                     # learnt from the first ready reply
        self.n_scans = 0
        self.n_rejected = 0

    def _scan_once(self) -> bool:
        n = min(len(self._down), MAXD, self._credit)
        rep = parse_up(self._port.scan(pack_down(bytes(self._down[:n]))))
        self.n_scans += 1
        if rep.overflow:
            raise JtagLinkError("bridge reports a down-FIFO overflow (sticky until the FPGA is "
                                "reprogrammed): bytes were lost")
        if not rep.ready:
            self.n_rejected += 1             # nothing happened: same bytes again next scan
            return False
        del self._down[:n]
        self._up += rep.data
        self._credit = rep.free - n
        return True

    def write(self, data: bytes) -> None:
        self._down += data
        t_end = self._clock() + self._timeout
        while self._down:
            if self._clock() > t_end:
                raise LinkTimeoutError(f"JTAG: {len(self._down)} bytes not accepted within {self._timeout} s")
            if not self._scan_once() and self._poll_s:
                self._sleep(self._poll_s)

    def read(self, size: int, timeout: float | None = None) -> bytes:
        t_end = self._clock() + (self._timeout if timeout is None else timeout)
        while len(self._up) < size and self._clock() <= t_end:
            self._scan_once()
            if len(self._up) < size and self._poll_s:
                self._sleep(self._poll_s)
        got = bytes(self._up[:size])
        del self._up[:size]
        return got                           # short = timed out; Link raises LinkTimeoutError

    def close(self) -> None:
        close = getattr(self._port, "close", None)
        if close is not None:
            close()


def open_jtag(timeout: float = 1.0, xsdb: str | None = None, link_cls=None, **link_kwargs):
    """A Link (or `link_cls`, e.g. SeqLink) over the JTAG transport. Needs a JTAG link
    top on the board (phase5_link_jtag_top -> Link, phase7_link_jtag_top -> SeqLink)."""
    from .link import Link
    cls = link_cls or Link
    return cls(JtagTransport(XsdbScanPort(xsdb=xsdb), timeout=timeout), **link_kwargs)
