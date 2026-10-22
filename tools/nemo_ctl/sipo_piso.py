"""Phase 6 (generic_controller_prompt.md §3): SIPO / PISO frames and timing profiles,
modelled on Dima's RTL in fpga/reference/dima_blocks/ (sipo.sv, sipo_wrapper.sv, piso.sv).

Three parts:

1. SIPO frame (136 bits, sent MSB-first: bit 135 first, bit 0 last).
   sipo.sv shifts left and inserts sipo_in at bit 0, so after 136 clk_sipo rising edges
   the first bit sent sits at parallel_out[135]. In sipo_wrapper.sv:
     sel[7:0]  = parallel_out[7:0]                (fixed, the last 8 bits sent)
     sel[23:8] = parallel_out[8+16k +: 16]         ("slice k", k = 0..7)
   Slice 0 is loaded on reset (but parallel_out is also in reset then -> always 0, Q1),
   slice k (1..7) after the k-th phirst rising edge, and the 8th phirst reads past bit
   135 (Q2). dima_sel_after() reproduces exactly that, quirks included -- they are
   documented here, not fixed (docs/controller_spec.md Q1/Q2).

2. PISO frame (168 bits = 4 stages x 42, read MSB-first from PISO0.serial_out).
   piso.sv stage layout (MSB first out): out1[13:0], tdc_out1[6:0], out0[13:0],
   tdc_out0[6:0]. The chain is PISO0 <- PISO1 <- PISO2 <- PISO3 <- 0, so the stream is
   all of PISO0, then PISO1, PISO2, PISO3. As an integer the first bit received is
   bit 167, which is exactly what cap_cell (CAP_W=168, msb_first) leaves in capture_reg.

3. Timing profiles in ticks (100 MHz, units.py) for the generic cells, plus the rules
   that make them correct against Dima's RTL:
     SIPO_LOAD: rst_sipo low PULSE -> clk_sipo CLOCK cycles=136 (starts high, so exactly
       136 rising edges, ends low) -> cs PULSE after the last edge. sipo_in is SERIAL
       MSB-first, shifted on clk_sipo's falling edge, and starts a few ticks before
       clk_sipo so bit 135 is stable at rising edge 1.
     PISO_READ: clk_piso CLOCK cycles=168 (rising edge 1 loads with shift=0, edges 2..168
       shift); shift PULSE rises inside clk_piso's first low phase and stays high past
       edge 168; piso_out captured on clk_piso's falling edge (falling edge 1 samples
       bit 1 before any shift).
   Which clock edge the chip changes/samples data on is UNCONFIRMED (Dima); the profiles
   follow the RTL plus docs/session1 and are kept as config fields from Phase 6.2 on.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import yaml

from .units import quantize_clock, quantize_duration

# ---- SIPO (sipo.sv / sipo_wrapper.sv defaults: WL_num=16, BL_num=8) ----
SIPO_BITS = 136
SEL_LO_BITS = 8
SLICE_BITS = 16
N_SLICES = (SIPO_BITS - SEL_LO_BITS) // SLICE_BITS  # 8

# ---- PISO (piso.sv defaults: OUT=14, TDC_OUT=7, 4 chained stages) ----
OUT_BITS = 14
TDC_BITS = 7
STAGE_BITS = 2 * (OUT_BITS + TDC_BITS)  # 42
PISO_STAGES = 4
PISO_BITS = PISO_STAGES * STAGE_BITS  # 168

# Ticks from a pad change to it being visible in cap_cell: 2-FF synchronizer + the
# cap_cell input register. Used by the PISO capture rule.
CAPTURE_SYNC_TICKS = 3


class FrameError(ValueError):
    pass


class DimaModelUndefined(FrameError):
    """Dima's RTL has no defined value here (Q2: index past WIDTH)."""


def _check_uint(name: str, value: int, bits: int) -> None:
    if not isinstance(value, int) or not 0 <= value < (1 << bits):
        raise FrameError(f"{name}={value!r} doesn't fit {bits} bits")


# ======================================================================================
# SIPO frame
# ======================================================================================

