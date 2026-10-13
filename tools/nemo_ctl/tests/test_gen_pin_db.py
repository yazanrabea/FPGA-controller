"""Regression check: the checked-in data/pin_db.yaml must match what the generator
produces from the live workbooks right now. If this fails, someone edited the workbook
or the yaml by hand without re-running tools/nemo_ctl/gen_pin_db.py."""
from nemo_ctl import gen_pin_db
from nemo_ctl.pins import load_pin_db


def test_checked_in_pin_db_matches_generator_output():
    fresh = gen_pin_db.build_pin_db()
    checked_in = load_pin_db()
    assert len(fresh) == len(checked_in)
    for entry in fresh:
        pin = checked_in[entry["name"]]
        assert pin.pad_digital_sheet == entry["pad_digital_sheet"]
        assert pin.pad_io_pins_dima == entry["pad_io_pins_dima"]
        assert pin.block == entry["block"]
        assert pin.direction == entry["direction"]
