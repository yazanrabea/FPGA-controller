from pathlib import Path

from nemo_ctl.config import load_config
from nemo_ctl.timing import format_timing_table, summarize_mode

EXAMPLE_CONFIG = Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml"


def test_summarize_inference_mode_covers_every_setting():
    cfg = load_config(EXAMPLE_CONFIG)
    expected = sum(1 for _ in cfg.iter_settings("INFERENCE"))
    rows = summarize_mode(cfg, "INFERENCE")
    assert len(rows) == expected


def test_clk_sipo_start_delay_and_cycles():
    cfg = load_config(EXAMPLE_CONFIG)
    rows = {r.key: r for r in summarize_mode(cfg, "INFERENCE")}
    clk_sipo = rows["clk_sipo"]
    assert clk_sipo.start_tick == 200  # 2us / 10ns
    assert clk_sipo.duration_tick == 100 * 136  # period_ticks * cycles
    assert "1.0000 MHz" in clk_sipo.summary


def test_cs_pulse_delay_matches_140us():
    cfg = load_config(EXAMPLE_CONFIG)
    rows = {r.key: r for r in summarize_mode(cfg, "INFERENCE")}
    assert rows["cs"].start_tick == 14000  # 140us / 10ns


def test_free_running_clock_has_no_duration():
    cfg = load_config(EXAMPLE_CONFIG)
    rows = {r.key: r for r in summarize_mode(cfg, "INFERENCE")}
    assert rows["clk"].duration_tick is None  # no `cycles` given -> free-running


def test_format_timing_table_is_a_markdown_table():
    cfg = load_config(EXAMPLE_CONFIG)
    rows = summarize_mode(cfg, "INFERENCE")
    table = format_timing_table(rows)
    assert table.startswith("| Block |")
    assert "clk_sipo" in table