@dataclass(frozen=True)
class SipoFrame:
    sel_lo: int  # parallel_out[7:0] -> sel[7:0]
    slices: tuple[int, ...]  # slices[k] = parallel_out[8+16k +: 16], k = 0..7


def pack_sipo_frame(sel_lo: int, slices: Sequence[int]) -> int:
    """sel[7:0] value + 8 sixteen-bit slices -> the 136-bit parallel_out value."""
    _check_uint("sel_lo", sel_lo, SEL_LO_BITS)
    if len(slices) != N_SLICES:
        raise FrameError(f"need {N_SLICES} slices, got {len(slices)}")
    frame = sel_lo
    for k, s in enumerate(slices):
        _check_uint(f"slices[{k}]", s, SLICE_BITS)
        frame |= s << (SEL_LO_BITS + SLICE_BITS * k)
    return frame


def unpack_sipo_frame(frame: int) -> SipoFrame:
    _check_uint("frame", frame, SIPO_BITS)
    mask = (1 << SLICE_BITS) - 1
    slices = tuple((frame >> (SEL_LO_BITS + SLICE_BITS * k)) & mask for k in range(N_SLICES))
    return SipoFrame(sel_lo=frame & ((1 << SEL_LO_BITS) - 1), slices=slices)


def sipo_tx_bits(frame: int) -> list[int]:
    """Bits in the order they go out on sipo_in: bit 135 first, bit 0 last."""
    _check_uint("frame", frame, SIPO_BITS)
    return [(frame >> i) & 1 for i in range(SIPO_BITS - 1, -1, -1)]


def dima_sel_after(frame: int, phirst_edges: int) -> int:
    """sel[23:0] of sipo_wrapper.sv after rst_sipo, a full load + cs, and `phirst_edges`
    phirst rising edges -- Dima's RTL as written, quirks included:
      0      -> sel[23:8] = 0 (Q1: the reset-time load reads parallel_out while it is
                itself in reset, so slice 0 never reaches sel)
      1..7   -> slices[1..7]
      >= 8   -> DimaModelUndefined (Q2: index runs past WIDTH=136, never wraps)
    """
    f = unpack_sipo_frame(frame)
    if phirst_edges < 0:
        raise FrameError(f"phirst_edges must be >= 0, got {phirst_edges}")
    if phirst_edges == 0:
        hi = 0
    elif phirst_edges < N_SLICES:
        hi = f.slices[phirst_edges]
    else:
        raise DimaModelUndefined(
            f"phirst edge {phirst_edges} reads parallel_out[{8 + 16 * phirst_edges + 15}:"
            f"{8 + 16 * phirst_edges}], past bit {SIPO_BITS - 1} (Q2)")
    return (hi << SEL_LO_BITS) | f.sel_lo


# ======================================================================================
# PISO frame
# ======================================================================================

@dataclass(frozen=True)
class PisoStage:
    out1: int  # stage[41:28], first out
    tdc_out1: int  # stage[27:21]
    out0: int  # stage[20:7]
    tdc_out0: int  # stage[6:0], last out

    def __post_init__(self):
        _check_uint("out1", self.out1, OUT_BITS)
        _check_uint("tdc_out1", self.tdc_out1, TDC_BITS)
        _check_uint("out0", self.out0, OUT_BITS)
        _check_uint("tdc_out0", self.tdc_out0, TDC_BITS)

    def to_bits(self) -> int:
        """The stage's 42-bit register value as piso.sv latches it on a load edge."""
        return (((self.out1 << TDC_BITS | self.tdc_out1) << OUT_BITS | self.out0)
                << TDC_BITS | self.tdc_out0)

    @classmethod
    def from_bits(cls, value: int) -> "PisoStage":
        _check_uint("stage", value, STAGE_BITS)
        tdc_out0 = value & ((1 << TDC_BITS) - 1)
        value >>= TDC_BITS
        out0 = value & ((1 << OUT_BITS) - 1)
        value >>= OUT_BITS
        tdc_out1 = value & ((1 << TDC_BITS) - 1)
        value >>= TDC_BITS
        return cls(out1=value, tdc_out1=tdc_out1, out0=out0, tdc_out0=tdc_out0)


