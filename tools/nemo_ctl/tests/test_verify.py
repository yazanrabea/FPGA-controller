"""Verification plan Step 1 (2026-11-01): `expect` on CAPTURE settings, verify.py, `cli verify`
and the editor's /api/verify. The board is a fake SeqLink returning chosen captures."""
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from nemo_ctl import cli, gui
from nemo_ctl.config import config_from_dict, config_to_dict, load_config
from nemo_ctl.mode_seq import mode_table
from nemo_ctl.pins import load_pin_db
from nemo_ctl.sequence import chip_target
from nemo_ctl.sipo_piso import PisoStage, encode_piso_frame
from nemo_ctl.validate import validate_config
from nemo_ctl.verify import (VerifyError, check_capture, format_csv, format_markdown, format_text,
                             mode_expectations, parse_expect, verify_table)

TOOLS = Path(__file__).resolve().parents[2]
TEXT = (TOOLS.parent / "config" / "nemo_config.yaml").read_text()
FRAME = "0x5AA55A0FF0123456789ABCDEF0C3C3E7E7"
STAGES = (PisoStage(0x1234, 0x11, 0x0ABC, 0x22), PisoStage(0x0001, 0x7F, 0x3FFF, 0x00),
          PisoStage(0x2AAA, 0x55, 0x1555, 0x2A), PisoStage(0x0F0F, 0x0F, 0x30F0, 0x70))
PISO = encode_piso_frame(STAGES)
CHIP = chip_target()

SIPO_OUT = "sipo_out: {type: CAPTURE, mode: level}"
PISO_OUT = "piso_out: {type: CAPTURE, mode: serial, clock: clk_piso, bits: 168, edge: falling}"


def _text(sipo_out=SIPO_OUT, piso_out=PISO_OUT):
    t = TEXT                                   # the config carries FRAME (2026-11-02)
    assert f'data: "{FRAME}"' in t and SIPO_OUT in t and PISO_OUT in t
    return t.replace(SIPO_OUT, sipo_out).replace(PISO_OUT, piso_out)


def _expecting(piso=f'"0x{PISO:042X}"', level=0):
    return _text(f"sipo_out: {{type: CAPTURE, mode: level, expect: {level}}}",
                 PISO_OUT[:-1] + f", expect: {piso}}}")


def _cfg(tmp_path, text):
    p = tmp_path / "c.yaml"
    p.write_text(text)
    return p


class _Board:
    """A fake SeqLink to chip_top: every cap cell reads `caps[name]` (defaults below)."""
    def __init__(self, piso=PISO, level=0, done=True, fault=False):
        self.target, self.calls = CHIP, []
        self.caps = {c.name: {"level": 0, "edges": 0, "period": 0, "high": 0, "capture": 0}
                     for c in CHIP.cap_cells}
        self.caps["piso_out"]["capture"] = piso
        self.caps["sipo_out"]["level"] = level
        self.done, self.fault = done, fault

    def load(self, table): self.calls.append("load")
    def start(self): self.calls.append("start")
    def wait(self, t): return SimpleNamespace(done=self.done, fault=self.fault, step=1)
    def read_cap_counts(self, n): return {"level": self.caps[n]["level"], "edges": self.caps[n]["edges"]}
    def read_cap_timing(self, n): return {"period": self.caps[n]["period"], "high": self.caps[n]["high"]}
    def read_capture(self, n):
        v = self.caps[n]["capture"]
        return v() if callable(v) else v
    def close(self): self.calls.append("close")


# ---- parsing ----

@pytest.mark.parametrize("params, kind, value, tol", [
    ({"mode": "level", "expect": 1}, "level", 1, 0),
    ({"mode": "level", "expect": "HIGH"}, "level", 1, 0),
    ({"mode": "period", "expect": "1us"}, "period", 100, 1),
    ({"mode": "period", "expect": "1MHz", "tolerance": "1%"}, "period", 100, 1),
    ({"mode": "period", "expect": "2us", "tolerance": "50ns"}, "period", 200, 5),
    ({"mode": "frequency", "expect": "500kHz", "tolerance": 3}, "period", 200, 3),
])
def test_parse_each_kind(params, kind, value, tol):
    e = parse_expect("p", "B", params)
    assert (e.kind, e.value, e.tol) == (kind, pytest.approx(value), pytest.approx(tol))


