"""Phase 2 exit criterion (generic_controller_prompt.md §3): "I build a full INFERENCE
profile in the wizard and it round-trips through Excel." Driven headlessly here with a
canned answer sequence standing in for a human at the terminal.

"keep" is used to skip items in tests that aren't exercising them — it's the one menu
choice valid for every pin and every group regardless of allowed types, so it's safe
padding. ("low"/"high" are not: e.g. clk only allows CLOCK, sipo_in only allows SERIAL.)
"""
from pathlib import Path

import pytest

from nemo_ctl.config import Config, PinSetting, config_to_dict
from nemo_ctl.excel_io import export_config, import_config
from nemo_ctl.pins import load_pin_db
from nemo_ctl.validate import has_errors, validate_config
from nemo_ctl.wizard import WizardError, run_wizard

# Per-block "skip everything" sequences: [copy=blank, reset=no, keep * one per item].
# Item counts come from pin_db's block/group structure (checked against gen_pin_db.py):
# Clock Generator=3 items (clk,reset,set), DSA=1 (rst_dsa), Array with Muxes=2
# (pulse, group s_p), DFT - All=1 (group b_dft), dft per ADC=1 (group s_dft),
# SIPO=4 (sipo_in,clk_sipo,cs,rst_sipo), PISO=3 (clk_piso,shift,rst_piso).
CLOCK_GEN_SKIP = ["", "n", "keep", "keep", "keep"]
DSA_SKIP = ["", "n", "keep"]
ARRAY_SKIP = ["", "n", "keep", "keep"]
DFT_ALL_SKIP = ["", "n", "keep"]
DFT_ADC_SKIP = ["", "n", "keep"]
SIPO_SKIP = ["", "n", "keep", "keep", "keep", "keep"]
PISO_SKIP = ["", "n", "keep", "keep", "keep"]
ALL_BLOCKS_SKIP = (
    CLOCK_GEN_SKIP + DSA_SKIP + ARRAY_SKIP + DFT_ALL_SKIP + DFT_ADC_SKIP + SIPO_SKIP + PISO_SKIP
)

# One full pass, every item actually configured, in pin_db block order.
FULL_INFERENCE_ANSWERS = [
    # Clock Generator: no copy, no reset -> walk clk, reset, set
    "", "n",
    "clock", "1MHz", "", "", "",          # clk
    "pulse", "1us", "", "",                # reset
    "low",                                  # set
    # DSA: rst_dsa
    "", "n",
    "pulse", "100ns", "", "",
    # Array with Muxes: pulse, then group s_p
    "", "n",
    "pulse", "1us", "", "",
    "bus", "0b101",
    # DFT - All: group b_dft -> DFT helper (also resolves s_dft)
    "", "n",
    "dft", "3", "phi1",
    # dft per ADC: group s_dft, already resolved by the helper -> keep it
    "", "n",
    "keep",
    # SIPO: sipo_in, clk_sipo, cs, rst_sipo
    "", "n",
    "serial", "clk_sipo", "0xFF", "", "", "",
    "clock", "1MHz", "", "136", "2us",
    "pulse", "1us", "140us", "",
    "pulse", "100ns", "", "",
    # PISO: clk_piso, shift, rst_piso
    "", "n",
    "clock", "1MHz", "", "168", "150us",
    "low",
    "pulse", "100ns", "", "",
]


def _make_ask(answers):
    it = iter(answers)

    def ask(prompt):
        try:
            return next(it)
        except StopIteration:
            raise AssertionError(f"wizard asked for more input than scripted: {prompt!r}") from None

    return ask, it


def test_full_inference_build_validates_and_round_trips_through_excel(tmp_path):
    db = load_pin_db()
    cfg = Config(modes={})
    ask, _ = _make_ask(FULL_INFERENCE_ANSWERS)
    run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)

    issues = validate_config(cfg, db)
    assert not has_errors(issues), [str(i) for i in issues]

    xlsx = tmp_path / "inference.xlsx"
    export_config(cfg, xlsx)
    cfg2 = import_config(xlsx)
    assert config_to_dict(cfg)["modes"] == config_to_dict(cfg2)["modes"]

    # spot-check a few concrete values made it all the way through
    sipo = cfg.modes["INFERENCE"]["SIPO"]
    assert sipo["clk_sipo"].params["cycles"] == 136
    assert sipo["sipo_in"].params["clock"] == "clk_sipo"
    assert cfg.modes["INFERENCE"]["DFT - All"]["dft_select"].params == {"adc": 3, "signal": "phi1"}
    assert "dft per ADC" not in config_to_dict(cfg)["modes"]["INFERENCE"]  # fully absorbed by the helper