def encode_piso_frame(stages: Sequence[PisoStage]) -> int:
    """4 stages (PISO0 first) -> the 168-bit frame as received, first bit = bit 167."""
    if len(stages) != PISO_STAGES:
        raise FrameError(f"need {PISO_STAGES} stages, got {len(stages)}")
    frame = 0
    for st in stages:
        frame = (frame << STAGE_BITS) | st.to_bits()
    return frame


def decode_piso_frame(frame: int) -> tuple[PisoStage, ...]:
    """168-bit frame (cap_cell capture_reg, first bit received = bit 167) -> 4 stages,
    PISO0 first."""
    _check_uint("frame", frame, PISO_BITS)
    mask = (1 << STAGE_BITS) - 1
    return tuple(
        PisoStage.from_bits((frame >> (STAGE_BITS * (PISO_STAGES - 1 - k))) & mask)
        for k in range(PISO_STAGES)
    )


def bits_to_frame(bits: Sequence[int]) -> int:
    """Bits in arrival order (first = MSB) -> integer."""
    frame = 0
    for i, b in enumerate(bits):
        if b not in (0, 1):
            raise FrameError(f"bits[{i}]={b!r} is not 0/1")
        frame = (frame << 1) | b
    return frame


# ======================================================================================
# Timing profiles (ticks) + rules
# ======================================================================================

@dataclass(frozen=True)
class SipoLoadTiming:
    """All values in ticks from RUN. Rising edge k of clk_sipo is at
    clk_delay + (k-1)*period; it is high for `high` ticks from there."""
    rst_delay: int  # rst_sipo: active-low PULSE
    rst_width: int
    clk_delay: int  # clk_sipo: CLOCK
    period: int
    high: int
    cycles: int
    data_delay: int  # sipo_in: SERIAL, shift_strobe = clk_sipo falling_edge
    cs_delay: int  # cs: active-high PULSE
    cs_width: int

    def rising_edge(self, k: int) -> int:
        return self.clk_delay + (k - 1) * self.period

    def falling_edge(self, k: int) -> int:
        return self.rising_edge(k) + self.high

    @property
    def end(self) -> int:
        return self.cs_delay + self.cs_width


@dataclass(frozen=True)
class PisoReadTiming:
    """All values in ticks from RUN (same edge convention as SipoLoadTiming)."""
    clk_delay: int  # clk_piso: CLOCK
    period: int
    high: int
    cycles: int
    shift_delay: int  # shift: active-high PULSE (0 = load/sample, 1 = shift)
    shift_width: int

    def rising_edge(self, k: int) -> int:
        return self.clk_delay + (k - 1) * self.period

    def falling_edge(self, k: int) -> int:
        return self.rising_edge(k) + self.high

    @property
    def end(self) -> int:
        return max(self.shift_delay + self.shift_width, self.falling_edge(self.cycles))


def build_sipo_load(freq="1MHz", duty="50%", rst_width="100ns", rst_to_clk="1us",
                    data_lead_ticks: int = 2, cs_width="1us") -> SipoLoadTiming:
    """rst_sipo pulses at RUN; clk_sipo starts `rst_to_clk` after rst_sipo releases;
    sipo_in starts `data_lead_ticks` before clk_sipo; cs rises one full clk_sipo period
    after the 136th rising edge (clk_sipo is back low by then)."""
    q = quantize_clock(freq, duty)
    rst_w = quantize_duration(rst_width).ticks
    clk_delay = rst_w + quantize_duration(rst_to_clk).ticks
    return SipoLoadTiming(
        rst_delay=0, rst_width=rst_w,
        clk_delay=clk_delay, period=q.period_ticks, high=q.high_ticks, cycles=SIPO_BITS,
        data_delay=clk_delay - data_lead_ticks,
        cs_delay=clk_delay + SIPO_BITS * q.period_ticks,
        cs_width=quantize_duration(cs_width).ticks,
    )


