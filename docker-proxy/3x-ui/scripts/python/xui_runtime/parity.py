"""Bash/Python desired-state parity checks."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from xui_runtime.desired import build_desired_state


def canonical_json(obj: Any) -> str:
    """Stable JSON serialization for cross-language comparison."""
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


class ParityError(Exception):
    """Desired-state JSON does not match between bash and Python."""


def assert_parity(bash_obj: Any, python_obj: Any) -> None:
    """Raise ``ParityError`` when canonical JSON differs."""
    bash_text = canonical_json(bash_obj)
    python_text = canonical_json(python_obj)
    if bash_text != python_text:
        raise ParityError(
            "desired-state parity failed:\n"
            f"  bash  : {bash_text}\n"
            f"  python: {python_text}"
        )


def _cmd_desired(bash_json_file: Path) -> int:
    raw = bash_json_file.read_text(encoding="utf-8")
    bash_obj = json.loads(raw)
    python_obj = build_desired_state(os.environ)
    try:
        assert_parity(bash_obj, python_obj)
    except ParityError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


def cli(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="xui_runtime.parity")
    sub = parser.add_subparsers(dest="command", required=True)

    desired_parser = sub.add_parser(
        "desired",
        help="Compare bash desired JSON file to Python build_desired_state",
    )
    desired_parser.add_argument(
        "--bash-json-file",
        required=True,
        type=Path,
        help="Path to JSON from bash build_desired_state",
    )

    args = parser.parse_args(argv)
    if args.command == "desired":
        code = _cmd_desired(args.bash_json_file)
        raise SystemExit(code)
    raise SystemExit(2)


if __name__ == "__main__":
    cli()