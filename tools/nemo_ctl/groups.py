"""Pin groupings for the BUS setting type (generic_controller_prompt.md §1 item 7) and
the DFT helper (§1, "DFT helper"). Bit order: index 0 in the list is bit 0 of the value.
"""
from __future__ import annotations

PIN_GROUPS: dict[str, list[str]] = {
    "s_p": ["s0_p", "s1_p", "s2_p"],
    "b_dft": ["b0_dft", "b1_dft", "b2_dft"],
    "s_dft": ["s0_dft", "s1_dft", "s2_dft", "s3_dft"],
}


def group_bits(group: str, value: int) -> dict[str, int]:
    """value -> {pin_name: 0|1} for every pin in the group, LSB = first pin."""
    pins = PIN_GROUPS[group]
    if value < 0 or value >= (1 << len(pins)):
        raise ValueError(f"value {value} doesn't fit in {len(pins)}-bit group {group!r}")
    return {pin: (value >> i) & 1 for i, pin in enumerate(pins)}
