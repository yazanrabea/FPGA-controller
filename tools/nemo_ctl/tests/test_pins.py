from nemo_ctl.pins import load_pin_db
from nemo_ctl.types import PinType


def test_pin_count_matches_session1_explainer():
    db = load_pin_db()
    assert len(db) == 26
    assert sum(1 for p in db.values() if p.direction == "in") == 22
    assert sum(1 for p in db.values() if p.direction == "out") == 4


def test_known_pad_numbers_from_controller_spec():
    db = load_pin_db()
    assert db["clk_sipo"].pad_digital_sheet == 29
    assert db["clk_sipo"].pad_io_pins_dima == 26
    assert db["cs"].pad_digital_sheet == 31
    assert db["piso_out"].pad_digital_sheet == 58


def test_rst_sipo_disagreement_is_preserved_not_resolved():
    db = load_pin_db()
    rst_sipo = db["rst_sipo"]
    # Absent from "Blocks Interface - Digital" (controller_spec.md §2.1).
    assert rst_sipo.pad_digital_sheet is None
    # Present at pin 37 in "IO-Pins-Dima"'s linear list.
    assert rst_sipo.pad_io_pins_dima == 37
    assert rst_sipo.polarity == "active_low"


def test_dft_select_bit_width_disagreement_is_preserved():
    db = load_pin_db()
    # s2_dft/s3_dft exist on "Blocks Interface - Digital" but not on IO-Pins-Dima's list.
    assert db["s2_dft"].pad_digital_sheet is not None
    assert db["s2_dft"].pad_io_pins_dima is None
    assert db["s3_dft"].pad_digital_sheet is not None
    assert db["s3_dft"].pad_io_pins_dima is None


def test_fmc_la_is_tbd_for_every_pin():
    db = load_pin_db()
    assert all(pin.fmc_la is None for pin in db.values())


def test_allowed_types_are_real_pin_types():
    db = load_pin_db()
    for pin in db.values():
        assert pin.allowed_types
        assert all(isinstance(t, PinType) for t in pin.allowed_types)


def test_resets_are_active_low_per_rtl():
    db = load_pin_db()
    assert db["rst_sipo"].polarity == "active_low"
    assert db["rst_piso"].polarity == "active_low"
