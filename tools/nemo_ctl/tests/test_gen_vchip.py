"""Chip pipeline step C6 (2026-10-26): gen_svh.py --vchip -> vchip_pkg.sv + vchip_top.xdc,
and `cli seq` on the chip_top target (EXP-08 runs config/chip_sim_test.yaml with it)."""
import re
from pathlib import Path

import pytest
import yaml

from nemo_ctl import cli, gen_svh
from nemo_ctl.config import load_config
from nemo_ctl.fmc_pins import FMC_PINS
from nemo_ctl.sequence import chip_target, load_sequence

REPO = Path(__file__).resolve().parents[3]
CONFIG = REPO / "config" / "nemo_config.yaml"
VCHIP = REPO / "config" / "exp08_vchip.yaml"
PKG, XDC = gen_svh.generate_vchip(CONFIG, VCHIP)
PIN_MAP = load_config(CONFIG).pin_map
CHIP = chip_target()
DFT = {"b0_dft", "b1_dft", "b2_dft", "s0_dft", "s1_dft", "s2_dft", "s3_dft"}


def _ports(xdc: str) -> dict[str, str]:
    return {m.group(2): m.group(1) for m in
            re.finditer(r"set_property PACKAGE_PIN (\S+) \[get_ports \{(\S+)\}\]", xdc)}


def _vdoc():
    return yaml.safe_load(VCHIP.read_text())


def test_committed_files_are_up_to_date():
    assert (REPO / "fpga" / "src" / "gen" / "vchip_pkg.sv").read_text() == PKG
    assert (REPO / "fpga" / "constraints" / "vchip_top.xdc").read_text() == XDC


def test_controller_pins_are_chip_tops_minus_dft():
    ports, chip_ports = _ports(XDC), _ports(gen_svh.generate_chip(CONFIG)[1])
    pinned = [i for i, c in enumerate(CHIP.sig_cells) if c.name not in DFT]
    assert f"localparam int N_CTL = {len(pinned)};" in PKG and len(pinned) == 15
    for k, i in enumerate(pinned):                    # same package pin as in chip_top.xdc
        assert ports[f"ctl_out[{k}]"] == chip_ports[f"chip_out[{i}]"], CHIP.sig_cells[i].name
    for j in range(len(CHIP.cap_cells)):
        assert ports[f"ctl_in[{j}]"] == chip_ports[f"chip_in[{j}]"]


def test_virtual_chip_pins_and_no_pin_twice():
    ports, vp = _ports(XDC), _vdoc()["vchip_pins"]
    for k, n in enumerate(gen_svh.VCHIP_IN):
        assert ports[f"vc_in[{k}]"] == FMC_PINS[vp[n]].package_pin, n
    for k, n in enumerate(gen_svh.VCHIP_OUT):
        assert ports[f"vc_out[{k}]"] == FMC_PINS[vp[n]].package_pin, n
    assert len(ports) == 15 + 4 + 8 + 2 + 9           # + clk + 8 LEDs
    assert len(set(ports.values())) == len(ports)


def test_rules_clocks_and_jumper_table():
    lines = XDC.splitlines()
    for p in ("ctl_out", "vc_out"):
        assert f"set_property DRIVE 4 [get_ports {{{p}[*]}}]" in lines
        assert f"set_property SLEW SLOW [get_ports {{{p}[*]}}]" in lines
    for p in ("ctl_in", "vc_in"):
        assert f"set_property PULLDOWN true [get_ports {{{p}[*]}}]" in lines
    for n in gen_svh.VCHIP_CLOCKS:
        k = gen_svh.VCHIP_IN.index(n)
        assert f"create_clock -name vc_{n} -period 1000.000 [get_ports {{vc_in[{k}]}}]" in lines
        assert f"set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets {{vc_in_IBUF[{k}]}}]" in lines
    assert "##   J3-4   clk_sipo  -> J2-21  virtual chip clk_sipo" in lines
    assert "##   J3-13  pulse     -> J2-27  virtual chip phirst" in lines
    assert "##   J2-17  piso_out  <- J2-29  virtual chip piso_out" in lines


