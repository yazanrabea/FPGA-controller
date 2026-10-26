"""Chip pipeline step C5 (2026-10-26): an editor mode -> a chip_top sequence (mode_seq.py)
and `cli run-mode`. Configs are the real config/nemo_config.yaml with small text edits."""
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from nemo_ctl import cli
from nemo_ctl.config import load_config
from nemo_ctl.groups import group_bits
from nemo_ctl.dft_helper import resolve as resolve_dft
from nemo_ctl.mode_seq import ModeError, mode_steps, mode_table
from nemo_ctl.sequence import chip_target

TOOLS = Path(__file__).resolve().parents[2]
CONFIG = TOOLS.parent / "config" / "nemo_config.yaml"
TEXT = CONFIG.read_text()
FRAME = "0x5AA55A0FF0123456789ABCDEF0C3C3E7E7"
FILLED = TEXT.replace('data: "0x" ,', f'data: "{FRAME}",')
CHIP = chip_target()


def _cfg(tmp_path, text=FILLED):
    p = tmp_path / "c.yaml"
    p.write_text(text)
    return p


def test_the_example_config_needs_sipo_data(tmp_path):
    assert FILLED != TEXT
    with pytest.raises(ModeError, match="sipo_in: SERIAL data '0x' isn't a number"):
        mode_steps(load_config(CONFIG), "INFERENCE")


def test_inference_becomes_idle_then_the_mode(tmp_path):
    steps, notes = mode_steps(load_config(_cfg(tmp_path)), "INFERENCE")
    idle, run = steps
    assert [s["name"] for s in steps] == ["idle", "INFERENCE"]
    # step 0 sets every cell (compile_steps needs that) at its idle level
    assert set(idle["set"]) == {c.name for c in CHIP.sig_cells}
    assert set(idle["capture"]) == {c.name for c in CHIP.cap_cells}
    assert idle["set"]["rst_sipo"] == {"type": "HIGH"} and idle["set"]["rst_piso"] == {"type": "HIGH"}
    assert idle["set"]["clk"] == {"type": "LOW"}
    assert any("idle level TBD" in n for n in notes)
    # step 1 copies the editor settings as they are
    assert run["set"]["clk"] == {"type": "CLOCK", "freq": "1MHz", "duty": "50%"}
    assert run["set"]["clk_sipo"]["cycles"] == 136
    assert run["set"]["sipo_in"]["data"] == FRAME and run["set"]["sipo_in"]["bits"] == 136
    assert run["capture"]["piso_out"] == {"mode": "SERIAL", "bits": 168, "msb_first": True}
    assert run["capture"]["sipo_out"] == {"mode": "LEVEL"}
    # duration: last event (clk_piso: 150 us + 168 us) + 10 %, whole microseconds
    assert run["until"] == {"after": "350us"} and idle["until"] == {"after": "10us"}


def test_dft_helper_becomes_the_b_and_s_pins(tmp_path):
    steps, _ = mode_steps(load_config(_cfg(tmp_path)), "INFERENCE")
    sel = resolve_dft(3, "phi1")
    want = {**group_bits("b_dft", sel.b_value), **group_bits("s_dft", sel.s_value)}
    assert len(want) == 7
    for pin, bit in want.items():
        assert steps[1]["set"][pin] == {"type": "HIGH" if bit else "LOW"}


def test_raw_bus_instead_of_the_helper(tmp_path):
    text = FILLED.replace("      dft_select: {adc: 3, signal: phi1}", "      b_dft: {type: BUS, value: 0b101}")
    steps, _ = mode_steps(load_config(_cfg(tmp_path, text)), "INFERENCE")
    got = {p: steps[1]["set"][p]["type"] for p in ("b0_dft", "b1_dft", "b2_dft")}
    assert got == {p: ("HIGH" if b else "LOW") for p, b in group_bits("b_dft", 0b101).items()}
    assert "s0_dft" not in steps[1]["set"]          # not configured -> keeps its idle level


