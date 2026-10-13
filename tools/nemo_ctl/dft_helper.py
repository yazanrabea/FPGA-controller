"""DFT "pick ADC k, signal X" helper -> raw b0-2_dft / s0-3_dft bits.

**UNCONFIRMED** (docs/controller_spec.md §4): bit order, which letter is which b2..b0
code, and which s-code gives which signal on dft_0 vs dft_1 are all unverified pending
Dima. This module encodes the brief's own description as a best-effort mapping so the
wizard/preview have something to show, but every result is flagged `confirmed=False` and
must not be treated as chip-accurate. Raw BUS control of b0-2_dft / s0-3_dft (see
groups.py) remains the reliable fallback.
"""
from __future__ import annotations

from dataclasses import dataclass

# "DFT - All" 8:1 mux of pairs, schematic order a..h (generic_controller_prompt.md §1).
# Index = assumed b2..b0 code (0..7) -- the assumption that 'a' is code 0 and so on is
# itself unconfirmed, there is no explicit letter->code table in any source we have.
PAIR_LETTERS = ["a", "b", "c", "d", "e", "f", "g", "h"]
PAIR_SOURCES = {  # letter -> (source feeding dft0_buff, source feeding dft1_buff)
    "a": ("dft13", "dft03"),
    "b": ("dft12", "dft02"),
    "c": ("dft11", "dft01"),
    "d": ("dft10", "dft00"),
    "e": ("dft17", "dft07"),
    "f": ("dft16", "dft06"),
    "g": ("dft15", "dft05"),
    "h": ("dft14", "dft04"),
}

# Inside one "dft per ADC" mux: d0..d7 = phirst, phi1, phi2, vtc_out_dft, repeated on d4..d7.
D_SIGNALS = ["phirst", "phi1", "phi2", "vtc_out_dft", "phirst", "phi1", "phi2", "vtc_out_dft"]
SIGNAL_NAMES = ("phirst", "phi1", "phi2", "vtc_out_dft")


@dataclass(frozen=True)
class DftSelection:
    b_value: int
    s_value: int
    pair_letter: str
    confirmed: bool
    note: str


def resolve(adc: int, signal: str) -> DftSelection:
    """adc: which of the 8 "dft per ADC" pairs (0..7, picks b2..b0).
    signal: one of SIGNAL_NAMES, picked inside that pair's mux (picks s0..s3).
    """
    if not (0 <= adc < 8):
        raise ValueError(f"adc must be 0..7, got {adc}")
    if signal not in SIGNAL_NAMES:
        raise ValueError(f"signal must be one of {SIGNAL_NAMES}, got {signal!r}")
    s_value = D_SIGNALS.index(signal)  # picks the lower index (d0..d3) of the repeated pair
    return DftSelection(
        b_value=adc,
        s_value=s_value,
        pair_letter=PAIR_LETTERS[adc],
        confirmed=False,
        note="UNCONFIRMED mapping (controller_spec.md §4) — ask Dima before trusting this bit pattern.",
    )