def test_serial_default_mask_is_every_bit():
    e = parse_expect("p", "B", {"mode": "serial", "bits": 8, "expect": "0xA5"})
    assert (e.value, e.mask, e.expected_text()) == (0xA5, 0xFF, "0xA5")
    e = parse_expect("p", "B", {"mode": "serial", "bits": 8, "expect": "0xA5", "mask": "0x0F"})
    assert e.expected_text() == "0xA5 mask 0x0F"


def test_no_expect_is_none_but_a_stray_tolerance_is_an_error():
    assert parse_expect("p", "B", {"mode": "level"}) is None
    with pytest.raises(VerifyError, match="tolerance without expect"):
        parse_expect("p", "B", {"mode": "level", "tolerance": 1})


@pytest.mark.parametrize("params, msg", [
    ({"mode": "level", "expect": 2}, "0 / 1"),
    ({"mode": "level", "expect": 1, "tolerance": 1}, "no tolerance"),
    ({"mode": "edge_count", "expect": 136}, "can't be checked"),
    ({"mode": "edges", "expect": "136", "tolerance": 2}, "can't be checked"),
    ({"mode": "period", "expect": "fast"}, "not a time or a frequency"),
    ({"mode": "period", "expect": "1us", "tolerance": "lots"}, "percentage"),
    ({"mode": "serial", "expect": "0xA5"}, "bits"),
    ({"mode": "serial", "bits": 4, "expect": "0xA5"}, "doesn't fit in 4 bits"),
    ({"mode": "serial", "bits": 8, "expect": "0xA5", "mask": "0x1FF"}, "mask"),
    ({"mode": "serial", "bits": 8, "expect": "0xA5", "tolerance": 1}, "use mask"),
    ({"mode": "wobble", "expect": 1}, "unknown capture mode"),
])
def test_parse_errors(params, msg):
    with pytest.raises(VerifyError, match=msg):
        parse_expect("p", "B", params)


def test_validator_reports_expect_errors_on_the_pin():
    db = load_pin_db()
    ok = config_from_dict(__import__("yaml").safe_load(_expecting()))
    assert not [i for i in validate_config(ok, db) if "expect" in i.message]
    bad = config_from_dict(__import__("yaml").safe_load(_expecting(piso='"0xZZ"')))
    issues = [i for i in validate_config(bad, db) if i.level == "error" and i.key == "piso_out"]
    assert len(issues) == 1 and "expect: expect '0xZZ' is not a number" in issues[0].message
    on_input = TEXT.replace("set:   {type: LOW}", "set:   {type: LOW, expect: 1}")
    cfg = config_from_dict(__import__("yaml").safe_load(on_input))
    assert any(i.key == "set" and "only go on a CAPTURE pin" in i.message for i in validate_config(cfg, db))


def test_expect_survives_save_and_the_excel_round_trip(tmp_path):
    from nemo_ctl.config import save_config
    from nemo_ctl.excel_io import export_config, import_config
    cfg = config_from_dict(__import__("yaml").safe_load(_expecting()))
    save_config(cfg, tmp_path / "s.yaml")
    assert mode_expectations(load_config(tmp_path / "s.yaml"), "INFERENCE")["piso_out"].value == PISO
    export_config(cfg, tmp_path / "x.xlsx")
    assert mode_expectations(import_config(tmp_path / "x.xlsx"), "INFERENCE")["piso_out"].value == PISO


def test_expect_does_not_change_the_compiled_table():
    plain = mode_table(config_from_dict(__import__("yaml").safe_load(_text())), "INFERENCE")[0]
    withx = mode_table(config_from_dict(__import__("yaml").safe_load(_expecting())), "INFERENCE")[0]
    assert plain.summary() == withx.summary()


# ---- comparing ----

