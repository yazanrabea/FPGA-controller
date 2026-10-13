"""The 7 pin setting types from generic_controller_prompt.md §1."""
from __future__ import annotations

from enum import Enum


class PinType(str, Enum):
    LOW = "LOW"
    HIGH = "HIGH"
    PULSE = "PULSE"
    CLOCK = "CLOCK"
    SERIAL = "SERIAL"
    CAPTURE = "CAPTURE"
    BUS = "BUS"

    def __str__(self) -> str:
        return self.value
