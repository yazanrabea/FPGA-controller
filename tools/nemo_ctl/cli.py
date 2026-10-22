"""Thin interactive shell over wizard.py — the only file here that calls input()/print()
directly. `python3 -m nemo_ctl.cli <subcommand>` from the repo root (or anywhere, with
tools/ on PYTHONPATH).
"""
from __future__ import annotations

import argparse
import json
import sys
import textwrap
from pathlib import Path

from .config import DEFAULT_CONFIG_PATH, load_config, save_config
from .excel_io import export_config, export_template, import_config
from .link import DEBUG_CELL_NAMES, SigCellConfig, open_serial
from .pins import load_pin_db
from .preview import preview_mode
from .timing import format_timing_table, summarize_mode
from .units import quantize_clock
from .validate import validate_config
from .wizard import run_wizard


def _ask(prompt: str) -> str:
    return input(prompt)


def _tell(msg: str) -> None:
    print(msg)


def cmd_wizard(args: argparse.Namespace) -> int:
    config_path = Path(args.config)
    cfg = load_config(config_path)
    pin_db = load_pin_db()

    run_wizard(cfg, pin_db, args.mode, _ask, _tell)

    issues = validate_config(cfg, pin_db)
    if issues:
        print("\nValidation:")
        for issue in issues:
            print(f"  {issue}")

    save_config(cfg, config_path)
    print(f"\nSaved {config_path}")

    if args.excel:
        export_config(cfg, Path(args.excel))
        print(f"Exported {args.excel}")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    cfg = load_config(Path(args.config))
    pin_db = load_pin_db()
    issues = validate_config(cfg, pin_db)
    for issue in issues:
        print(issue)
    return 1 if any(i.level == "error" for i in issues) else 0


def cmd_preview(args: argparse.Namespace) -> int:
    cfg = load_config(Path(args.config))
    if args.format == "table":
        print(format_timing_table(summarize_mode(cfg, args.mode)))
    else:
        print(json.dumps(preview_mode(cfg, args.mode), indent=2))
    return 0


def cmd_export_excel(args: argparse.Namespace) -> int:
    cfg = load_config(Path(args.config))
    export_config(cfg, Path(args.out))
    print(f"wrote {args.out}")
    return 0


def cmd_import_excel(args: argparse.Namespace) -> int:
    cfg = import_config(Path(args.excel))
    save_config(cfg, Path(args.config))
    print(f"wrote {args.config}")
    return 0


def cmd_gen_template(args: argparse.Namespace) -> int:
    pin_db = load_pin_db()
    export_template(pin_db, Path(args.out), modes=tuple(args.modes))
    print(f"wrote {args.out}")
    return 0


def _open_link(args: argparse.Namespace):
    return open_serial(args.port, baud=args.baud, timeout=args.timeout)


def _open_seqlink(args: argparse.Namespace):
    """SeqLink on the serial port (tests replace this function)."""
    from .link import SeqLink, SerialTransport
    return SeqLink(SerialTransport(args.port, baud=args.baud, timeout=args.timeout))


def _print_seq_status(st, step, last) -> None:
    flags = [n for n in ("run", "busy", "done", "fault", "aborted", "late", "table_rejected",
                         "rx_overflow") if getattr(st, n)]
    print(f"STATUS: {' '.join(flags) or 'idle'}; step {step}, last step {last}")


def cmd_seq_load(args: argparse.Namespace) -> int:
    from .sequence import SequenceError, link_late_warnings, load_sequence
    try:
        table = load_sequence(Path(args.config))
    except SequenceError as exc:
        for line in str(exc).splitlines():
            print(f"error: {line}", file=sys.stderr)
        return 1
    for line in table.summary():
        print(line)
    for w in list(table.warnings) + link_late_warnings(table):
        print(f"warning: {w}", file=sys.stderr)
    sl = _open_seqlink(args)
    try:
        sl.load(table)
    finally:
        sl.close()
    print(f"loaded {len(table.steps)} steps, step 0 applied")
    return 0