def build_piso_read(freq="1MHz", duty="50%", clk_delay="0") -> PisoReadTiming:
    """clk_piso from `clk_delay`; shift rises in the middle of clk_piso's first low
    phase and stays high for 167 periods, i.e. past rising edge 168 and its falling
    edge."""
    q = quantize_clock(freq, duty)
    d = quantize_duration(clk_delay).ticks
    low = q.period_ticks - q.high_ticks
    shift_delay = d + q.high_ticks + low // 2
    return PisoReadTiming(
        clk_delay=d, period=q.period_ticks, high=q.high_ticks, cycles=PISO_BITS,
        shift_delay=shift_delay, shift_width=(PISO_BITS - 1) * q.period_ticks,
    )


def check_sipo_load(t: SipoLoadTiming) -> list[str]:
    """Empty list = the profile loads Dima's sipo.sv correctly (as far as RTL timing
    goes; real chip setup/hold and max clk_sipo rate are still unknown, Q7)."""
    errs = []
    if t.cycles != SIPO_BITS:
        errs.append(f"clk_sipo cycles={t.cycles}, must be exactly {SIPO_BITS} "
                    f"(one rising edge per frame bit)")
    if t.period < 2 or not 1 <= t.high < t.period:
        errs.append(f"clk_sipo period={t.period}/high={t.high} ticks gives no clean edge")
    if t.rst_width < 1:
        errs.append("rst_sipo width is 0 ticks")
    if t.clk_delay <= t.rst_delay + t.rst_width:
        errs.append(f"clk_sipo starts at tick {t.clk_delay}, but rst_sipo is still low "
                    f"until tick {t.rst_delay + t.rst_width}: the first edges are lost")
    if t.data_delay >= t.clk_delay:
        errs.append(f"sipo_in starts at tick {t.data_delay}, not before clk_sipo's first "
                    f"rising edge (tick {t.clk_delay}): bit 135 isn't set up for edge 1")
    last_fall = t.falling_edge(t.cycles)
    if t.cs_delay < last_fall:
        errs.append(f"cs rises at tick {t.cs_delay}, before clk_sipo's last falling edge "
                    f"(tick {last_fall}): parallel_out may latch an incomplete frame")
    if t.cs_width < 1:
        errs.append("cs width is 0 ticks")
    return errs


def check_piso_read(t: PisoReadTiming, chip_delay_ticks: int = 0) -> list[str]:
    """Empty list = the profile reads Dima's 4-stage piso2 chain correctly.
    chip_delay_ticks: clk_piso pad -> piso_out pad delay (clk-to-q + 4 DLY3 cells +
    wiring), UNKNOWN until measured; 0 checks only the FPGA-side latency."""
    errs = []
    if t.cycles != PISO_BITS:
        errs.append(f"clk_piso cycles={t.cycles}, must be exactly {PISO_BITS} "
                    f"(1 load edge + {PISO_BITS - 1} shift edges)")
    if t.period < 2 or not 1 <= t.high < t.period:
        errs.append(f"clk_piso period={t.period}/high={t.high} ticks gives no clean edge")
    if not t.falling_edge(1) <= t.shift_delay < t.rising_edge(2):
        errs.append(f"shift rises at tick {t.shift_delay}, outside clk_piso's first low "
                    f"phase [{t.falling_edge(1)}, {t.rising_edge(2)}): edge 1 must load "
                    f"(shift=0) and edge 2 must already shift (shift=1)")
    shift_end = t.shift_delay + t.shift_width
    last_fall = t.falling_edge(t.cycles)
    if shift_end < last_fall:
        errs.append(f"shift falls at tick {shift_end}, before clk_piso's last falling edge "
                    f"(tick {last_fall}): the last edges reload instead of shift")
    need_high = CAPTURE_SYNC_TICKS + chip_delay_ticks
    if t.high < need_high:
        errs.append(f"clk_piso high time {t.high} ticks < {need_high} "
                    f"({CAPTURE_SYNC_TICKS} sync + {chip_delay_ticks} chip/wire): the "
                    f"falling-edge capture samples piso_out before the new bit arrives")
    return errs


