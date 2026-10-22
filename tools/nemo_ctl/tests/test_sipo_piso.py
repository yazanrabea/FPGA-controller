"""Phase 6.1 tests. Besides the pack/decode round trips, a small tick-level model
replays each timing profile the way sig_cell/cap_cell drive the pins and the way
Dima's sipo.sv / piso.sv react to them, so a profile that passes check_*() is also shown
to load/read the right frame (until the real RTL testbench in 6.4 runs in xsim)."""
import random

import pytest

from nemo_ctl.sipo_piso import (
    PISO_BITS, PISO_STAGES, SIPO_BITS, STAGE_BITS,
    DimaModelUndefined, FrameError, PisoStage,
    bits_to_frame, build_piso_read, build_sipo_load, check_piso_read, check_sipo_load,
    decode_piso_frame, dima_sel_after, encode_piso_frame, pack_sipo_frame,
    sipo_tx_bits, unpack_sipo_frame,
)

SLICES = [0x1111 * (k + 1) & 0xFFFF for k in range(8)]  # distinct, easy to spot
FRAME = pack_sipo_frame(0xA5, SLICES)

STAGES = (
    PisoStage(out1=0x3FFF, tdc_out1=0x00, out0=0x1234, tdc_out0=0x7F),
    PisoStage(out1=0x0001, tdc_out1=0x55, out0=0x2AAA, tdc_out0=0x01),
    PisoStage(out1=0x1555, tdc_out1=0x2A, out0=0x0000, tdc_out0=0x40),
    PisoStage(out1=0x2001, tdc_out1=0x7F, out0=0x3FFE, tdc_out0=0x00),
)


# ---------------------------------------------------------------- SIPO frame

def test_sipo_pack_places_sel_lo_and_slices_like_sipo_wrapper():
    assert FRAME & 0xFF == 0xA5  # sel[7:0] = parallel_out[7:0]
    for k in range(8):
        assert (FRAME >> (8 + 16 * k)) & 0xFFFF == SLICES[k]  # parallel_out[8+16k +: 16]
    assert FRAME < 1 << SIPO_BITS


def test_sipo_unpack_round_trip():
    f = unpack_sipo_frame(FRAME)
    assert f.sel_lo == 0xA5
    assert list(f.slices) == SLICES


def test_sipo_tx_order_is_msb_first():
    bits = sipo_tx_bits(1 << 135)
    assert bits[0] == 1 and sum(bits) == 1 and len(bits) == SIPO_BITS
    assert sipo_tx_bits(1)[-1] == 1


def test_shifting_tx_bits_through_sipo_sv_rebuilds_the_frame():
    # sipo.sv: shift_reg <= {shift_reg[134:0], serial_in} on every clk_sipo rising edge
    reg = 0
    for b in sipo_tx_bits(FRAME):
        reg = ((reg << 1) | b) & ((1 << SIPO_BITS) - 1)
    assert reg == FRAME


def test_dima_sel_reproduces_q1_and_q2():
    assert dima_sel_after(FRAME, 0) == 0xA5  # Q1: slice 0 never reaches sel[23:8]
    for k in range(1, 8):
        assert dima_sel_after(FRAME, k) == (SLICES[k] << 8) | 0xA5
    with pytest.raises(DimaModelUndefined):
        dima_sel_after(FRAME, 8)  # Q2: index runs past bit 135


@pytest.mark.parametrize("sel_lo,slices", [(256, [0] * 8), (0, [0] * 7), (0, [0x10000] + [0] * 7)])
def test_sipo_pack_rejects_bad_fields(sel_lo, slices):
    with pytest.raises(FrameError):
        pack_sipo_frame(sel_lo, slices)


# ---------------------------------------------------------------- PISO frame

def test_piso_stage_layout_matches_piso_sv():
    st = PisoStage(out1=1, tdc_out1=0, out0=0, tdc_out0=0)
    assert st.to_bits() == 1 << 28  # out1 = stage[41:28]
    assert PisoStage(0, 1, 0, 0).to_bits() == 1 << 21  # tdc_out1 = [27:21]
    assert PisoStage(0, 0, 1, 0).to_bits() == 1 << 7  # out0 = [20:7]
    assert PisoStage(0, 0, 0, 1).to_bits() == 1  # tdc_out0 = [6:0]


def test_piso_round_trip_puts_piso0_first():
    frame = encode_piso_frame(STAGES)
    assert frame >> (PISO_BITS - STAGE_BITS) == STAGES[0].to_bits()
    assert decode_piso_frame(frame) == STAGES


def test_piso_round_trip_random():
    rng = random.Random(6)
    for _ in range(50):
        stages = tuple(PisoStage(rng.getrandbits(14), rng.getrandbits(7),
                                 rng.getrandbits(14), rng.getrandbits(7)) for _ in range(4))
        assert decode_piso_frame(encode_piso_frame(stages)) == stages


def test_piso_stage_rejects_out_of_range():
    with pytest.raises(FrameError):
        PisoStage(out1=1 << 14, tdc_out1=0, out0=0, tdc_out0=0)
    with pytest.raises(FrameError):
        PisoStage(out1=0, tdc_out1=1 << 7, out0=0, tdc_out0=0)


def test_bits_to_frame():
    assert bits_to_frame([1, 0, 1, 1]) == 0b1011
    with pytest.raises(FrameError):
        bits_to_frame([0, 2])


# ---------------------------------------------------------------- tick-level model

def _clock(t, delay, period, high, cycles):
    return int(delay <= t < delay + cycles * period and (t - delay) % period < high)


