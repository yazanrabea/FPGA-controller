"""Browser form for the chip config (config/nemo_config.yaml): the wizard's job as a page.

generic_controller_prompt.md §3 Phase 2: "A GUI is optional and only after phase 5 works."
Phase 5 works (EXP-02), so this is it. Same data, same rules as the wizard and Excel:
the page edits the same {modes: {mode: {block: {pin: setting}}}} structure, the checks
are validate.validate_config, the achieved values are timing.py's, the waveform panel is
waves.py's (real edge times of the unsaved edits), and Save writes the
file with config.save_config (a .bak copy of the old file is kept first; like the wizard,
saving drops the YAML comments). "Run on board" (chip pipeline C5) runs the shown mode, as
edited, on chip_top over the JTAG cable (mode_seq.py, same as `cli run-mode --jtag`).

    cd tools && python -m nemo_ctl.cli gui [--config ../config/nemo_config.yaml]

Runs a small web server on 127.0.0.1 only (this PC; nothing on the network can reach
it) using just the standard library, and opens the page in the default browser. Stop it
with Ctrl+C. Requests must name 127.0.0.1/localhost as Host and POSTs must be JSON, so a
web page you happen to visit can't drive it.
"""
from __future__ import annotations

import json
import shutil
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .config import DEFAULT_CONFIG_PATH, ConfigError, config_from_dict, load_config, save_config
from .dft_helper import SIGNAL_NAMES
from .groups import PIN_GROUPS
from .pins import Pin, load_pin_db
from .timing import _summarize_setting
from .validate import has_errors, validate_config
from .waves import WaveError, mode_waves
from .mode_seq import mode_table, run_table
from .sequence import SequenceError
from .units import UnitsError, parse_duration_ns

PAGE_PATH = Path(__file__).resolve().parent / "data" / "config_gui.html"


def _pin_json(p: Pin) -> dict:
    return {
        "name": p.name, "block": p.block, "direction": p.direction,
        "allowed": [t.value for t in p.allowed_types], "polarity": p.polarity,
        "idle": p.idle_level, "notes": p.notes, "limits": p.limits or {},
    }


def state_payload(config_path: Path, pin_db: dict[str, Pin]) -> dict:
    """Everything the page needs to draw itself: the file's modes, the pin list (blocks in
    pin_db order), the bus groups and the DFT helper's signal names."""
    from .config import config_to_dict
    doc = config_to_dict(load_config(config_path))
    return {
        "path": str(config_path),
        "modes": doc["modes"],
        "pin_map": doc["pin_map"],
        "pins": [_pin_json(p) for p in pin_db.values()],
        "groups": PIN_GROUPS,
        "dft_signals": list(SIGNAL_NAMES),
    }


def check_payload(doc: dict, pin_db: dict[str, Pin]) -> dict:
    """Parse + validate a config the page sent. Returns the issues (level/mode/block/key/
    message) and, per setting, the achieved-value line timing.py prints in `preview`."""
    try:
        config = config_from_dict(doc)
    except (ConfigError, TypeError, AttributeError, ValueError) as exc:
        return {"parse_error": str(exc), "issues": [], "summaries": {}, "errors": 1, "warnings": 0}
    try:
        issues = validate_config(config, pin_db)
    except Exception as exc:  # a malformed field the validator didn't expect
        return {"parse_error": f"could not check: {exc}", "issues": [], "summaries": {},
                "errors": 1, "warnings": 0}
    summaries: dict = {}
    for mode in config.mode_names():
        for block, key, setting in config.iter_settings(mode):
            try:
                text = _summarize_setting(block, key, setting).summary
                ok = True
            except Exception as exc:
                text, ok = str(exc), False
            summaries.setdefault(mode, {}).setdefault(block, {})[key] = {"text": text, "ok": ok}
    out = [{"level": i.level, "mode": i.mode, "block": i.block, "key": i.key, "message": i.message}
           for i in issues]
    return {
        "parse_error": None, "issues": out, "summaries": summaries,
        "errors": sum(1 for i in issues if i.level == "error"),
        "warnings": sum(1 for i in issues if i.level == "warning"),
    }


def waves_payload(doc: dict) -> dict:
    """The waveform of doc["mode"] in the config the page sent (not the saved file), over
    [doc["t0"], doc["t1"]] ns, or the whole mode when those are missing."""
    try:
        config = config_from_dict(doc)
        return mode_waves(config, doc.get("mode") or "", doc.get("t0"), doc.get("t1"))
    except (ConfigError, WaveError, TypeError, AttributeError, ValueError) as exc:
        return {"error": str(exc), "lanes": []}


