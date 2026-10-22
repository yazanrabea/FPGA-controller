"""Phase 6.2: config/phase6_sipo_piso.yaml -> load_phase6_config -> gen_svh --phase6."""
import re

import pytest
import yaml

from nemo_ctl.gen_svh import PHASE6_CONFIG_PATH, generate_phase6
from nemo_ctl.sipo_piso import (
    FrameError, build_piso_read, build_sipo_load, decode_piso_frame, encode_piso_frame,
    load_phase6_config, unpack_sipo_frame,
)


def _variant(tmp_path, edit):
    """Copy of the real config with `edit(doc)` applied."""
    doc = yaml.safe_load(PHASE6_CONFIG_PATH.read_text())
    edit(doc)
    p = tmp_path / "phase6.yaml"
    p.write_text(yaml.safe_dump(doc))
    return p


def test_config_matches_the_1mhz_builders():
    c = load_phase6_config()
    assert c.sipo == build_sipo_load("1MHz")
    assert c.piso == build_piso_read("1MHz")
    assert c.sipo_data_edge == "falling" and c.piso_capture_edge == "falling"


def test_config_frame_and_stages():
    c = load_phase6_config()
    f = unpack_sipo_frame(c.sipo_frame)
    assert f.sel_lo == 0xA5
    assert list(f.slices) == [0x1111 * (k + 1) for k in range(8)]
    assert len(c.tb_piso_stages) == 4


def test_unconfirmed_edges_are_always_warned():
    assert any("UNCONFIRMED" in w for w in load_phase6_config().warnings)


@pytest.mark.parametrize("edit,msg", [
    (lambda d: d["profiles"]["SIPO_LOAD"]["cs"].update(delay="100us"), "incomplete frame"),
    (lambda d: d["profiles"]["SIPO_LOAD"]["clk_sipo"].update(cycles=135), "exactly 136"),
    (lambda d: d["profiles"]["SIPO_LOAD"]["sipo_in"].update(delay="1.1us"), "bit 135"),
    (lambda d: d["profiles"]["SIPO_LOAD"]["sipo_in"].update(msb_first=False), "msb_first"),
    (lambda d: d["profiles"]["PISO_READ"]["shift"].update(delay="0"), "first low phase"),
    (lambda d: d["profiles"]["PISO_READ"]["shift"].update(width="100us"), "reload"),
    (lambda d: d["profiles"]["PISO_READ"]["piso_out"].update(edge="rising"), "falling edge 1"),
    (lambda d: d["profiles"]["PISO_READ"]["piso_out"].update(chip_delay="480ns"), "high time"),
    (lambda d: d["profiles"]["PISO_READ"]["piso_out"].update(bits=167), "168"),
    (lambda d: d["profiles"]["SIPO_LOAD"].pop("cs"), "missing pin 'cs'"),
    (lambda d: d["profiles"]["SIPO_LOAD"]["cs"].update(type="CLOCK"), "type must be PULSE"),
    (lambda d: d["testbench"]["piso_stages"].pop(), "need 4 stages"),
    (lambda d: d["testbench"]["piso_stages"][0].update(out1=0x4000), "out1"),
])
def test_bad_configs_are_rejected(tmp_path, edit, msg):
    with pytest.raises(FrameError, match=re.escape(msg)):
        load_phase6_config(_variant(tmp_path, edit))


def test_nonrtl_polarity_and_rising_data_edge_only_warn(tmp_path):
    def edit(d):
        d["profiles"]["SIPO_LOAD"]["cs"]["polarity"] = "active_low"
        d["profiles"]["SIPO_LOAD"]["sipo_in"]["data_edge"] = "rising"
    c = load_phase6_config(_variant(tmp_path, edit))
    assert any("cs: polarity active_low differs" in w for w in c.warnings)
    assert any("data_edge rising" in w for w in c.warnings)


def _localparam(text, name):
    m = re.search(rf"localparam .*\b{name} = (?:\d+'([hbd])([0-9a-f]+)|(\d+));", text)
    assert m, name
    if m.group(3):
        return int(m.group(3))
    return int(m.group(2), {"h": 16, "b": 2, "d": 10}[m.group(1)])


def test_generated_package_carries_the_checked_ticks():
    text, _ = generate_phase6()
    assert "package phase6_cfg_pkg;" in text and "endpackage" in text
    assert text.count("`ifndef") == 1 and text.count("`endif") == 1
    assert "`timescale 1ns / 1ps" in text
    expect = {"CLK_SIPO_DELAY": 110, "CLK_SIPO_PARAM_A": 100, "CLK_SIPO_PARAM_B": 50,
              "CLK_SIPO_CYCLES": 136, "SIPO_IN_DELAY": 108, "SIPO_IN_BITS": 136,
              "CS_DELAY": 13710, "CS_PARAM_A": 100, "RST_SIPO_IDLE": 1, "RST_SIPO_PARAM_A": 10,
              "CLK_PISO_CYCLES": 168, "SHIFT_DELAY": 75, "SHIFT_PARAM_A": 16700,
              "SHIFT_IDLE": 0, "RST_PISO_TYPE": 1, "RST_PISO_IDLE": 1,
              "PISO_OUT_CAP_MODE": 3, "PISO_OUT_BITS": 168,
              "SIPO_IN_SHIFT_ON_FALLING": 1, "PISO_OUT_CAPTURE_ON_FALLING": 1}
    for name, value in expect.items():
        assert _localparam(text, name) == value, name


def test_generated_vectors_round_trip():
    text, _ = generate_phase6()
    c = load_phase6_config()
    assert _localparam(text, "SIPO_IN_DATA") == c.sipo_frame
    assert _localparam(text, "SIPO_TB_SEL_AFTER_0") == 0x0000A5  # Q1
    assert _localparam(text, "SIPO_TB_SEL_AFTER_3") == 0x4444A5
    frame = _localparam(text, "PISO_TB_FRAME")
    assert frame == encode_piso_frame(c.tb_piso_stages)
    assert decode_piso_frame(frame) == c.tb_piso_stages
    assert _localparam(text, "PISO_TB_STAGE1_TDC_OUT1") == 0x55


def test_bad_config_raises_before_any_text(tmp_path):
    p = _variant(tmp_path, lambda d: d["profiles"]["SIPO_LOAD"]["cs"].update(delay="1us"))
    with pytest.raises(FrameError):
        generate_phase6(p)
