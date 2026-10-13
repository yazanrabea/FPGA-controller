"""Phase 2 interactive wizard engine (generic_controller_prompt.md §3 Phase 2).

Deliberately split from the CLI shell: every function here takes `ask`/`tell` callables
instead of calling input()/print() directly, so the whole flow can be driven headlessly
in tests (feed a canned list of answers, capture the transcript) as well as from a real
terminal. The wizard writes the same Config object `config.py`/`excel_io.py` use — the
wizard, the YAML and the Excel sheet are three views of one format.

Flow: for each block, offer copy-from-another-mode / reset-to-defaults / walk its input
pins one by one. Each input pin shows its current setting and a menu built from exactly
the types that pin's pin_db entry allows (0/1/pulse/clock/serial), always with keep/skip.
Pins that belong to a BUS group (groups.PIN_GROUPS) are walked once as a group, with a
"set individually" escape hatch back to the raw per-pin menu, plus a DFT helper shortcut
for the two DFT groups.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from typing import Callable

from .config import DFT_HELPER_TYPE, Config, PinSetting
from .dft_helper import SIGNAL_NAMES, resolve as resolve_dft
from .groups import PIN_GROUPS, group_bits
from .pins import Pin, input_blocks
from .types import PinType
from .units import UnitsError, quantize_clock, quantize_duration

Ask = Callable[[str], str]
Tell = Callable[[str], None]

DFT_GROUPS = {"b_dft", "s_dft"}


class WizardError(ValueError):
    pass


@dataclass(frozen=True)
class _Item:
    kind: str  # "pin" | "group"
    name: str | None = None
    group: str | None = None
    members: tuple[str, ...] = ()


def _build_items(pin_names: list[str]) -> list[_Item]:
    items: list[_Item] = []
    seen_groups: set[str] = set()
    for name in pin_names:
        group = next((g for g, members in PIN_GROUPS.items() if name in members), None)
        if group:
            if group in seen_groups:
                continue
            seen_groups.add(group)
            items.append(_Item("group", group=group, members=tuple(PIN_GROUPS[group])))
        else:
            items.append(_Item("pin", name=name))
    return items


def _fmt_setting(setting: PinSetting | None) -> str:
    if setting is None:
        return "unset (idle)"
    return f"{setting.type} {setting.params}" if setting.params else setting.type


def _menu(allowed_types: tuple[PinType, ...], extra: list[tuple[str, str]] | None = None) -> list[tuple[str, str]]:
    opts: list[tuple[str, str]] = []
    if PinType.LOW in allowed_types:
        opts.append(("low", "0 (constant low)"))
    if PinType.HIGH in allowed_types:
        opts.append(("high", "1 (constant high)"))
    if PinType.PULSE in allowed_types:
        opts.append(("pulse", "pulse"))
    if PinType.CLOCK in allowed_types:
        opts.append(("clock", "clock"))
    if PinType.SERIAL in allowed_types:
        opts.append(("serial", "serial"))
    opts = (extra or []) + opts
    opts.append(("keep", "keep / skip (leave as-is)"))
    return opts


def _prompt_menu(ask: Ask, tell: Tell, options: list[tuple[str, str]]) -> str:
    for i, (kw, label) in enumerate(options, 1):
        tell(f"    {i}. {label} [{kw}]")
    while True:
        raw = ask("  choice: ").strip().lower()
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1][0]
        exact = [kw for kw, _ in options if kw == raw]
        if exact:
            return exact[0]
        prefix = [kw for kw, _ in options if raw and kw.startswith(raw)]
        if len(prefix) == 1:
            return prefix[0]
        tell(f"  not understood: {raw!r} — try again")


def _build_setting(pin: Pin, choice: str, ask: Ask, tell: Tell) -> PinSetting:
    if choice == "low":
        return PinSetting(pin.name, PinType.LOW.value, {})
    if choice == "high":
        return PinSetting(pin.name, PinType.HIGH.value, {})

    if choice == "pulse":
        width = ask("  width (e.g. 1us, 100ns): ").strip()
        try:
            q = quantize_duration(width)
        except UnitsError as exc:
            raise WizardError(str(exc)) from None
        tell(f"    -> {q.ticks} ticks ({q.achieved_ns:.0f} ns, {q.error_pct:+.2f}%)")
        params: dict = {"width": width}
        delay = ask("  delay (blank = 0): ").strip()
        if delay:
            qd = quantize_duration(delay)
            tell(f"    -> delay {qd.ticks} ticks ({qd.achieved_ns:.0f} ns)")
            params["delay"] = delay
        default_pol = pin.polarity or "active_high"
        pol = ask(f"  polarity (active_high/active_low, blank = {default_pol}): ").strip()
        params["polarity"] = pol or default_pol
        return PinSetting(pin.name, PinType.PULSE.value, params)

    if choice == "clock":
        freq = ask("  frequency (e.g. 1MHz): ").strip()
        duty = ask("  duty (blank = 50%): ").strip() or "50%"
        try:
            q = quantize_clock(freq, duty)
        except UnitsError as exc:
            raise WizardError(str(exc)) from None
        tell(f"    -> achieved {q.achieved_hz/1e6:.4f} MHz (N={q.period_ticks} ticks, "
             f"high={q.high_ticks}, {q.error_pct:+.2f}%)")
        params = {"freq": freq, "duty": duty}
        cycles = ask("  cycles (blank = free-running): ").strip()
        if cycles:
            params["cycles"] = int(cycles)
        delay = ask("  delay (blank = 0): ").strip()
        if delay:
            params["delay"] = delay
        return PinSetting(pin.name, PinType.CLOCK.value, params)

    if choice == "serial":
        clock = ask("  clock pin this shifts on (e.g. clk_sipo): ").strip()
        data = ask("  data (hex string or file path): ").strip()
        default_bits = pin.limits.get("frame_bits")
        bits_raw = ask(f"  bits (blank = {default_bits}): ").strip()
        msb = ask("  msb first? [Y/n]: ").strip().lower()
        edge = ask("  data changes on which clk_sipo edge (falling/rising, blank = falling): ").strip()
        params = {
            "clock": clock, "data": data,
            "msb_first": msb not in ("n", "no"),
            "data_edge": edge or "falling",
        }
        if bits_raw:
            params["bits"] = int(bits_raw)
        elif default_bits:
            params["bits"] = default_bits
        tell(f"    -> SERIAL referencing {clock!r} (checked against configured CLOCK pins by validate_config)")
        return PinSetting(pin.name, PinType.SERIAL.value, params)

    raise AssertionError(f"unhandled choice {choice!r}")


def _run_pin(config: Config, mode: str, block: str, pin: Pin, ask: Ask, tell: Tell) -> None:
    current = config.modes[mode][block].get(pin.name)
    tell(f"-- {pin.name} ({pin.block}) -- current: {_fmt_setting(current)}")
    if pin.notes:
        tell(f"   note: {pin.notes}")
    choice = _prompt_menu(ask, tell, _menu(pin.allowed_types))
    if choice == "keep":
        return
    config.modes[mode][block][pin.name] = _build_setting(pin, choice, ask, tell)


def _materialize_dft_helper(config: Config, mode: str, selection) -> None:
    """Expand a `dft_select` helper pick back into explicit b_dft/s_dft BUS settings,
    so overriding just one of the two groups afterward doesn't lose the other."""
    config.modes[mode].setdefault("DFT - All", {})["b_dft"] = PinSetting(
        "b_dft", PinType.BUS.value, {"value": selection.b_value})
    config.modes[mode].setdefault("dft per ADC", {})["s_dft"] = PinSetting(
        "s_dft", PinType.BUS.value, {"value": selection.s_value})
    config.modes[mode]["DFT - All"].pop("dft_select", None)


