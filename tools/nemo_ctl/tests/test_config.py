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


def test_pin_map_is_the_agreed_layout():
    # decision 2026-10-26 (docs/decisions.md): every signal has its pin; grouped by block,
    # clk on LA00, the 4 chip outputs on LA16-19
    cfg = load_config(EXAMPLE_CONFIG)
    assert len(cfg.pin_map) == 26 and all(cfg.pin_map.values())
    assert cfg.pin_map["clk"] == "LA00_P" and cfg.pin_map["sipo_in"] == "LA03_P"
    assert [cfg.pin_map[s] for s in ("sipo_out", "piso_out", "dft0_buff", "dft1_buff")] == \
        ["LA16_P", "LA17_P", "LA18_P", "LA19_P"]
    assert len(set(cfg.pin_map.values())) == 26


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
