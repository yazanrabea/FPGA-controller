"""Exercises the actual `python3 -m nemo_ctl.cli` entry point (not just the headless
wizard engine), since that's what a human runs. Subprocess, not import, so it's a real
check of argument parsing + stdin/stdout wiring."""
import subprocess
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
REPO_CONFIG = TOOLS_DIR.parent / "config" / "nemo_config.yaml"


def _run(args, input_text=None):
    return subprocess.run(
        [sys.executable, "-m", "nemo_ctl.cli", *args],
        cwd=TOOLS_DIR,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=15,
    )


def test_validate_subcommand_runs_clean():
    result = _run(["validate", "--config", str(REPO_CONFIG)])
    assert result.returncode == 0, result.stderr
    assert "ERROR" not in result.stdout


def test_preview_table_subcommand():
    result = _run(["preview", "--mode", "INFERENCE", "--format", "table", "--config", str(REPO_CONFIG)])
    assert result.returncode == 0, result.stderr
    assert "clk_sipo" in result.stdout


def test_preview_wavedrom_subcommand():
    result = _run(["preview", "--mode", "INFERENCE", "--format", "wavedrom", "--config", str(REPO_CONFIG)])
    assert result.returncode == 0, result.stderr
    assert '"signal"' in result.stdout


def test_gen_template_subcommand(tmp_path):
    out = tmp_path / "template.xlsx"
    result = _run(["gen-template", "--out", str(out), "--modes", "INFERENCE"])
    assert result.returncode == 0, result.stderr
    assert out.exists()


def test_export_then_import_excel_round_trip(tmp_path):
    xlsx = tmp_path / "export.xlsx"
    r1 = _run(["export-excel", "--config", str(REPO_CONFIG), "--out", str(xlsx)])
    assert r1.returncode == 0, r1.stderr
    assert xlsx.exists()

    round_tripped = tmp_path / "roundtrip.yaml"
    r2 = _run(["import-excel", "--excel", str(xlsx), "--config", str(round_tripped)])
    assert r2.returncode == 0, r2.stderr
    assert round_tripped.exists()


def test_link_subcommand_help_lists_every_action():
    result = _run(["link", "--help"])
    assert result.returncode == 0, result.stderr
    for action in ("status", "run", "stop", "apply", "set-clock", "read-captures"):
        assert action in result.stdout


def test_link_status_requires_port():
    result = _run(["link", "status"])
    assert result.returncode != 0
    assert "--port" in result.stderr


def test_link_status_fails_cleanly_without_a_real_port():
    # No real hardware/serial port in this environment (and pyserial isn't installed
    # either) -- just confirms this is a clean nonzero exit, not a hang, when the port
    # can't be opened.
    result = _run(["link", "status", "--port", "/dev/__definitely_not_a_real_port__"])
    assert result.returncode != 0


def test_wizard_subcommand_over_piped_stdin(tmp_path):
    cfg_path = tmp_path / "wizard_config.yaml"
    cfg_path.write_text(REPO_CONFIG.read_text())

    answers = (
        ["", "n", "keep", "keep", "keep"]  # Clock Generator: skip all 3
        + ["", "n", "keep"]                 # DSA
        + ["", "n", "keep", "keep"]         # Array with Muxes
        + ["", "n", "keep"]                 # DFT - All
        + ["", "n", "keep"]                 # dft per ADC
        + ["", "n", "keep", "keep", "keep", "keep"]  # SIPO
        + ["", "n", "keep", "keep", "keep"]  # PISO
    )
    result = _run(
        ["wizard", "--mode", "INFERENCE", "--config", str(cfg_path)],
        input_text="\n".join(answers) + "\n",
    )
    assert result.returncode == 0, result.stderr
    assert "Done building mode 'INFERENCE'" in result.stdout
    assert f"Saved {cfg_path}" in result.stdout
    assert cfg_path.exists()


def test_link_and_seq_offer_jtag():
    # JTAG link step J4: --jtag is the alternative to --port (docs/link_register_map.md)
    for argv in (["link", "status", "--help"], ["seq", "status", "--help"]):
        result = _run(argv)
        assert result.returncode == 0 and "--jtag" in result.stdout and "J17" in result.stdout


def test_port_and_jtag_are_exclusive():
    result = _run(["link", "status", "--port", "COM3", "--jtag"])
    assert result.returncode != 0
    assert "not allowed with" in result.stderr


def test_fmt_hz_keeps_low_frequencies_readable():
    from nemo_ctl.cli import _fmt_hz
    assert _fmt_hz(1.0) == "1.0000 Hz"            # was "0.0000 MHz" (EXP-02, 2026-10-22)
    assert _fmt_hz(100.0) == "100.0000 Hz"
    assert _fmt_hz(250e3) == "250.0000 kHz"
    assert _fmt_hz(3.0303e6) == "3.0303 MHz"