def test_each_kind_passes_and_fails():
    lv = parse_expect("p", "B", {"mode": "level", "expect": 1})
    assert check_capture(lv, {"level": 1}, 1).ok and not check_capture(lv, {"level": 0}, 1).ok
    pe = parse_expect("p", "B", {"mode": "period", "expect": "1us"})
    assert [check_capture(pe, {"period": n}, 1).ok for n in (98, 99, 100, 101, 102)] == [
        False, True, True, True, False]
    r = check_capture(pe, {"period": 0}, 1)
    assert not r.ok and "fewer than 2 rising edges" in r.note


def test_serial_mask_and_partial_lsb_first_capture():
    e = parse_expect("p", "B", {"mode": "serial", "bits": 8, "expect": "0xA5", "mask": "0xF0"})
    assert check_capture(e, {"capture": "0xAF"}, 8).ok
    r = check_capture(e, {"capture": "0x25"}, 8)
    assert not r.ok and r.note == "1 bit wrong (bit 7)"
    # cap_cell.sv: an lsb_first capture shorter than CAP_W sits in the top bits
    e = parse_expect("p", "B", {"mode": "serial", "bits": 8, "expect": "0xA5", "msb_first": False})
    assert check_capture(e, {"capture": "0xA500"}, 16).ok


def test_piso_mismatch_names_the_stage_and_field():
    e = parse_expect("piso_out", "PISO", {"mode": "serial", "bits": 168, "expect": f"0x{PISO:042X}"})
    bad = list(STAGES)
    bad[2] = PisoStage(STAGES[2].out1, STAGES[2].tdc_out1, STAGES[2].out0 ^ 0b101000, STAGES[2].tdc_out0)
    r = check_capture(e, {"capture": encode_piso_frame(bad)}, 168)
    assert not r.ok and r.note == "2 bits wrong: PISO2 out0 bits 3,5"


# ---- running ----

def test_verify_passes_and_shows_unjudged_captures():
    cfg = config_from_dict(__import__("yaml").safe_load(_expecting()))
    table, _ = mode_table(cfg, "INFERENCE")
    board = _Board()
    res = verify_table(board, table, mode_expectations(cfg, "INFERENCE"), mode="INFERENCE")
    assert res.ok and board.calls == ["load", "start"]
    t = {r.pin: r for r in res.table()}
    assert t["(run)"].ok and t["piso_out"].ok and t["sipo_out"].ok
    assert t["dft0_buff"].ok is None and t["dft0_buff"].note == "no expect set"
    assert res.counts() == (3, 0, 2)
    assert format_text(res)[-1] == "PASS: 3 pass, 0 fail, 2 not judged, 1 run"


def test_a_fault_fails_even_if_every_capture_matches():
    cfg = config_from_dict(__import__("yaml").safe_load(_expecting()))
    table, _ = mode_table(cfg, "INFERENCE")
    res = verify_table(_Board(fault=True), table, mode_expectations(cfg, "INFERENCE"))
    assert not res.ok and res.table()[0].measured.startswith("done, FAULT")


def test_repeat_counts_passes_and_keeps_the_first_failure():
    cfg = config_from_dict(__import__("yaml").safe_load(_expecting()))
    table, _ = mode_table(cfg, "INFERENCE")
    frames = iter([PISO, PISO ^ 1, PISO, PISO ^ (1 << 167)])
    board = _Board(piso=lambda: next(frames))
    res = verify_table(board, table, mode_expectations(cfg, "INFERENCE"), repeat=4)
    piso = {r.pin: r for r in res.table()}["piso_out"]
    assert not res.ok and not piso.ok
    assert piso.note == "2/4 pass; first fail: 1 bit wrong: PISO3 tdc_out0 bit 0"
    assert piso.measured == f"0x{PISO ^ 1:042X}"
    assert format_csv(res).count("\n") == 1 + 4 * len(res.runs[0])
    md = format_markdown(res, {"date": "x"})
    assert "result: **FAIL**" in md and "| piso_out | serial |" in md


# ---- cli ----

