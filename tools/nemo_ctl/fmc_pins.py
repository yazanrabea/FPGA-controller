"""The 32 FMC LA_P pins the controller may use, and which of them are verified on the board.

Source of truth for the package pins is the verified XDC mapping (CLAUDE.md §5: XDC <->
lab spreadsheet <-> Digilent FMC pinout matched for all 32 LA P pins; see
docs/pin_verification.md). This table is copied from `fpga/constraints/phase4_loopback_top.xdc`
(`fmc_pins[i]` = LAi_P), and tests/test_fmc_pins.py checks it against that file, so the two
can't drift apart. Header positions: J3 carries LA00-LA16, J2 LA17-LA33; position = LA index
(CLAUDE.md §4).

Only the P column is used. The pin map (config `pin_map`) names pins as "LA05_P" etc.
"""
from __future__ import annotations

from dataclasses import dataclass

# LA index -> package pin, from fpga/constraints/phase4_loopback_top.xdc
_PACKAGE_PINS = {
    0: "M19", 1: "N19", 2: "P17", 3: "N22", 4: "M21", 5: "J18", 6: "L21", 7: "T16",
    8: "J21", 9: "R20", 10: "R19", 11: "N17", 12: "P20", 13: "L17", 14: "K19", 15: "J16",
    16: "J20", 17: "B19", 18: "D20", 19: "G15", 20: "G20", 21: "E19", 22: "G19", 23: "E15",
    24: "A18", 25: "D22", 26: "F18", 27: "E21", 28: "A16", 29: "C17", 30: "C15", 31: "B16",
}

# Verified on the board, per direction (docs/pin_verification.md, EXP-01 / EXP-06):
# LA00-04 driven as outputs, LA16-20 read as inputs, through the loopback jumpers.
VERIFIED_AS_OUTPUT = frozenset(range(0, 5))
VERIFIED_AS_INPUT = frozenset(range(16, 21))


@dataclass(frozen=True)
class FmcPin:
    la: int               # LA index
    name: str             # "LA05_P"
    package_pin: str      # e.g. "J18"
    header: str           # e.g. "J3-5"


def _header(la: int) -> str:
    return f"J3-{la}" if la <= 16 else f"J2-{la}"


FMC_PINS: dict[str, FmcPin] = {
    f"LA{i:02d}_P": FmcPin(i, f"LA{i:02d}_P", pkg, _header(i)) for i, pkg in _PACKAGE_PINS.items()
}


def is_verified(pin_name: str, fpga_drives: bool) -> bool:
    """True if this LA pin has been checked on the board in this direction.
    fpga_drives: the FPGA drives it (a chip input) vs. reads it (a chip output)."""
    la = FMC_PINS[pin_name].la
    return la in (VERIFIED_AS_OUTPUT if fpga_drives else VERIFIED_AS_INPUT)
