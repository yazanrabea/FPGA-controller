"""Chip pipeline step C3 (2026-10-26): gen_svh.py --chip -> chip_pkg.sv + chip_top.xdc."""
import re
from pathlib import Path

import pytest

from nemo_ctl import gen_svh
from nemo_ctl.config import load_config
from nemo_ctl.fmc_pins import FMC_PINS
from nemo_ctl.sequence import chip_target, entry_layout

REPO = Path(__file__).resolve().parents[3]
CONFIG = REPO / "config" / "nemo_config.yaml"
CHIP = chip_target()
PKG, XDC = gen_svh.generate_chip(CONFIG)
PIN_MAP = load_config(CONFIG).pin_map


def _ports(xdc: str) -> dict[str, str]:
    """port -> package pin, from every PACKAGE_PIN line."""
    return {m.group(2): m.group(1) for m in
            re.finditer(r"set_property PACKAGE_PIN (\S+) \[get_ports \{(\S+)\}\]", xdc)}


def _verified_la_pins() -> dict[int, str]:
    xdc = (REPO / "fpga" / "constraints" / "phase4_loopback_top.xdc").read_text()
    return {int(m.group(2)): m.group(1) for m in
            re.finditer(r"PACKAGE_PIN (\S+) \[get_ports \{fmc_pins\[(\d+)\]\}\]", xdc)}


def test_every_chip_pin_matches_the_verified_xdc_mapping():
    ports, verified = _ports(XDC), _verified_la_pins()
    for i, c in enumerate(CHIP.sig_cells):
        la = FMC_PINS[PIN_MAP[c.name]].la
        assert ports[f"chip_out[{i}]"] == verified[la], c.name
    for j, c in enumerate(CHIP.cap_cells):
        la = FMC_PINS[PIN_MAP[c.name]].la
        assert ports[f"chip_in[{j}]"] == verified[la], c.name


def test_pin_count_and_no_pin_twice():
    ports = _ports(XDC)
    chip = {p: k for p, k in ports.items() if p.startswith("chip_")}
    assert len(chip) == 26 and len(ports) == 26 + 9          # + clk + 8 LEDs
    assert len(set(ports.values())) == len(ports)


def test_drive_rule_on_outputs_pulldown_on_inputs():
    lines = XDC.splitlines()
    assert "set_property IOSTANDARD LVCMOS18 [get_ports {chip_out[*]}]" in lines
    assert "set_property DRIVE 4 [get_ports {chip_out[*]}]" in lines
    assert "set_property SLEW SLOW [get_ports {chip_out[*]}]" in lines
    assert "set_property IOSTANDARD LVCMOS18 [get_ports {chip_in[*]}]" in lines
    assert "set_property PULLDOWN true [get_ports {chip_in[*]}]" in lines
    assert not [l for l in lines if "DRIVE" in l and "chip_in" in l]   # inputs have no drive


def test_board_lines_are_the_verified_ones():
    ref = (REPO / "fpga" / "constraints" / "phase7_link_jtag_top.xdc").read_text().splitlines()
    for line in gen_svh.BOARD_XDC_LINES:
        assert line in ref and line in XDC.splitlines()
    assert "create_clock -name jtag_tck -period 33.333 [get_pins -hierarchical *u_bscan/TCK]" in XDC


def test_package_matches_the_target_and_layout():
    lay = entry_layout(CHIP)
    assert f"localparam int N_SIG = {len(CHIP.sig_cells)};" in PKG
    assert f"localparam int USED_BYTES = {lay.used_bytes};" in PKG
    assert f"localparam int ENTRY_BYTES = {CHIP.entry_bytes};" in PKG
    assert f"localparam int SIPO_CELL = {CHIP.sig_index('sipo_in')};" in PKG
    assert f"localparam int PISO_CLK_CELL = {CHIP.sig_index('clk_piso')};" in PKG
    widths = re.search(r"SIG_SERIAL_W \[N_SIG\] = '\{([^}]*)\}", PKG).group(1)
    assert [int(w) for w in widths.split(",")] == [c.serial_w for c in CHIP.sig_cells]


def test_committed_files_are_up_to_date():
    assert (REPO / "fpga" / "src" / "gen" / "chip_pkg.sv").read_text() == PKG
    assert (REPO / "fpga" / "constraints" / "chip_top.xdc").read_text() == XDC


def test_refuses_an_incomplete_pin_map(tmp_path):
    text = CONFIG.read_text().replace("  clk: LA00_P", "  clk: null")
    assert text != CONFIG.read_text()
    cfg = tmp_path / "c.yaml"
    cfg.write_text(text)
    with pytest.raises(gen_svh.GenError, match="clk"):
        gen_svh.generate_chip(cfg)


def test_refuses_a_duplicate_pin(tmp_path):
    cfg = tmp_path / "c.yaml"
    cfg.write_text(CONFIG.read_text().replace("  reset: LA01_P", "  reset: LA00_P"))
    with pytest.raises(gen_svh.GenError, match="already used"):
        gen_svh.generate_chip(cfg)
