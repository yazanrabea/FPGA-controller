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
from .pins import load_pin_db
from .preview import preview_mode
from .timing import format_timing_table, summarize_mode
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

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