def test_compiles_for_chip_top(tmp_path):
    table, _ = mode_table(load_config(_cfg(tmp_path)), "INFERENCE")
    assert len(table.steps) == 2
    assert table.steps[0].cond_arg == 1000 and table.steps[1].cond_arg == 35000   # 10 us, 350 us
    assert not table.warnings


def test_explicit_duration(tmp_path):
    steps, notes = mode_steps(load_config(_cfg(tmp_path)), "INFERENCE", duration_s=2e-3)
    assert steps[1]["until"] == {"after": "2000us"}
    assert not any(n.startswith("duration") for n in notes)
    with pytest.raises(ModeError, match="out of range"):
        mode_steps(load_config(_cfg(tmp_path)), "INFERENCE", duration_s=60.0)


def test_free_running_mode_needs_a_duration(tmp_path):
    text = FILLED.replace("  READ: {}", "  READ:\n    Clock Generator:\n      clk: {type: CLOCK, freq: 1MHz}")
    cfg = load_config(_cfg(tmp_path, text))
    with pytest.raises(ModeError, match="no finite end"):
        mode_steps(cfg, "READ")
    steps, _ = mode_steps(cfg, "READ", duration_s=1e-3)
    assert steps[1]["set"] == {"clk": {"type": "CLOCK", "freq": "1MHz"}}


def test_empty_and_unknown_modes(tmp_path):
    cfg = load_config(_cfg(tmp_path))
    with pytest.raises(ModeError, match="configures nothing"):
        mode_steps(cfg, "WRITE")
    with pytest.raises(ModeError, match="no mode 'NOPE'"):
        mode_steps(cfg, "NOPE")


def test_capture_edge_the_bitstream_is_not_wired_for(tmp_path):
    text = FILLED.replace("bits: 168, edge: falling}", "bits: 168, edge: rising}")
    with pytest.raises(ModeError, match="captures piso_out on clk_piso's falling edge"):
        mode_steps(load_config(_cfg(tmp_path, text)), "INFERENCE")


def test_unknown_capture_mode(tmp_path):
    text = FILLED.replace("sipo_out: {type: CAPTURE, mode: level}", "sipo_out: {type: CAPTURE, mode: eye}")
    with pytest.raises(ModeError, match="unknown capture mode 'eye'"):
        mode_steps(load_config(_cfg(tmp_path, text)), "INFERENCE")


def test_capture_mode_names(tmp_path):
    text = FILLED.replace("sipo_out: {type: CAPTURE, mode: level}", "sipo_out: {type: CAPTURE, mode: edge_count}")
    steps, _ = mode_steps(load_config(_cfg(tmp_path, text)), "INFERENCE")
    assert steps[1]["capture"]["sipo_out"] == {"mode": "EDGE_COUNT"}


def test_pin_set_twice(tmp_path):
    # the helper drives b0_dft, so a raw BUS on the same pins in the same mode is an error
    text = FILLED.replace("      # b_dft: {type: BUS, value: 0b011}", "      b_dft: {type: BUS, value: 0b011}")
    with pytest.raises(ModeError, match="already set"):
        mode_steps(load_config(_cfg(tmp_path, text)), "INFERENCE")


# ---- cli run-mode ----

def _run(args):
    return subprocess.run([sys.executable, "-m", "nemo_ctl.cli", *args], cwd=TOOLS,
                          capture_output=True, text=True, timeout=30)


def test_cli_dry_run(tmp_path):
    r = _run(["run-mode", "--mode", "INFERENCE", "--config", str(_cfg(tmp_path)), "--dry-run"])
    assert r.returncode == 0, r.stderr
    assert "mode INFERENCE -> sequence for chip_top:" in r.stdout
    assert "1 INFERENCE:" in r.stdout and "ends after 35000 ticks" in r.stdout
    assert "note: duration 350 us" in r.stdout


def test_cli_error_and_no_link(tmp_path):
    r = _run(["run-mode", "--mode", "INFERENCE", "--config", str(CONFIG), "--dry-run"])
    assert r.returncode == 1 and "isn't a number yet" in r.stderr
    r = _run(["run-mode", "--mode", "INFERENCE", "--config", str(_cfg(tmp_path))])
    assert r.returncode == 1 and "give --jtag" in r.stderr