# ======================================================================================
# Phase 6.2: config/phase6_sipo_piso.yaml -> checked per-pin settings
# ======================================================================================

DEFAULT_PHASE6_CONFIG = Path(__file__).resolve().parents[2] / "config" / "phase6_sipo_piso.yaml"

# Per-pin requirements of the two profiles: setting type + the polarity Dima's RTL
# implies (rst_n active-low; cs = clk_s, rising-edge; shift = load, 1 = shift). A
# different polarity in the config is allowed (the pad might invert, Q6) but warned.
SIPO_PINS = {"rst_sipo": ("PULSE", "active_low"), "clk_sipo": ("CLOCK", None),
             "sipo_in": ("SERIAL", None), "cs": ("PULSE", "active_high")}
PISO_PINS = {"rst_piso": ("HIGH", None), "clk_piso": ("CLOCK", None),
             "shift": ("PULSE", "active_high"), "piso_out": ("CAPTURE", None)}
EDGES = ("rising", "falling")


@dataclass(frozen=True)
class Phase6Config:
    sipo_pins: dict  # pin -> raw setting dict (type + params), human units
    piso_pins: dict
    sipo: SipoLoadTiming
    piso: PisoReadTiming
    sipo_frame: int  # 136-bit parallel_out value to load
    sipo_data_edge: str  # clk_sipo edge sipo_in changes on (UNCONFIRMED)
    piso_capture_edge: str  # clk_piso edge piso_out is sampled on (UNCONFIRMED)
    chip_delay_ticks: int
    tb_piso_stages: tuple[PisoStage, ...]  # values the 6.4 testbench feeds the piso2 chain
    warnings: tuple[str, ...]


def _ticks(value) -> int:
    return quantize_duration(value if value is not None else 0).ticks


def _frame_from_setting(s: dict) -> int:
    if "frame" in s:
        f = s["frame"]
        return pack_sipo_frame(int(f["sel_lo"]), [int(x) for x in f["slices"]])
    raw = s.get("data")
    if raw is None:
        raise FrameError("sipo_in needs either 'frame: {sel_lo, slices}' or 'data'")
    frame = int(raw, 0) if isinstance(raw, str) else int(raw)
    _check_uint("sipo_in data", frame, SIPO_BITS)
    return frame


def _check_pins(profile: str, pins: dict, spec: dict, errs: list, warns: list) -> None:
    for name, (typ, rtl_polarity) in spec.items():
        s = pins.get(name)
        if s is None:
            errs.append(f"{profile}: missing pin {name!r}")
            continue
        if s.get("type") != typ:
            errs.append(f"{profile}/{name}: type must be {typ}, got {s.get('type')!r}")
        if rtl_polarity and s.get("polarity", "active_high") != rtl_polarity:
            warns.append(f"{profile}/{name}: polarity {s.get('polarity', 'active_high')} differs "
                         f"from Dima's RTL ({rtl_polarity}); only right if the pad inverts (Q6)")
    for name in pins:
        if name not in spec:
            errs.append(f"{profile}: unexpected pin {name!r}")