def test_cli_dry_run_lists_the_expectations(tmp_path, capsys):
    rc = cli.main(["verify", "--mode", "INFERENCE", "--config", str(_cfg(tmp_path, _expecting())), "--dry-run"])
    out = capsys.readouterr().out
    assert rc == 0 and "2 expectation(s)" in out and "sipo_out: level 0" in out


def test_cli_without_expect_warns(tmp_path, capsys):
    rc = cli.main(["verify", "--mode", "INFERENCE", "--config", str(_cfg(tmp_path, _text())), "--dry-run"])
    assert rc == 0 and "nothing is judged" in capsys.readouterr().err


def test_cli_bad_expect_is_an_error(tmp_path, capsys):
    rc = cli.main(["verify", "--mode", "INFERENCE", "--dry-run",
                   "--config", str(_cfg(tmp_path, _expecting(level="maybe")))])
    assert rc == 1 and "INFERENCE/SIPO/sipo_out" in capsys.readouterr().err


@pytest.mark.parametrize("ext", ["md", "csv"])
def test_cli_on_a_fake_board_pass_and_fail(tmp_path, monkeypatch, capsys, ext):
    cfg = str(_cfg(tmp_path, _expecting()))
    monkeypatch.setattr(cli, "_open_chip_link", lambda args: _Board())
    out = tmp_path / f"r.{ext}"
    assert cli.main(["verify", "--mode", "INFERENCE", "--config", cfg, "--jtag", "--out", str(out)]) == 0
    assert "PASS: 3 pass" in capsys.readouterr().out and out.read_text()
    monkeypatch.setattr(cli, "_open_chip_link", lambda args: _Board(level=1))
    assert cli.main(["verify", "--mode", "INFERENCE", "--config", cfg, "--jtag", "--repeat", "2"]) == 1
    text = capsys.readouterr().out
    assert "FAIL: 2 pass, 1 fail" in text and "0/2 pass" in text


# ---- editor ----

def _doc(**extra):
    return {**config_to_dict(config_from_dict(__import__("yaml").safe_load(_expecting()))),
            "mode": "INFERENCE", **extra}


def test_gui_verify_dry_and_run():
    r = gui.verify_payload(_doc(dry=True), open_link=lambda: pytest.fail("no board on a dry run"))
    assert r["ok"] and {e["pin"] for e in r["expect"]} == {"piso_out", "sipo_out"} and "rows" not in r
    board = _Board(level=1)
    r = gui.verify_payload(_doc(repeat=3), open_link=lambda: board)
    assert r["ok"] and not r["passed"] and r["runs"] == 3 and board.calls[-1] == "close"
    row = [x for x in r["rows"] if x["pin"] == "sipo_out"][0]
    assert row["ok"] is False and row["note"] == "0/3 pass"
    assert r["counts"] == {"pass": 2, "fail": 1, "not_judged": 2} and "| sipo_out |" in r["markdown"]


def test_gui_verify_errors_are_reported():
    assert "repeat" in gui.verify_payload(_doc(repeat=0), open_link=_Board)["error"]
    doc = _doc()
    doc["modes"]["INFERENCE"]["SIPO"]["sipo_out"]["expect"] = 7
    assert "0 / 1" in gui.verify_payload(doc, open_link=_Board)["error"]

    def no_cable():
        raise RuntimeError("no JTAG cable")
    r = gui.verify_payload(_doc(), open_link=no_cable)
    assert not r["ok"] and "no JTAG cable" in r["error"] and r["expect"]


def test_gui_server_has_the_verify_endpoint(tmp_path):
    import http.client, threading
    srv = gui.make_server(_cfg(tmp_path, _expecting()), port=0, open_link=_Board)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=10)
        c.request("POST", "/api/verify", json.dumps(_doc()), {"Content-Type": "application/json"})
        r = json.loads(c.getresponse().read())
        assert r["ok"] and r["passed"]
    finally:
        srv.shutdown()
        srv.server_close()


# ---- step sequences (cli verify --seq), EXP-09 ----