def _run_dft_helper(config: Config, mode: str, ask: Ask, tell: Tell, dft_handled: dict) -> None:
    adc_raw = ask("  ADC index 0-7: ").strip()
    signal = ask(f"  signal ({'/'.join(SIGNAL_NAMES)}): ").strip()
    try:
        sel = resolve_dft(int(adc_raw), signal)
    except (ValueError, TypeError) as exc:
        raise WizardError(str(exc)) from None
    tell(f"  -> pair {sel.pair_letter!r}, b={sel.b_value:03b}, s={sel.s_value:03b} "
         f"(b2..b0 / s0..s2) — {sel.note}")
    for g in DFT_GROUPS:
        for blk in config.modes[mode].values():
            blk.pop(g, None)
            for m in PIN_GROUPS[g]:
                blk.pop(m, None)
    config.modes[mode].setdefault("DFT - All", {})["dft_select"] = PinSetting(
        "dft_select", DFT_HELPER_TYPE, {"adc": sel.b_value, "signal": signal})
    for g in DFT_GROUPS:
        dft_handled[g] = sel


def _run_group(config: Config, pin_db: dict[str, Pin], mode: str, block: str, group: str,
               members: tuple[str, ...], ask: Ask, tell: Tell, dft_handled: dict) -> None:
    tell(f"-- group {group} ({', '.join(members)}) --")
    if group in dft_handled:
        sel = dft_handled[group]
        tell(f"   currently set via DFT helper: adc(b)={sel.b_value:03b} s={sel.s_value:03b}, "
             f"pair={sel.pair_letter!r}")
    else:
        current = config.modes[mode][block].get(group)
        tell(f"   current bus setting: {_fmt_setting(current)}")

    extra = [("individual", "set pins individually")]
    if group in DFT_GROUPS:
        extra = [("dft", "DFT helper (pick ADC + signal)")] + extra
    options = [("bus", "set as one bus value")] + extra + [("keep", "keep / skip (leave as-is)")]
    choice = _prompt_menu(ask, tell, options)

    if choice == "keep":
        return
    if choice == "dft":
        _run_dft_helper(config, mode, ask, tell, dft_handled)
        return

    if group in dft_handled:
        tell(f"   note: overriding the DFT helper pick for {group!r}")
        _materialize_dft_helper(config, mode, dft_handled[group])
        dft_handled.pop("b_dft", None)
        dft_handled.pop("s_dft", None)

    if choice == "bus":
        raw = ask(f"  value for {list(members)} (decimal, 0x.., or 0b..): ").strip()
        try:
            value = int(raw, 0)
            group_bits(group, value)  # raises if out of range
        except ValueError as exc:
            raise WizardError(f"bad bus value {raw!r}: {exc}") from None
        tell(f"    -> {group_bits(group, value)}")
        for m in members:
            config.modes[mode][block].pop(m, None)
        config.modes[mode][block][group] = PinSetting(group, PinType.BUS.value, {"value": value})
    elif choice == "individual":
        config.modes[mode][block].pop(group, None)
        for m in members:
            _run_pin(config, mode, block, pin_db[m], ask, tell)