def simulate_sipo_load(t, frame):
    """sig_cell pins tick by tick -> sipo.sv. Returns parallel_out after cs."""
    bits = sipo_tx_bits(frame)
    clk = [_clock(i, t.clk_delay, t.period, t.high, t.cycles) for i in range(t.end + 2)]
    # sipo_in: SERIAL, shift_strobe = clk_sipo falling_edge (1 tick after the pin falls,
    # pin updates one more tick later). Before data_delay it idles low.
    sipo_in, n = [], 0
    for i in range(len(clk)):
        if i >= 2 and clk[i - 2] == 1 and clk[i - 1] == 0 and i - 1 > t.data_delay:
            n += 1
        sipo_in.append(bits[n] if t.data_delay <= i and n < SIPO_BITS else 0)
    shift_reg, parallel_out = 0, 0
    for i in range(1, len(clk)):
        rst_n = not (t.rst_delay <= i < t.rst_delay + t.rst_width)
        if not rst_n:
            shift_reg = parallel_out = 0
            continue
        if clk[i] and not clk[i - 1]:
            shift_reg = ((shift_reg << 1) | sipo_in[i - 1]) & ((1 << SIPO_BITS) - 1)
        if i == t.cs_delay:  # cs rising edge
            parallel_out = shift_reg
    return parallel_out


def simulate_piso_read(t, stages, chip_delay=0):
    """sig_cell pins tick by tick -> 4 chained piso2 -> 2-FF sync -> cap_cell SERIAL
    (capture_strobe = clk_piso falling_edge). Returns the captured 168-bit frame."""
    regs = [0] * PISO_STAGES
    end = t.end + chip_delay + 4
    clk = [_clock(i, t.clk_delay, t.period, t.high, t.cycles) for i in range(end)]
    shift = [int(t.shift_delay <= i < t.shift_delay + t.shift_width) for i in range(end)]
    msb = 1 << (STAGE_BITS - 1)
    serial_out = [0] * end  # PISO0.serial_out at the pad
    for i in range(end):
        prev_clk = clk[i - 1] if i else 0  # pins idle low before RUN
        if clk[i] and not prev_clk:
            if not (shift[i - 1] if i else 0):
                regs = [st.to_bits() for st in stages]
            else:
                ins = [int(bool(regs[k + 1] & msb)) for k in range(PISO_STAGES - 1)] + [0]
                regs = [((r << 1) & ((1 << STAGE_BITS) - 1)) | b for r, b in zip(regs, ins)]
        if i + chip_delay < end:
            serial_out[i + chip_delay] = int(bool(regs[0] & msb))
    captured = []
    for i in range(1, end):
        if clk[i - 1] == 1 and clk[i] == 0:  # strobe in the first low tick
            captured.append(serial_out[i - 2] if i >= 2 else 0)  # 2-FF sync: 2 ticks back
    return bits_to_frame(captured[:PISO_BITS])


@pytest.mark.parametrize("freq", ["1MHz", "10MHz", "100kHz"])
def test_default_sipo_profile_passes_rules_and_loads_the_frame(freq):
    t = build_sipo_load(freq)
    assert check_sipo_load(t) == []
    assert simulate_sipo_load(t, FRAME) == FRAME


@pytest.mark.parametrize("freq", ["1MHz", "10MHz", "100kHz"])
def test_default_piso_profile_passes_rules_and_reads_the_frame(freq):
    t = build_piso_read(freq)
    assert check_piso_read(t) == []
    assert decode_piso_frame(simulate_piso_read(t, STAGES)) == STAGES


def test_1mhz_numbers():
    s = build_sipo_load("1MHz")
    assert (s.rst_width, s.clk_delay, s.period, s.high, s.data_delay) == (10, 110, 100, 50, 108)
    assert s.cs_delay == 110 + 136 * 100
    p = build_piso_read("1MHz")
    assert (p.period, p.high, p.shift_delay, p.shift_width) == (100, 50, 75, 167 * 100)


def test_sipo_rules_catch_what_breaks_the_load():
    from dataclasses import replace
    t = build_sipo_load("1MHz")
    late_data = replace(t, data_delay=t.clk_delay)
    assert any("bit 135" in e for e in check_sipo_load(late_data))
    assert simulate_sipo_load(late_data, FRAME) != FRAME
    early_cs = replace(t, cs_delay=t.falling_edge(135))
    assert any("incomplete frame" in e for e in check_sipo_load(early_cs))
    assert simulate_sipo_load(early_cs, FRAME) != FRAME
    in_reset = replace(t, clk_delay=t.rst_width - 1, data_delay=0)
    assert any("rst_sipo" in e for e in check_sipo_load(in_reset))
    assert check_sipo_load(replace(t, cycles=135))


def test_piso_rules_catch_what_breaks_the_read():
    from dataclasses import replace
    t = build_piso_read("1MHz", clk_delay="1us")
    early_shift = replace(t, shift_delay=t.clk_delay - 5)  # shift=1 already at the load edge
    assert any("first low phase" in e for e in check_piso_read(early_shift))
    assert decode_piso_frame(simulate_piso_read(early_shift, STAGES)) != STAGES
    short_shift = replace(t, shift_width=100 * 100)
    assert any("reload" in e for e in check_piso_read(short_shift))
    assert decode_piso_frame(simulate_piso_read(short_shift, STAGES)) != STAGES


def test_piso_capture_needs_high_time_for_sync_and_chip_delay():
    t = build_piso_read("50MHz")  # period 2, high 1 tick
    assert any("high time" in e for e in check_piso_read(t))
    assert decode_piso_frame(simulate_piso_read(t, STAGES)) != STAGES
    t = build_piso_read("1MHz")  # high 50 ticks
    assert check_piso_read(t, chip_delay_ticks=40) == []
    assert any("high time" in e for e in check_piso_read(t, chip_delay_ticks=48))
    assert decode_piso_frame(simulate_piso_read(t, STAGES, chip_delay=40)) == STAGES
