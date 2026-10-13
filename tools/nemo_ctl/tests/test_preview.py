from pathlib import Path

from nemo_ctl.config import load_config
from nemo_ctl.preview import preview_mode

EXAMPLE_CONFIG = Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml"


def test_preview_mode_is_valid_wavedrom_shape():
    cfg = load_config(EXAMPLE_CONFIG)
    doc = preview_mode(cfg, "INFERENCE")
    assert "signal" in doc
    assert all("name" in lane and "wave" in lane for lane in doc["signal"])


def test_preview_includes_every_configured_block_as_a_lane():
    cfg = load_config(EXAMPLE_CONFIG)
    doc = preview_mode(cfg, "INFERENCE")
    names = {lane["name"] for lane in doc["signal"]}
    for block in cfg.modes["INFERENCE"]:
        assert block in names


def test_clock_lane_shows_achieved_frequency():
    cfg = load_config(EXAMPLE_CONFIG)
    doc = preview_mode(cfg, "INFERENCE")
    clk_lane = next(lane for lane in doc["signal"] if lane["name"] == "clk")
    assert "1.000 MHz" in clk_lane["data"][0]


def test_empty_mode_previews_cleanly():
    cfg = load_config(EXAMPLE_CONFIG)
    doc = preview_mode(cfg, "READ")
    assert doc["signal"] == []
