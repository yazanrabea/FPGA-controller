from pathlib import Path

from nemo_ctl.config import Config, PinSetting, load_config
from nemo_ctl.pins import load_pin_db
from nemo_ctl.validate import has_errors, validate_config

EXAMPLE_CONFIG = Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml"


def test_example_inference_config_has_no_errors():
    cfg = load_config(EXAMPLE_CONFIG)
    db = load_pin_db()
    issues = validate_config(cfg, db)
    assert not has_errors(issues), [str(i) for i in issues]


def test_example_inference_config_warns_about_unconfirmed_things():
    cfg = load_config(EXAMPLE_CONFIG)
    db = load_pin_db()
    issues = validate_config(cfg, db)
    messages = " ".join(i.message for i in issues)
    assert "TBD" in messages or "UNCONFIRMED" in messages


def test_unknown_pin_is_an_error():
    cfg = Config(modes={"T": {"SIPO": {"not_a_real_pin": PinSetting("not_a_real_pin", "LOW", {})}}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)


def test_disallowed_type_is_an_error():
    cfg = Config(modes={"T": {"SIPO": {"cs": PinSetting("cs", "CLOCK", {"freq": "1MHz"})}}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)
    assert any("not allowed" in i.message for i in issues)


def test_serial_must_reference_a_clock_pin():
    cfg = Config(modes={"T": {"SIPO": {
        "sipo_in": PinSetting("sipo_in", "SERIAL", {"clock": "clk_sipo", "bits": 136}),
        # clk_sipo deliberately not configured as CLOCK anywhere in this mode
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)
    assert any("not configured as a CLOCK" in i.message for i in issues)


def test_serial_referencing_a_real_clock_pin_is_fine():
    cfg = Config(modes={"T": {"SIPO": {
        "clk_sipo": PinSetting("clk_sipo", "CLOCK", {"freq": "1MHz", "cycles": 136}),
        "sipo_in": PinSetting("sipo_in", "SERIAL", {"clock": "clk_sipo", "bits": 136}),
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert not has_errors(issues)


def test_pin_used_twice_is_an_error():
    cfg = Config(modes={"T": {
        "SIPO": {"cs": PinSetting("cs", "PULSE", {"width": "1us"})},
        "PISO": {"cs": PinSetting("cs", "LOW", {})},
    }})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)
    assert any("already configured" in i.message for i in issues)


def test_wrong_block_for_pin_is_an_error():
    cfg = Config(modes={"T": {"PISO": {"cs": PinSetting("cs", "PULSE", {"width": "1us"})}}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)
    assert any("belongs to block" in i.message for i in issues)


def test_frequency_above_hard_limit_is_an_error():
    cfg = Config(modes={"T": {"Clock Generator": {
        "clk": PinSetting("clk", "CLOCK", {"freq": "60MHz"})
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)
    assert any("hard limit" in i.message for i in issues)


def test_frequency_above_warn_threshold_only_warns():
    cfg = Config(modes={"T": {"Clock Generator": {
        "clk": PinSetting("clk", "CLOCK", {"freq": "20MHz"})
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert not has_errors(issues)
    assert any("jumper-wire" in i.message for i in issues)


def test_bus_value_out_of_range_is_an_error():
    cfg = Config(modes={"T": {"Array with Muxes": {
        "s_p": PinSetting("s_p", "BUS", {"value": 8})  # 3-bit group, max 7
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert has_errors(issues)


def test_bus_value_in_range_is_fine():
    cfg = Config(modes={"T": {"Array with Muxes": {
        "s_p": PinSetting("s_p", "BUS", {"value": 5})
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert not has_errors(issues)


def test_dft_select_resolves_with_a_warning():
    cfg = Config(modes={"T": {"DFT - All": {
        "dft_select": PinSetting("dft_select", "DFT_HELPER", {"adc": 3, "signal": "phi1"})
    }}})
    issues = validate_config(cfg, load_pin_db())
    assert not has_errors(issues)
    assert any("UNCONFIRMED" in i.message for i in issues)
