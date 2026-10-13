import pytest

from nemo_ctl.dft_helper import resolve as resolve_dft
from nemo_ctl.groups import PIN_GROUPS, group_bits


def test_group_bits_lsb_first():
    bits = group_bits("s_p", 0b101)
    assert bits == {"s0_p": 1, "s1_p": 0, "s2_p": 1}


def test_group_bits_rejects_out_of_range():
    with pytest.raises(ValueError):
        group_bits("s_p", 8)  # 3-bit group, max value 7


def test_every_group_member_is_a_real_pin_name():
    from nemo_ctl.pins import load_pin_db
    db = load_pin_db()
    for members in PIN_GROUPS.values():
        for name in members:
            assert name in db


def test_dft_resolve_is_marked_unconfirmed():
    sel = resolve_dft(3, "phi1")
    assert sel.confirmed is False
    assert sel.b_value == 3
    assert sel.pair_letter == "d"


def test_dft_resolve_rejects_bad_adc():
    with pytest.raises(ValueError):
        resolve_dft(8, "phi1")


def test_dft_resolve_rejects_bad_signal():
    with pytest.raises(ValueError):
        resolve_dft(0, "not_a_signal")