class _FakeLink:
    """Stands in for SeqLink on chip_top: records what run-mode does."""
    def __init__(self):
        self.target, self.calls = CHIP, []

    def load(self, table):
        self.calls.append(("load", len(table.steps)))

    def start(self):
        self.calls.append("start")

    def wait(self, timeout_s):
        self.calls.append(("wait", round(timeout_s, 5)))
        return SimpleNamespace(done=True, fault=False, step=1)

    def read_cap_counts(self, name):
        return {"level": 1, "edges": 3}

    def read_cap_timing(self, name):
        return {"period": 100, "high": 50}

    def read_capture(self, name):
        return 0xA5

    def close(self):
        self.calls.append("close")


def test_cli_run_on_a_fake_board(tmp_path, monkeypatch, capsys):
    fake = _FakeLink()
    monkeypatch.setattr(cli, "_open_chip_link", lambda args: fake)
    rc = cli.main(["run-mode", "--mode", "INFERENCE", "--config", str(_cfg(tmp_path)), "--jtag"])
    out = capsys.readouterr().out
    assert rc == 0
    assert fake.calls == [("load", 2), "start", ("wait", 2.00036), "close"]   # 10 us + 350 us + 2 s margin
    assert "STATUS: done; last step 1" in out
    assert "piso_out: level 1, edges 3, period 100 ticks, high 50 ticks, capture 0x" + "0" * 40 + "A5" in out
    assert "sipo_out: level 1, edges 3, period 100 ticks, high 50 ticks\n" in out


# ---- the editor's Run on board button (gui.py /api/run) ----

def _page_doc(tmp_path, **extra):
    from nemo_ctl.config import config_to_dict
    return {**config_to_dict(load_config(_cfg(tmp_path))), "mode": "INFERENCE", **extra}


def test_gui_check_only_converts(tmp_path):
    from nemo_ctl import gui
    opened = []
    r = gui.run_payload(_page_doc(tmp_path, dry=True), open_link=lambda: opened.append(1))
    assert r["ok"] and not opened and "done" not in r
    assert any("ends after 35000 ticks" in l for l in r["summary"])


def test_gui_run_on_a_fake_board(tmp_path):
    from nemo_ctl import gui
    fake = _FakeLink()
    r = gui.run_payload(_page_doc(tmp_path, duration="1ms"), open_link=lambda: fake)
    assert r["ok"] and r["done"] and not r["fault"]
    assert fake.calls == [("load", 2), "start", ("wait", 2.00101), "close"]
    assert {c["name"] for c in r["captures"]} == {c.name for c in CHIP.cap_cells}
    assert [c for c in r["captures"] if c["name"] == "piso_out"][0]["capture"].endswith("A5")


def test_gui_run_errors_are_reported_not_raised(tmp_path):
    from nemo_ctl import gui
    r = gui.run_payload({**_page_doc(tmp_path), "mode": "WRITE"}, open_link=_FakeLink)
    assert not r["ok"] and "configures nothing" in r["error"]

    def no_cable():
        raise RuntimeError("no JTAG cable")
    r = gui.run_payload(_page_doc(tmp_path), open_link=no_cable)
    assert not r["ok"] and "board run failed: no JTAG cable" in r["error"] and r["summary"]


def test_gui_server_has_the_endpoint(tmp_path):
    import http.client, threading
    from nemo_ctl import gui
    srv = gui.make_server(_cfg(tmp_path), port=0, open_link=_FakeLink)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=10)
        c.request("POST", "/api/run", json.dumps(_page_doc(tmp_path)), {"Content-Type": "application/json"})
        r = json.loads(c.getresponse().read())
        assert r["ok"] and r["done"]
        c.request("GET", "/")
        page = c.getresponse().read().decode("utf-8")
        assert 'id="rrun"' in page and "/api/run" in page
    finally:
        srv.shutdown(); srv.server_close()
