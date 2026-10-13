"""Thin interactive shell over wizard.py — the only file here that calls input()/print()
directly. `python3 -m nemo_ctl.cli <subcommand>` from the repo root (or anywhere, with
tools/ on PYTHONPATH).
"""
from __future__ import annotations

import argparse
import json
import sys
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


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="nemo_ctl")
    sub = p.add_subparsers(dest="command", required=True)

    w = sub.add_parser("wizard", help="interactively build one mode's config")
    w.add_argument("--mode", required=True, choices=["READ", "WRITE", "INFERENCE"])
    w.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    w.add_argument("--excel", default=None, help="also export to this .xlsx after saving")
    w.set_defaults(func=cmd_wizard)

    v = sub.add_parser("validate", help="validate the config, print every issue")
    v.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    v.set_defaults(func=cmd_validate)

    pr = sub.add_parser("preview", help="print a timing table or WaveDrom JSON for one mode")
    pr.add_argument("--mode", required=True)
    pr.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    pr.add_argument("--format", choices=["table", "wavedrom"], default="table")
    pr.set_defaults(func=cmd_preview)

    ee = sub.add_parser("export-excel", help="export the YAML config to a workbook")
    ee.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    ee.add_argument("--out", required=True)
    ee.set_defaults(func=cmd_export_excel)

    ie = sub.add_parser("import-excel", help="import a workbook, overwrite the YAML config")
    ie.add_argument("--excel", required=True)
    ie.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    ie.set_defaults(func=cmd_import_excel)

    gt = sub.add_parser("gen-template", help="blank Excel template, one row per input pin")
    gt.add_argument("--out", required=True)
    gt.add_argument("--modes", nargs="+", default=["READ", "WRITE", "INFERENCE"])
    gt.set_defaults(func=cmd_gen_template)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