def test_jumper_indices_in_the_package():
    jm = _vdoc()["jumpers"]
    pinned = [c.name for c in CHIP.sig_cells if c.name not in DFT]
    src = [pinned.index(jm[n]) for n in gen_svh.VCHIP_IN]
    dst = [[c.name for c in CHIP.cap_cells].index(jm[n]) for n in gen_svh.VCHIP_OUT]
    assert "VC_SRC [8] = '{" + ", ".join(map(str, src)) + "};" in PKG
    assert "VC_DST [2] = '{" + ", ".join(map(str, dst)) + "};" in PKG


def _write(tmp_path, doc):
    p = tmp_path / "v.yaml"
    p.write_text(yaml.safe_dump(doc))
    return p


def test_refuses_a_pin_the_controller_uses(tmp_path):
    doc = _vdoc()
    doc["vchip_pins"]["phirst"] = PIN_MAP["clk"]
    with pytest.raises(gen_svh.GenError, match="already used by controller clk"):
        gen_svh.generate_vchip(CONFIG, _write(tmp_path, doc))


def test_a_dft_pin_is_free_for_the_virtual_chip(tmp_path):
    doc = _vdoc()
    doc["vchip_pins"]["phirst"] = PIN_MAP["b0_dft"]   # LA15: not pinned in vchip_top
    gen_svh.generate_vchip(CONFIG, _write(tmp_path, doc))


def test_refuses_a_dft_jumper_and_a_wrong_direction(tmp_path):
    doc = _vdoc()
    doc["jumpers"]["phirst"] = "b0_dft"
    with pytest.raises(gen_svh.GenError, match="pinned controller output"):
        gen_svh.generate_vchip(CONFIG, _write(tmp_path, doc))
    doc = _vdoc()
    doc["jumpers"]["piso_out"] = "clk"
    with pytest.raises(gen_svh.GenError, match="controller input"):
        gen_svh.generate_vchip(CONFIG, _write(tmp_path, doc))


def test_refuses_missing_or_extra_names(tmp_path):
    doc = _vdoc()
    del doc["vchip_pins"]["phirst"]
    with pytest.raises(gen_svh.GenError, match="exactly"):
        gen_svh.generate_vchip(CONFIG, _write(tmp_path, doc))


# ---- cli seq on the chip_top target ----

class _FakeSeqLink:
    def __init__(self, target):
        self.target, self.loaded = target, None

    def load(self, table):
        self.loaded = table

    def close(self):
        pass


def test_cli_seq_load_takes_the_target_from_the_file(monkeypatch, capsys):
    seen = []

    def fake_open(args):
        link = _FakeSeqLink(cli._seq_target(args.target))
        seen.append(link)
        return link
    monkeypatch.setattr(cli, "_open_seqlink", fake_open)
    rc = cli.main(["seq", "load", str(REPO / "config" / "chip_sim_test.yaml"), "--jtag"])
    assert rc == 0
    assert seen[0].target.name == "chip_top" and len(seen[0].loaded.steps) == 3
    assert seen[0].loaded == load_sequence(REPO / "config" / "chip_sim_test.yaml", CHIP)


def test_cli_seq_load_refuses_a_contradicting_target(monkeypatch, capsys):
    monkeypatch.setattr(cli, "_open_seqlink", lambda args: pytest.fail("must not open the link"))
    rc = cli.main(["seq", "load", str(REPO / "config" / "chip_sim_test.yaml"), "--jtag",
                   "--target", "phase7_seq_loopback_top"])
    assert rc == 1 and "but --target" in capsys.readouterr().err


def test_seq_target_names():
    assert cli._seq_target(None).name == "phase7_seq_loopback_top"
    assert cli._seq_target("chip_top").name == "chip_top"