def load_phase6_config(path: Path | None = None) -> Phase6Config:
    """Parse and check config/phase6_sipo_piso.yaml. Raises FrameError listing every
    problem; warnings (UNCONFIRMED choices) come back in .warnings."""
    with open(path or DEFAULT_PHASE6_CONFIG) as f:
        doc = yaml.safe_load(f) or {}
    profiles = doc.get("profiles") or {}
    sp = profiles.get("SIPO_LOAD") or {}
    pp = profiles.get("PISO_READ") or {}
    errs: list[str] = []
    warns: list[str] = []
    _check_pins("SIPO_LOAD", sp, SIPO_PINS, errs, warns)
    _check_pins("PISO_READ", pp, PISO_PINS, errs, warns)
    if errs:
        raise FrameError("; ".join(errs))

    rst, clk, din, cs = sp["rst_sipo"], sp["clk_sipo"], sp["sipo_in"], sp["cs"]
    cq = quantize_clock(clk["freq"], clk.get("duty", "50%"))
    sipo = SipoLoadTiming(
        rst_delay=_ticks(rst.get("delay")), rst_width=_ticks(rst["width"]),
        clk_delay=_ticks(clk.get("delay")), period=cq.period_ticks, high=cq.high_ticks,
        cycles=int(clk.get("cycles", 0)),
        data_delay=_ticks(din.get("delay")),
        cs_delay=_ticks(cs.get("delay")), cs_width=_ticks(cs["width"]),
    )
    pclk, shift, pout = pp["clk_piso"], pp["shift"], pp["piso_out"]
    pq = quantize_clock(pclk["freq"], pclk.get("duty", "50%"))
    piso = PisoReadTiming(
        clk_delay=_ticks(pclk.get("delay")), period=pq.period_ticks, high=pq.high_ticks,
        cycles=int(pclk.get("cycles", 0)),
        shift_delay=_ticks(shift.get("delay")), shift_width=_ticks(shift["width"]),
    )

    if din.get("clock") != "clk_sipo":
        errs.append(f"SIPO_LOAD/sipo_in: clock must be 'clk_sipo', got {din.get('clock')!r}")
    if int(din.get("bits", 0)) != SIPO_BITS:
        errs.append(f"SIPO_LOAD/sipo_in: bits must be {SIPO_BITS}")
    if din.get("msb_first", True) is not True:
        errs.append("SIPO_LOAD/sipo_in: must be msb_first (bit 135 first, sipo.sv shifts left)")
    if pout.get("mode") != "serial" or pout.get("clock") != "clk_piso":
        errs.append("PISO_READ/piso_out: must be mode: serial, clock: clk_piso")
    if int(pout.get("bits", 0)) != PISO_BITS:
        errs.append(f"PISO_READ/piso_out: bits must be {PISO_BITS}")
    if pout.get("msb_first", True) is not True:
        errs.append("PISO_READ/piso_out: must be msb_first (piso2 shifts out its MSB first)")

    data_edge = din.get("data_edge", "falling")
    cap_edge = pout.get("edge", "falling")
    if data_edge not in EDGES or cap_edge not in EDGES:
        errs.append(f"edges must be one of {EDGES}")
    if data_edge == "rising":
        warns.append("SIPO_LOAD/sipo_in: data_edge rising changes sipo_in 1 tick after the "
                     "edge sipo.sv samples on -- 10 ns hold margin, chip hold time unknown")
    if cap_edge == "rising":
        errs.append("PISO_READ/piso_out: edge rising can't work with 168 clk_piso cycles: "
                    "rising edge 1 is the load, so bit 1 must be read on falling edge 1")
    warns.append("SIPO_LOAD/sipo_in data_edge and PISO_READ/piso_out edge are UNCONFIRMED (Dima)")

    chip_delay = _ticks(pout.get("chip_delay"))
    errs += [f"SIPO_LOAD: {e}" for e in check_sipo_load(sipo)]
    errs += [f"PISO_READ: {e}" for e in check_piso_read(piso, chip_delay)]

    try:
        frame = _frame_from_setting(din)
    except (FrameError, KeyError, TypeError, ValueError) as exc:
        errs.append(f"SIPO_LOAD/sipo_in: {exc}")
        frame = 0
    tb = (doc.get("testbench") or {}).get("piso_stages") or []
    try:
        stages = tuple(PisoStage(**{k: int(v) for k, v in st.items()}) for st in tb)
        if len(stages) != PISO_STAGES:
            raise FrameError(f"need {PISO_STAGES} stages, got {len(stages)}")
    except (FrameError, TypeError) as exc:
        errs.append(f"testbench/piso_stages: {exc}")
        stages = ()
    if errs:
        raise FrameError("; ".join(errs))

    return Phase6Config(sipo_pins=sp, piso_pins=pp, sipo=sipo, piso=piso, sipo_frame=frame,
                        sipo_data_edge=data_edge, piso_capture_edge=cap_edge,
                        chip_delay_ticks=chip_delay, tb_piso_stages=stages,
                        warnings=tuple(warns))