SEQ = TOOLS.parent / "config" / "exp09_verify_vchip.yaml"
EXP08 = 0x5AA55A0FF0123456789ABCDEF0C3C3E7E70000E7C6


def test_exp09_sequence_compiles_like_exp08s():
    from nemo_ctl.sequence import compile_steps
    from nemo_ctl.verify import load_verify_sequence
    import yaml
    table, expect, margin = load_verify_sequence(SEQ)
    exp08 = yaml.safe_load((TOOLS.parent / "config" / "chip_sim_test.yaml").read_text())
    assert table.summary() == compile_steps(exp08["steps"], CHIP).summary()   # expect changes nothing
    assert expect["piso_out"].value == EXP08 and expect["sipo_out"].value == 1
    assert margin == pytest.approx(2.0003)                                    # + piso_read's 300 us timeout


def test_sequence_expect_must_be_on_the_last_capture():
    from nemo_ctl.verify import sequence_expectations
    steps = [{"name": "a", "capture": {"piso_out": {"mode": "SERIAL", "bits": 8, "expect": 1}}},
             {"name": "b", "capture": {"piso_out": {"mode": "SERIAL", "bits": 8}}}]
    with pytest.raises(VerifyError, match="step 'b' re-arms piso_out"):
        sequence_expectations(steps)
    del steps[0]["capture"]["piso_out"]["expect"]
    steps[1]["capture"]["piso_out"]["expect"] = "0x1FF"
    with pytest.raises(VerifyError, match="step 'b' / piso_out: expect '0x1FF' doesn't fit in 8 bits"):
        sequence_expectations(steps)


def test_cli_seq_on_a_fake_vchip(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(cli, "_open_chip_link", lambda args: _Board(piso=EXP08, level=1))
    assert cli.main(["verify", "--seq", str(SEQ), "--jtag", "--repeat", "3"]) == 0
    assert "PASS: 3 pass, 0 fail, 2 not judged, 3 runs" in capsys.readouterr().out
    monkeypatch.setattr(cli, "_open_chip_link", lambda args: _Board(piso=EXP08 & ~0xFF, level=1))
    assert cli.main(["verify", "--seq", str(SEQ), "--jtag"]) == 1
    assert "PISO3 tdc_out0" in capsys.readouterr().out
    wrong = tmp_path / "p7.yaml"
    wrong.write_text("target: phase7_seq_loopback_top\nsteps: []\n")
    assert cli.main(["verify", "--seq", str(wrong), "--dry-run"]) == 1
    assert "verify runs on chip_top" in capsys.readouterr().err


# ---- edge_count expects are refused (docs/issues.md 2026-11-02) ----
# cap_cell.sv clears edge_count while run is low and the captures are read after the run, so
# an edge-count expect could only ever read 0 on the board (EXP-07 / EXP-08: always "edges 0").

def test_edge_count_expect_is_refused_everywhere():
    import yaml
    from nemo_ctl import gui
    from nemo_ctl.config import config_from_dict
    from nemo_ctl.pins import load_pin_db
    from nemo_ctl.validate import validate_config
    text = _text().replace("sipo_out: {type: CAPTURE, mode: level}",
                           "sipo_out: {type: CAPTURE, mode: edge_count, expect: 136}")
    assert text != _text()
    doc = yaml.safe_load(text)
    # validate (and so the editor's live check and Save) reports it on the pin
    issues = [i for i in validate_config(config_from_dict(doc), load_pin_db())
              if i.key == "sipo_out" and i.level == "error"]
    assert issues and "can't be checked" in issues[0].message
    # cli verify / the editor's Verify refuse it before touching the board
    with pytest.raises(VerifyError, match="can't be checked"):
        mode_expectations(config_from_dict(doc), "INFERENCE")
    r = gui.verify_payload({**doc, "mode": "INFERENCE", "dry": True}, open_link=lambda: pytest.fail("no board"))
    assert not r["ok"] and "can't be checked" in r["error"]


def test_edge_count_capture_without_expect_is_still_shown():
    assert parse_expect("p", "B", {"mode": "edge_count"}) is None

