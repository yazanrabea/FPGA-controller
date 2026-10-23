"""Browser config editor (gui.py): the API functions, the local server, the page's script."""
from __future__ import annotations

import http.client
import json
import re
import shutil
import subprocess
import threading
from pathlib import Path

import pytest

from nemo_ctl import gui
from nemo_ctl.config import config_to_dict, load_config
from nemo_ctl.pins import load_pin_db
from nemo_ctl.validate import validate_config

EXAMPLE = Path(__file__).resolve().parents[3] / "config" / "nemo_config.yaml"
PIN_DB = load_pin_db()


@pytest.fixture
def cfg(tmp_path):
    p = tmp_path / "nemo_config.yaml"
    shutil.copy(EXAMPLE, p)
    return p


def _doc(path):
    return config_to_dict(load_config(path))


# ---------------------------------------------------------------- API functions

def test_state_has_every_pin_the_groups_and_the_modes(cfg):
    st = gui.state_payload(cfg, PIN_DB)
    assert len(st["pins"]) == 26 and {"s_p", "b_dft", "s_dft"} <= set(st["groups"])
    assert "INFERENCE" in st["modes"] and st["modes"]["INFERENCE"]["Clock Generator"]["clk"]["type"] == "CLOCK"
    clk = next(p for p in st["pins"] if p["name"] == "clk")
    assert clk["allowed"] == ["CLOCK"] and clk["direction"] == "in"
    assert "phi1" in st["dft_signals"]


def test_check_matches_validate_and_shows_achieved_values(cfg):
    r = gui.check_payload(_doc(cfg), PIN_DB)
    assert r["parse_error"] is None
    assert len(r["issues"]) == len(validate_config(load_config(cfg), PIN_DB))
    assert "1.0000 MHz" in r["summaries"]["INFERENCE"]["Clock Generator"]["clk"]["text"]


def test_check_reports_a_bad_value_on_its_pin(cfg):
    d = _doc(cfg)
    d["modes"]["INFERENCE"]["Clock Generator"]["clk"]["freq"] = "fast"
    r = gui.check_payload(d, PIN_DB)
    assert r["errors"] >= 1
    assert any(i["key"] == "clk" and i["level"] == "error" for i in r["issues"])
    assert r["summaries"]["INFERENCE"]["Clock Generator"]["clk"]["ok"] is False


def test_check_reports_an_unparseable_config(cfg):
    d = _doc(cfg)
    d["modes"]["INFERENCE"]["Clock Generator"]["clk"] = {"freq": "1MHz"}  # no type
    r = gui.check_payload(d, PIN_DB)
    assert r["parse_error"] and "type" in r["parse_error"]


def test_save_refuses_errors_and_leaves_the_file_alone(cfg):
    before = cfg.read_bytes()
    d = _doc(cfg)
    d["modes"]["INFERENCE"]["Clock Generator"]["clk"]["freq"] = "60MHz"  # over the 50 MHz hard limit
    r = gui.save_payload(d, cfg, PIN_DB)
    assert not r["saved"] and cfg.read_bytes() == before
    assert not cfg.with_suffix(".yaml.bak").exists()


def test_save_writes_the_change_and_keeps_a_backup(cfg):
    before = cfg.read_bytes()
    d = _doc(cfg)
    d["modes"]["INFERENCE"]["Clock Generator"]["clk"]["freq"] = "2MHz"
    r = gui.save_payload(d, cfg, PIN_DB)
    assert r["saved"], r
    assert cfg.with_suffix(".yaml.bak").read_bytes() == before
    assert load_config(cfg).modes["INFERENCE"]["Clock Generator"]["clk"].params["freq"] == "2MHz"


def test_unchanged_round_trip_keeps_the_config(cfg):
    original = _doc(cfg)
    assert gui.save_payload(gui.state_payload(cfg, PIN_DB) | {"modes": original["modes"]}, cfg, PIN_DB)["saved"]
    assert _doc(cfg) == original


# ---------------------------------------------------------------- local server

@pytest.fixture
def server(cfg):
    srv = gui.make_server(cfg, port=0, pin_db=PIN_DB)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv.server_address[1], cfg
    srv.shutdown()
    srv.server_close()


def _req(port, method, path, body=None, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, data


def test_server_serves_the_page_and_the_api(server):
    port, cfg = server
    code, page = _req(port, "GET", "/")
    assert code == 200 and b"NEMO Config Editor" in page
    code, st = _req(port, "GET", "/api/state")
    assert code == 200 and json.loads(st)["path"] == str(cfg.resolve())
    body = json.dumps({"modes": _doc(cfg)["modes"]})
    code, r = _req(port, "POST", "/api/check", body, {"Content-Type": "application/json"})
    assert code == 200 and json.loads(r)["parse_error"] is None


def test_server_refuses_other_hosts_and_non_json_posts(server):
    port, _ = server
    assert _req(port, "GET", "/api/state", headers={"Host": "evil.example"})[0] == 403
    assert _req(port, "POST", "/api/save", "{}", {"Content-Type": "text/plain"})[0] == 415
    assert _req(port, "GET", "/nope")[0] == 404


# ---------------------------------------------------------------- the page

def test_page_script_parses():
    node = shutil.which("node")
    if not node:
        pytest.skip("node not installed")
    page = gui.PAGE_PATH.read_text(encoding="utf-8")
    script = re.search(r"<script>(.*)</script>", page, re.S).group(1)
    r = subprocess.run([node, "--check", "-"], input=script, capture_output=True, text=True, encoding="utf-8")
    assert r.returncode == 0, r.stderr


def test_cli_has_the_gui_command():
    from nemo_ctl.cli import build_parser
    a = build_parser().parse_args(["gui", "--no-browser", "--port", "0"])
    assert a.no_browser and a.port == 0
