from pathlib import Path

import pytest

from nemo_ctl.config import ConfigError, config_to_dict, load_config, save_config

EXAMPLE_CONFIG = Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml"


def test_example_config_loads():
    cfg = load_config(EXAMPLE_CONFIG)
    assert set(cfg.mode_names()) == {"READ", "WRITE", "INFERENCE"}
    assert cfg.modes["READ"] == {}
    assert "SIPO" in cfg.modes["INFERENCE"]


def test_iter_settings_yields_block_key_setting():
    cfg = load_config(EXAMPLE_CONFIG)
    found = {(b, k) for b, k, _ in cfg.iter_settings("INFERENCE")}
    assert ("SIPO", "clk_sipo") in found
    assert ("PISO", "piso_out") in found


def test_pin_map_is_all_tbd():
    cfg = load_config(EXAMPLE_CONFIG)
    assert cfg.pin_map  # not empty
    assert all(v is None for v in cfg.pin_map.values())


def test_setting_missing_type_raises(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text("modes:\n  X:\n    Block:\n      pin1: {freq: 1MHz}\n")
    with pytest.raises(ConfigError):
        load_config(bad)


def test_setting_unknown_type_raises(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text("modes:\n  X:\n    Block:\n      pin1: {type: NOT_A_TYPE}\n")
    with pytest.raises(ConfigError):
        load_config(bad)


def test_round_trip_through_yaml(tmp_path):
    cfg = load_config(EXAMPLE_CONFIG)
    out = tmp_path / "roundtrip.yaml"
    save_config(cfg, out)
    cfg2 = load_config(out)
    assert config_to_dict(cfg) == config_to_dict(cfg2)
