"""fmc_pins.py (the 32 LA_P pins) and the validator's pin_map checks (step C1, 2026-10-26)."""
import re
from pathlib import Path

from nemo_ctl.config import Config, load_config
from nemo_ctl.fmc_pins import FMC_PINS, VERIFIED_AS_INPUT, VERIFIED_AS_OUTPUT, is_verified
from nemo_ctl.pins import load_pin_db
from nemo_ctl.validate import validate_config

REPO = Path(__file__).resolve().parents[3]
PIN_DB = load_pin_db()


def _xdc_pins(path):
    pat = re.compile(r"PACKAGE_PIN\s+(\S+)\s+\[get_ports \{fmc_pins\[(\d+)\]\}\]")
    return {int(m.group(2)): m.group(1) for m in pat.finditer(path.read_text())}


def test_table_matches_every_verified_xdc():
    # the table must equal the verified mapping in the XDCs, not a hand-typed copy of it
    for xdc in ("phase4_loopback_top.xdc", "phase5_link_jtag_top.xdc", "phase7_link_jtag_top.xdc"):
        pins = _xdc_pins(REPO / "fpga" / "constraints" / xdc)
        assert len(pins) == 32, xdc
        for la, pkg in pins.items():
            assert FMC_PINS[f"LA{la:02d}_P"].package_pin == pkg, (xdc, la)


def test_headers_and_verified_sets():
    assert FMC_PINS["LA00_P"].header == "J3-0" and FMC_PINS["LA16_P"].header == "J3-16"
    assert FMC_PINS["LA17_P"].header == "J2-17" and FMC_PINS["LA31_P"].header == "J2-31"
    assert VERIFIED_AS_OUTPUT == {0, 1, 2, 3, 4} and VERIFIED_AS_INPUT == {16, 17, 18, 19, 20}
    assert is_verified("LA00_P", fpga_drives=True) and not is_verified("LA00_P", fpga_drives=False)
    assert is_verified("LA20_P", fpga_drives=False) and not is_verified("LA20_P", fpga_drives=True)


def _issues(pin_map):
    return [i for i in validate_config(Config(modes={}, pin_map=pin_map), PIN_DB) if i.mode == "pin_map"]


def test_example_config_map_has_no_errors_and_warns_only_unverified_pins():
    issues = [i for i in validate_config(load_config(REPO / "config" / "nemo_config.yaml"), PIN_DB)
              if i.mode == "pin_map"]
    assert not [i for i in issues if i.level == "error"]
    warned = {i.key for i in issues}
    # outputs on LA05-15 and LA20-25 are not verified yet; clk..clk_sipo (LA00-04) and the
    # chip outputs (LA16-19) are
    assert len(warned) == 17
    assert not warned & {"clk", "reset", "set", "sipo_in", "clk_sipo",
                         "sipo_out", "piso_out", "dft0_buff", "dft1_buff"}
    assert "b1_dft" in warned          # LA20 is verified only as an input


def test_pin_map_errors():
    full = {s: None for s in PIN_DB}
    bad = dict(full, clk="LA40_P")
    assert any(i.level == "error" and i.key == "clk" for i in _issues(bad))
    dup = dict(full, clk="LA00_P", reset="LA00_P")
    assert any(i.level == "error" and "already used" in i.message for i in _issues(dup))
    unknown = dict(full, not_a_pin="LA01_P")
    assert any(i.level == "error" and i.key == "not_a_pin" for i in _issues(unknown))


def test_pin_map_warnings_for_gaps():
    partial = {"clk": "LA00_P"}
    issues = _issues(partial)
    assert not [i for i in issues if i.level == "error"]
    assert {i.key for i in issues if "missing from pin_map" in i.message} == set(PIN_DB) - {"clk"}
    assert any(i.key == "reset" and "no FMC pin" in i.message for i in _issues({"clk": "LA00_P", "reset": None}))


def test_empty_pin_map_is_not_checked():
    assert _issues({}) == []