def test_all_scripted_answers_are_consumed_exactly():
    db = load_pin_db()
    cfg = Config(modes={})
    ask, remaining = _make_ask(FULL_INFERENCE_ANSWERS)
    run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)
    assert list(remaining) == []  # nothing left unused


def test_copy_block_from_another_mode():
    db = load_pin_db()
    src = Config(modes={})
    ask, _ = _make_ask(FULL_INFERENCE_ANSWERS)
    run_wizard(src, db, "INFERENCE", ask, lambda m: None)

    dst = Config(modes={"INFERENCE": src.modes["INFERENCE"]})
    answers = ["INFERENCE"] + DSA_SKIP + ARRAY_SKIP + DFT_ALL_SKIP + DFT_ADC_SKIP + SIPO_SKIP + PISO_SKIP
    ask, remaining = _make_ask(answers)
    run_wizard(dst, db, "WRITE", ask, lambda m: None)
    assert list(remaining) == []
    assert dst.modes["WRITE"]["Clock Generator"] == src.modes["INFERENCE"]["Clock Generator"]


def test_reset_block_to_defaults_clears_it():
    db = load_pin_db()
    cfg = Config(modes={"INFERENCE": {
        "DSA": {"rst_dsa": PinSetting("rst_dsa", "PULSE", {"width": "1us"})},
    }})
    answers = CLOCK_GEN_SKIP + ["", "y"] + ARRAY_SKIP + DFT_ALL_SKIP + DFT_ADC_SKIP + SIPO_SKIP + PISO_SKIP
    ask, remaining = _make_ask(answers)
    run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)
    assert list(remaining) == []
    assert cfg.modes["INFERENCE"]["DSA"] == {}


def test_invalid_menu_choice_is_rejected_then_retried():
    db = load_pin_db()
    cfg = Config(modes={})
    answers = (
        ["", "n", "not_a_choice", "clock", "1MHz", "", "", "", "keep", "keep"]
        + DSA_SKIP + ARRAY_SKIP + DFT_ALL_SKIP + DFT_ADC_SKIP + SIPO_SKIP + PISO_SKIP
    )
    ask, remaining = _make_ask(answers)
    run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)
    assert list(remaining) == []
    assert cfg.modes["INFERENCE"]["Clock Generator"]["clk"].type == "CLOCK"


def test_overriding_dft_helper_materializes_the_other_group():
    """Picking the DFT helper sets both b_dft and s_dft; later overriding just s_dft with
    a raw bus value must not lose the b_dft side that was never touched again."""
    db = load_pin_db()
    cfg = Config(modes={})
    answers = (
        CLOCK_GEN_SKIP + DSA_SKIP + ARRAY_SKIP
        + ["", "n", "dft", "3", "phi1"]   # DFT - All: helper sets b_dft(=3) and s_dft
        + ["", "n", "bus", "0b10"]         # dft per ADC: override s_dft with a raw value
        + SIPO_SKIP + PISO_SKIP
    )
    ask, remaining = _make_ask(answers)
    run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)
    assert list(remaining) == []

    dft_all = cfg.modes["INFERENCE"]["DFT - All"]
    dft_adc = cfg.modes["INFERENCE"]["dft per ADC"]
    assert "dft_select" not in dft_all
    assert dft_all["b_dft"].params == {"value": 3}  # the helper's pick, preserved
    assert dft_adc["s_dft"].params == {"value": 2}   # the override


def test_bad_pulse_width_raises_wizard_error():
    db = load_pin_db()
    cfg = Config(modes={})
    # clk (CLOCK-only) kept as-is; reset (allows PULSE) given a bad width.
    answers = ["", "n", "keep", "pulse", "not-a-duration"]
    ask, _ = _make_ask(answers)
    with pytest.raises(WizardError):
        run_wizard(cfg, db, "INFERENCE", ask, lambda m: None)