def cmd_seq_run(args: argparse.Namespace) -> int:
    from .link import V2_STEP
    sl = _open_seqlink(args)
    try:
        sl.start()
        if args.wait <= 0:
            print("RUN sent")
            return 0
        r = sl.wait(args.wait)
        st = sl.seq_status()
        _print_seq_status(st, sl.read_reg(V2_STEP, 1)[0], r.step)
    finally:
        sl.close()
    return 0 if r.done and not r.fault else 1


def cmd_seq_stop(args: argparse.Namespace) -> int:
    sl = _open_seqlink(args)
    try:
        sl.abort()
    finally:
        sl.close()
    print("STOP sent")
    return 0


def cmd_seq_status(args: argparse.Namespace) -> int:
    from .link import V2_LAST_STEP, V2_STEP
    sl = _open_seqlink(args)
    try:
        _print_seq_status(sl.seq_status(), sl.read_reg(V2_STEP, 1)[0], sl.read_reg(V2_LAST_STEP, 1)[0])
    finally:
        sl.close()
    return 0


def cmd_seq_read(args: argparse.Namespace) -> int:
    sl = _open_seqlink(args)
    try:
        value = sl.read_capture(args.cell)
        c = sl.read_cap_counts(args.cell)
    finally:
        sl.close()
    print(f"{args.cell}: capture 0x{value:X}, edges {c['edges']}, level {int(c['level'])}")
    return 0


def cmd_link_status(args: argparse.Namespace) -> int:
    lnk = _open_link(args)
    try:
        running = lnk.status()
    finally:
        lnk.close()
    print("RUNNING" if running else "STOPPED")
    return 0


def cmd_link_run(args: argparse.Namespace) -> int:
    lnk = _open_link(args)
    try:
        lnk.run()
    finally:
        lnk.close()
    print("RUN sent")
    return 0


def cmd_link_stop(args: argparse.Namespace) -> int:
    lnk = _open_link(args)
    try:
        lnk.stop()
    finally:
        lnk.close()
    print("STOP sent")
    return 0


def cmd_link_apply(args: argparse.Namespace) -> int:
    lnk = _open_link(args)
    try:
        lnk.apply()
    finally:
        lnk.close()
    print("APPLY sent")
    return 0


def cmd_link_set_clock(args: argparse.Namespace) -> int:
    q = quantize_clock(args.freq, args.duty)
    cfg = SigCellConfig(type="CLOCK", param_a=q.period_ticks, param_b=q.high_ticks,
                         cycles=args.cycles)
    lnk = _open_link(args)
    try:
        lnk.send_cell_config(args.cell, cfg)
        if args.apply:
            lnk.apply()
    finally:
        lnk.close()
    print(f"requested {q.requested_hz / 1e6:.4f} MHz -> achieved {q.achieved_hz / 1e6:.4f} MHz "
          f"({q.error_pct:+.2f}%), period={q.period_ticks} ticks, high={q.high_ticks} ticks"
          + (" -- applied" if args.apply else " -- NOT applied yet, run `link apply` (or pass --apply)"))
    return 0


def cmd_link_read_captures(args: argparse.Namespace) -> int:
    lnk = _open_link(args)
    try:
        statuses = lnk.read_captures()
    finally:
        lnk.close()
    for cell, st in statuses.items():
        print(f"{cell}: level_out={st.level_out} period_valid={st.period_valid} done={st.done} "
              f"edge_count={st.edge_count} period_ticks={st.period_ticks} high_ticks={st.high_ticks} "
              f"capture_reg=0x{st.capture_reg:04X}")
    return 0


# Every description/epilog here is meant to match docs/USER_MANUAL.md word for word
# where it overlaps -- if you change the wording in one, change it in the other.
_RDF = argparse.RawDescriptionHelpFormatter