def run_wizard(config: Config, pin_db: dict[str, Pin], mode: str, ask: Ask, tell: Tell) -> Config:
    config.modes.setdefault(mode, {})
    dft_handled: dict[str, object] = {}

    for block_name, pin_names in input_blocks(pin_db).items():
        config.modes[mode].setdefault(block_name, {})
        tell(f"\n=== Block: {block_name} ===")

        copy_from = ask(f"Copy block {block_name!r} from another mode? "
                         f"Enter mode name, or blank to skip: ").strip()
        if copy_from:
            if copy_from not in config.modes or block_name not in config.modes[copy_from]:
                tell(f"  nothing to copy from {copy_from!r}, skipping")
            else:
                config.modes[mode][block_name] = deepcopy(config.modes[copy_from][block_name])
                tell(f"  copied {len(config.modes[mode][block_name])} setting(s) from {copy_from!r}")
                continue

        do_reset = ask(f"Reset block {block_name!r} to defaults (clear it)? [y/N]: ").strip().lower()
        if do_reset in ("y", "yes"):
            config.modes[mode][block_name] = {}
            tell("  cleared.")
            continue

        for item in _build_items(pin_names):
            if item.kind == "pin":
                _run_pin(config, mode, block_name, pin_db[item.name], ask, tell)
            else:
                _run_group(config, pin_db, mode, block_name, item.group, item.members,
                            ask, tell, dft_handled)

    tell(f"\nDone building mode {mode!r}.")
    return config