def save_payload(doc: dict, config_path: Path, pin_db: dict[str, Pin]) -> dict:
    """Save only a config without errors (warnings are fine: most of them are the
    UNCONFIRMED / TBD notes). The previous file is copied to <name>.bak first."""
    result = check_payload(doc, pin_db)
    if result["parse_error"] or result["errors"]:
        result["saved"] = False
        result["message"] = "Not saved: fix the errors first."
        return result
    config = config_from_dict(doc)
    backup = config_path.with_suffix(config_path.suffix + ".bak")
    if config_path.exists():
        shutil.copy2(config_path, backup)
    save_config(config, config_path)
    result["saved"] = True
    result["message"] = f"Saved {config_path.name} (previous version in {backup.name})."
    return result


def _open_board():
    """SeqLink to chip_top over the J17 JTAG cable (tests replace it)."""
    from .jtag import open_jtag
    from .link import SeqLink
    from .sequence import chip_target
    return open_jtag(link_cls=SeqLink, target=chip_target())


_RUN_LOCK = threading.Lock()   # one board run at a time


def run_payload(doc: dict, open_link=_open_board) -> dict:
    """Run doc["mode"] of the config the page sent on chip_top (doc["dry"]: only convert).
    doc["duration"]: "350us" etc., empty = the mode's last event + 10 %."""
    try:
        config = config_from_dict(doc)
        dur = doc.get("duration")
        dur_s = parse_duration_ns(dur) * 1e-9 if dur else None
        table, notes = mode_table(config, doc.get("mode") or "", dur_s)
    except (ConfigError, SequenceError, UnitsError, TypeError, AttributeError, ValueError) as exc:
        return {"ok": False, "error": str(exc)}
    out = {"ok": True, "summary": table.summary(), "notes": notes, "warnings": list(table.warnings)}
    if doc.get("dry"):
        return out
    if not _RUN_LOCK.acquire(blocking=False):
        return {"ok": False, "error": "a board run is already going"}
    try:
        link = open_link()
        try:
            out.update(run_table(link, table))
        finally:
            link.close()
    except Exception as exc:          # the cable, xsdb, the link: report, don't crash the server
        return {**out, "ok": False, "error": f"board run failed: {exc}"}
    finally:
        _RUN_LOCK.release()
    return out


class _Handler(BaseHTTPRequestHandler):
    config_path: Path
    pin_db: dict[str, Pin]
    port: int
    open_link = staticmethod(_open_board)

    def log_message(self, *_args):  # keep the terminal quiet
        pass

    def _host_ok(self) -> bool:
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

    def do_GET(self):
        if not self._host_ok():
            return self._json(403, {"error": "local requests only"})
        if self.path in ("/", "/index.html"):
            return self._send(200, PAGE_PATH.read_bytes(), "text/html; charset=utf-8")
        if self.path == "/api/state":
            return self._json(200, state_payload(self.config_path, self.pin_db))
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok():
            return self._json(403, {"error": "local requests only"})
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return self._json(415, {"error": "JSON only"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            doc = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad JSON"})
        if self.path == "/api/check":
            return self._json(200, check_payload(doc, self.pin_db))
        if self.path == "/api/waves":
            return self._json(200, waves_payload(doc))
        if self.path == "/api/run":
            return self._json(200, run_payload(doc, self.open_link))
        if self.path == "/api/save":
            return self._json(200, save_payload(doc, self.config_path, self.pin_db))
        return self._json(404, {"error": "not found"})


def make_server(config_path: Path | None = None, port: int = 0,
                pin_db: dict[str, Pin] | None = None, open_link=None) -> ThreadingHTTPServer:
    """A server bound to 127.0.0.1 (port 0 = any free port); call serve_forever().
    `open_link`: how Run on board reaches chip_top (default: JTAG on J17)."""
    config_path = Path(config_path or DEFAULT_CONFIG_PATH).resolve()
    handler = type("Handler", (_Handler,), {
        "config_path": config_path,
        "pin_db": pin_db or load_pin_db(),
        "open_link": staticmethod(open_link or _open_board),
    })
    return ThreadingHTTPServer(("127.0.0.1", port), handler)


def serve(config_path: Path | None = None, port: int = 8765, open_browser: bool = True) -> None:
    srv = make_server(config_path, port)
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    print(f"Config editor for {srv.RequestHandlerClass.config_path}")
    print(f"Open {url} in your browser (Ctrl+C here to stop).")
    if open_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
    finally:
        srv.server_close()