def _wrap(text: str, width: int = 78) -> str:
    """Fill a one-paragraph description to `width` columns. Descriptions above are
    written as plain prose (easy to edit/diff); RawDescriptionHelpFormatter -- needed so
    epilogs keep their intentional example-command line breaks -- would otherwise print
    them as one unwrapped line."""
    return textwrap.fill(" ".join(text.split()), width=width)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="nemo_ctl",
        description=_wrap(
            "NEMO/Y-Flash generic controller config tool. Run as a module from inside "
            "tools/: `cd tools && python3 -m nemo_ctl.cli <command> --help`. "
            "Full walkthroughs: docs/USER_MANUAL.md."
        ),
        formatter_class=_RDF,
    )
    sub = p.add_subparsers(dest="command", required=True)

    w = sub.add_parser(
        "wizard",
        help="interactively build one mode's config",
        description=_wrap(
            "Walk one mode block by block, pin by pin: show the current setting and a "
            "menu built from exactly the types that pin allows, quantize units as you "
            "type, validate, and save. See docs/USER_MANUAL.md section 3 for the full menu "
            "walkthrough (what each type asks for, grouped-pin/bus handling, the DFT "
            "helper)."
        ),
        epilog=(
            "This OVERWRITES --config when it finishes. To try it safely, point it at a "
            "copy first:\n"
            "  cp config/nemo_config.yaml /tmp/my_test.yaml\n"
            "  python3 -m nemo_ctl.cli wizard --mode INFERENCE --config /tmp/my_test.yaml"
        ),
        formatter_class=_RDF,
    )
    w.add_argument("--mode", required=True, choices=["READ", "WRITE", "INFERENCE"],
                    help="which mode (profile) to build or edit")
    w.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                    help=f"YAML config to load and overwrite (default: {DEFAULT_CONFIG_PATH})")
    w.add_argument("--excel", default=None,
                    help="also export to this .xlsx path after saving the YAML")
    w.set_defaults(func=cmd_wizard)

    v = sub.add_parser(
        "validate",
        help="validate the config, print every issue",
        description=_wrap(
            "Check --config for errors (type not allowed on a pin, frequency over the "
            "50 MHz hard limit, a pin configured twice, a SERIAL setting referencing a "
            "clock that isn't configured, ...) and warnings (TBD/UNCONFIRMED items from "
            "docs/controller_spec.md -- expected, not a problem). No output means no "
            "issues of either kind. See docs/USER_MANUAL.md section 2.1."
        ),
        epilog="Exit code is 1 if any [ERROR] was printed, 0 otherwise (warnings don't fail it).",
        formatter_class=_RDF,
    )
    v.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                    help=f"YAML config to validate (default: {DEFAULT_CONFIG_PATH})")
    v.set_defaults(func=cmd_validate)

    pr = sub.add_parser(
        "preview",
        help="print a timing table or WaveDrom JSON for one mode",
        description=_wrap(
            "Show every configured pin in --mode with its achieved value and error "
            "after tick quantization (e.g. a 3 MHz request becomes 3.0303 MHz, +1.0%). "
            "--format table is a markdown table; --format wavedrom is a waveform "
            "diagram you can paste into a WaveDrom-compatible viewer. See "
            "docs/USER_MANUAL.md section 2.2."
        ),
        formatter_class=_RDF,
    )
    pr.add_argument("--mode", required=True, help="which mode to preview")
    pr.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                     help=f"YAML config to read (default: {DEFAULT_CONFIG_PATH})")
    pr.add_argument("--format", choices=["table", "wavedrom"], default="table",
                     help="output shape (default: table)")
    pr.set_defaults(func=cmd_preview)

    ee = sub.add_parser(
        "export-excel",
        help="export the YAML config to a workbook",
        description=_wrap(
            "Write --config to an .xlsx, one sheet per mode, same columns the wizard "
            "and the YAML both use. See docs/USER_MANUAL.md section 2.3."
        ),
        formatter_class=_RDF,
    )
    ee.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                     help=f"YAML config to read (default: {DEFAULT_CONFIG_PATH})")
    ee.add_argument("--out", required=True, help="path to write the .xlsx to")
    ee.set_defaults(func=cmd_export_excel)

    ie = sub.add_parser(
        "import-excel",
        help="import a workbook, overwrite the YAML config",
        description=_wrap(
            "Read an .xlsx built by export-excel (or gen-template, filled in) and "
            "overwrite --config with it. See docs/USER_MANUAL.md section 2.3."
        ),
        formatter_class=_RDF,
    )
    ie.add_argument("--excel", required=True, help="the .xlsx to read")
    ie.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                     help=f"YAML config path to overwrite (default: {DEFAULT_CONFIG_PATH})")
    ie.set_defaults(func=cmd_import_excel)

    gt = sub.add_parser(
        "gen-template",
        help="blank Excel template, one row per input pin",
        description=_wrap(
            "Write a blank .xlsx, one sheet per --modes entry, one row per input pin "
            "(grouped by block), Type column empty for you to fill in -- a starting "
            "point when you don't already have a config to export. See "
            "docs/USER_MANUAL.md section 2.3."
        ),
        formatter_class=_RDF,
    )
    gt.add_argument("--out", required=True, help="path to write the blank .xlsx to")
    gt.add_argument("--modes", nargs="+", default=["READ", "WRITE", "INFERENCE"],
                     help="which mode sheets to include (default: all three)")
    gt.set_defaults(func=cmd_gen_template)

    # ---- link: Phase 5 runtime link over a real USB-UART serial port ----
    # needs actual hardware (a programmed board + a confirmed serial port) -- see
    # docs/USER_MANUAL.md section 6 and docs/experiments/EXP-02.
    link_common = argparse.ArgumentParser(add_help=False)
    link_common.add_argument("--port", required=True,
                              help="serial device for the USB-UART adapter, e.g. /dev/ttyUSB0 "
                                   "or /dev/tty.usbserial-XXXX (macOS) or COM3 (Windows)")
    link_common.add_argument("--baud", type=int, default=115_200,
                              help="must match uart_tx.sv/uart_rx.sv's BAUD on the loaded "
                                   "bitstream (default: 115200)")
    link_common.add_argument("--timeout", type=float, default=1.0,
                              help="seconds to wait for a response before giving up (default: 1.0)")

    lk = sub.add_parser(
        "link",
        help="talk to a running phase5_link_top bitstream over the serial link",
        description=_wrap(
            "Low-level control of the Phase 5 runtime link (docs/link_register_map.md, "
            "fpga/src/link_ctrl.sv). Needs a board already programmed with a "
            "phase5_link_top bitstream and a USB-UART adapter wired up -- see "
            "docs/USER_MANUAL.md section 6."
        ),
        formatter_class=_RDF,
    )
    lk_sub = lk.add_subparsers(dest="link_command", required=True)

    lk_status = lk_sub.add_parser(
        "status", parents=[link_common], formatter_class=_RDF,
        help="print whether the board is currently RUNNING or STOPPED",
        description=_wrap("Send STATUS and print RUNNING or STOPPED. See docs/USER_MANUAL.md section 6.2."),
    )
    lk_status.set_defaults(func=cmd_link_status)

    lk_run = lk_sub.add_parser(
        "run", parents=[link_common], formatter_class=_RDF,
        help="send RUN (start every configured cell)",
        description=_wrap("Send the RUN command. See docs/USER_MANUAL.md section 6.2."),
    )
    lk_run.set_defaults(func=cmd_link_run)

    lk_stop = lk_sub.add_parser(
        "stop", parents=[link_common], formatter_class=_RDF,
        help="send STOP (halt every cell, pins idle)",
        description=_wrap("Send the STOP command. See docs/USER_MANUAL.md section 6.2."),
    )
    lk_stop.set_defaults(func=cmd_link_stop)

    lk_apply = lk_sub.add_parser(
        "apply", parents=[link_common], formatter_class=_RDF,
        help="send APPLY (latch any pending register writes, even while RUNning)",
        description=_wrap(
            "Send the APPLY command, which atomically latches any WRITE_REGs sent since "
            "the last apply -- works while RUNning, no STOP needed. See "
            "docs/USER_MANUAL.md section 6.2."
        ),
    )
    lk_apply.set_defaults(func=cmd_link_apply)

    lk_clock = lk_sub.add_parser(
        "set-clock", parents=[link_common], formatter_class=_RDF,
        help="configure one debug cell as a CLOCK at a given frequency",
        description=_wrap(
            "Write a CLOCK config (requested frequency/duty, quantized to 100 MHz ticks "
            "the same way the wizard does -- see docs/USER_MANUAL.md section 2.2) to one "
            "of the 5 fixed debug cells. This is Phase 5's own exit criterion: run it "
            "once, `link run`, then run it again with a different --freq and --apply (or "
            "a separate `link apply`) WHILE still running, and see the new frequency on "
            "the multimeter/scope -- no re-synthesis. See docs/USER_MANUAL.md section 6.2 "
            "and docs/experiments/EXP-02."
        ),
        epilog=(
            "Example (change test_clock to 2 kHz and take effect immediately):\n"
            "  python3 -m nemo_ctl.cli link set-clock --port /dev/ttyUSB0 \\\n"
            "      --cell test_clock --freq 2kHz --apply"
        ),
    )
    lk_clock.add_argument("--cell", required=True, choices=list(DEBUG_CELL_NAMES),
                           help="which debug cell to configure")
    lk_clock.add_argument("--freq", required=True,
                           help="requested frequency, e.g. 1MHz, 500kHz, or a bare number of Hz")
    lk_clock.add_argument("--duty", default="50%",
                           help="requested duty cycle, e.g. 50%% (default: 50%%)")
    lk_clock.add_argument("--cycles", type=int, default=0,
                           help="run for this many cycles then stop on its own, 0 = free-running "
                                "(default: 0)")
    lk_clock.add_argument("--apply", action="store_true",
                           help="also send APPLY immediately after writing the config")
    lk_clock.set_defaults(func=cmd_link_set_clock)

    lk_cap = lk_sub.add_parser(
        "read-captures", parents=[link_common], formatter_class=_RDF,
        help="print every debug cell's live capture status",
        description=_wrap(
            "Read and print every debug cell's cap_cell status (level_out/period_valid/"
            "done/edge_count/period_ticks/high_ticks/capture_reg). See "
            "docs/USER_MANUAL.md section 6.2."
        ),
    )
    lk_cap.set_defaults(func=cmd_link_read_captures)

    # ---- seq: Phase 7 round 2, the step sequencer over link v2 (phase7_link_top) ----
    sq = sub.add_parser(
        "seq",
        help="load / run / read a step sequence on a phase7_link_top bitstream",
        description=_wrap(
            "Phase 7 step sequencer over link v2 (docs/link_register_map.md 'v2', "
            "fpga/src/phase7_link_top.sv). Needs a board programmed with phase7_link_top "
            "and the USB-UART adapter wired up (pin/voltage still unconfirmed, EXP-02). "
            "See docs/USER_MANUAL.md section 8.6."
        ),
    )
    sq_sub = sq.add_subparsers(dest="seq_command", required=True)
    sq_load = sq_sub.add_parser(
        "load", parents=[link_common], formatter_class=_RDF,
        help="check a sequence YAML, send its step table, apply its idle state",
        description=_wrap("Compile and check the sequence (same checks as "
                          "`python -m nemo_ctl.sequence`), write every step to the board, then "
                          "APPLY so the pins sit at its step 0. Refused if a sequence is running."),
    )
    sq_load.add_argument("config", help="sequence YAML, e.g. ../config/phase7_seq_loopback.yaml")
    sq_load.set_defaults(func=cmd_seq_load)
    sq_run = sq_sub.add_parser(
        "run", parents=[link_common], formatter_class=_RDF,
        help="start the loaded sequence (optionally wait for it)",
        description=_wrap("Start the loaded sequence. With --wait N, poll STATUS for up to N "
                          "seconds and print how it ended."),
    )
    sq_run.add_argument("--wait", type=float, default=0.0, metavar="SECONDS",
                        help="poll until it finishes, up to this many seconds (default: don't wait)")
    sq_run.set_defaults(func=cmd_seq_run)
    sq_stop = sq_sub.add_parser("stop", parents=[link_common], formatter_class=_RDF,
                                help="abort the running sequence (pins back to step 0)")
    sq_stop.set_defaults(func=cmd_seq_stop)
    sq_status = sq_sub.add_parser("status", parents=[link_common], formatter_class=_RDF,
                                  help="print STATUS flags, current and last step")
    sq_status.set_defaults(func=cmd_seq_status)
    sq_read = sq_sub.add_parser("read", parents=[link_common], formatter_class=_RDF,
                                help="print a cap cell's capture register and edge count")
    sq_read.add_argument("cell", help="cap cell name, e.g. data_in")
    sq_read.set_defaults(func=cmd_seq_read)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
