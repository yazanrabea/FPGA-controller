"""Chip pipeline step C2 (2026-10-26): the real chip as a sequencer target (sequence.chip_target)."""
import pytest

from nemo_ctl import link
from nemo_ctl.pins import load_pin_db
from nemo_ctl.sequence import (SequenceError, chip_target, compile_steps, encode_step, entry_layout)
from nemo_ctl.sipo_piso import PISO_BITS, SIPO_BITS

CHIP = chip_target()
PIN_DB = load_pin_db()


def test_cells_are_the_chip_pins_by_direction():
    assert [c.name for c in CHIP.sig_cells] == [p.name for p in PIN_DB.values() if p.direction == "in"]
    assert [c.name for c in CHIP.cap_cells] == [p.name for p in PIN_DB.values() if p.direction == "out"]
    assert len(CHIP.sig_cells) == 22 and len(CHIP.cap_cells) == 4


def test_serial_cells_and_their_strobes():
    sipo = CHIP.sig_cells[CHIP.sig_index("sipo_in")]
    piso = CHIP.cap_cells[CHIP.cap_index("piso_out")]
    assert (sipo.serial_w, sipo.strobe) == (SIPO_BITS, ("clk_sipo", "falling")) == (136, ("clk_sipo", "falling"))
    assert (piso.cap_w, piso.strobe) == (PISO_BITS, ("clk_piso", "falling")) == (168, ("clk_piso", "falling"))
    others = [c for c in CHIP.sig_cells if c.name != "sipo_in"] + [c for c in CHIP.cap_cells if c.name != "piso_out"]
    assert all(getattr(c, "serial_w", getattr(c, "cap_w", 1)) == 1 and c.strobe is None for c in others)


def test_edges_are_parameters_until_dima_answers():
    t = chip_target(sipo_data_edge="rising", piso_sample_edge="rising")
    assert t.sig_cells[t.sig_index("sipo_in")].strobe == ("clk_sipo", "rising")
    assert t.cap_cells[t.cap_index("piso_out")].strobe == ("clk_piso", "rising")
    with pytest.raises(SequenceError):
        chip_target(sipo_data_edge="both")


def test_entry_layout_fits_1024_bytes():
    lay = entry_layout(CHIP)
    assert CHIP.entry_bytes == 1024
    assert lay.used_bytes == 534 > 256       # why the chip needs the larger stride
    assert link.v2_cap_stride(CHIP) == 40    # flags + counters + the 21-byte (168-bit) capture


FRAME = (1 << SIPO_BITS) - 1 - (0xF0F << 100)   # a 136-bit pattern with both 1s and 0s


def _sipo_load_steps():
    idle = {c.name: {"type": "LOW"} for c in CHIP.sig_cells}
    idle["rst_sipo"] = {"type": "HIGH"}        # active-low reset, held inactive (polarity UNCONFIRMED)
    caps = {c.name: {"mode": "LEVEL"} for c in CHIP.cap_cells}
    return [
        {"name": "idle", "set": idle, "capture": caps, "until": {"after": "10us"}},
        {"name": "sipo_load",
         "set": {"clk_sipo": {"type": "CLOCK", "freq": "1MHz", "cycles": SIPO_BITS, "delay": "2us"},
                 "sipo_in": {"type": "SERIAL", "data": hex(FRAME), "bits": SIPO_BITS, "msb_first": True,
                             "clock": "clk_sipo", "data_edge": "falling"}},
         "until": {"after": "200us"}},
    ]


def test_a_136_bit_sipo_load_compiles_and_encodes():
    table = compile_steps(_sipo_load_steps(), CHIP)
    lay = entry_layout(CHIP)
    st = table.steps[1]
    i = CHIP.sig_index("sipo_in")
    assert st.sig_mask[i] and st.sig[i].bits == SIPO_BITS
    entry = encode_step(st, lay)
    assert len(entry) == 534
    data = int.from_bytes(entry[lay.sig_base[i] + lay.SIG_DATA:][:SIPO_BITS // 8], "little")
    assert data == FRAME                        # 136 bits = 17 whole bytes, nothing lost


class _RecordingDevice:
    """Frame-level fake: records every WRITE_REG and answers reads with zeros (STATUS idle)."""
    def __init__(self):
        self.writes = []
        self.buf = bytearray()

    def write(self, data):
        cmd, addr, payload = link.parse_frame(bytes(data))
        if cmd == link.CMD_WRITE_REG:
            self.writes.append((addr, bytes(payload)))
        elif cmd in (link.CMD_READ_REG, link.CMD_STATUS):
            self.buf += link.build_frame(cmd, addr, bytes(max(1, len(payload))))

    def read(self, size, timeout=None):
        got = bytes(self.buf[:size]); del self.buf[:size]; return got


def test_seqlink_loads_chip_entries_in_frames_of_at_most_128_bytes():
    table = compile_steps(_sipo_load_steps(), CHIP)
    dev = _RecordingDevice()
    link.SeqLink(dev, target=CHIP, clock=lambda: 0.0, sleep=lambda s: None).load(table)
    lay = entry_layout(CHIP)
    table_writes = [(a, d) for a, d in dev.writes if a >= link.V2_TABLE_BASE]
    assert all(len(d) <= link.SeqLink.WRITE_CHUNK for _, d in table_writes)
    for k, st in enumerate(table.steps):
        base = link.V2_TABLE_BASE + k * CHIP.entry_bytes
        got = b"".join(d for a, d in sorted(table_writes) if base <= a < base + CHIP.entry_bytes)
        assert got == encode_step(st, lay)       # the pieces reassemble the whole entry
