import pytest

from nemo_ctl.units import (
    UnitsError,
    ns_to_ticks,
    parse_duration_ns,
    parse_duty,
    parse_freq_hz,
    quantize_clock,
    quantize_duration,
)


def test_parse_duration_units():
    assert parse_duration_ns("100ns") == 100
    assert parse_duration_ns("1us") == 1000
    assert parse_duration_ns("1.5ms") == 1_500_000
    assert parse_duration_ns("2s") == 2_000_000_000
    assert parse_duration_ns(0) == 0
    assert parse_duration_ns("0") == 0


def test_parse_freq_units():
    assert parse_freq_hz("1MHz") == 1_000_000
    assert parse_freq_hz("500kHz") == 500_000
    assert parse_freq_hz("100Hz") == 100
    assert parse_freq_hz(1_000_000) == 1_000_000


def test_parse_duty():
    assert parse_duty("50%") == 0.5
    assert parse_duty(0.5) == 0.5
    assert parse_duty(25) == 0.25


def test_bad_units_raise():
    with pytest.raises(UnitsError):
        parse_duration_ns("not a duration")
    with pytest.raises(UnitsError):
        parse_freq_hz("fast")


def test_quantize_clock_matches_brief_worked_example():
    # generic_controller_prompt.md §2: "3 MHz -> N=33 -> 3.0303 MHz, +1.0%"
    q = quantize_clock("3MHz")
    assert q.period_ticks == 33
    assert q.achieved_hz == pytest.approx(3_030_303.03, rel=1e-6)
    assert q.error_pct == pytest.approx(1.01, abs=0.01)


def test_quantize_clock_exact_1mhz():
    q = quantize_clock("1MHz", "50%")
    assert q.period_ticks == 100
    assert q.high_ticks == 50
    assert q.achieved_hz == 1_000_000
    assert q.error_pct == 0


def test_quantize_clock_minimum_period_is_two_ticks():
    # 100 MHz timebase / 2-tick period = 50 MHz ceiling.
    q = quantize_clock("100MHz")
    assert q.period_ticks == 2
    assert q.achieved_hz == 50_000_000


def test_quantize_clock_rejects_non_positive_freq():
    with pytest.raises(UnitsError):
        quantize_clock("0Hz")


def test_quantize_duration_edge_cases():
    assert quantize_duration("0").ticks == 0
    # 5ns is exactly half a tick -> round-half-to-even gives 0 ticks here. A real PULSE
    # width this small is caught separately by validate.py ("quantizes to 0 ticks").
    assert quantize_duration("5ns").ticks == 0
    assert quantize_duration("10ns").ticks == 1
    assert quantize_duration("1us").ticks == 100


def test_ns_to_ticks_rounding():
    assert ns_to_ticks(10) == 1
    assert ns_to_ticks(15) == 2  # round-half-to-even is fine, just must be deterministic
    assert ns_to_ticks(0) == 0
