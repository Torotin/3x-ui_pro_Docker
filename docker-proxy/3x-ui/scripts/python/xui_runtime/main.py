"""CLI entry for the Python xui runtime (fail-closed until orchestrator exists)."""

from __future__ import annotations

import argparse
import sys

PYTHON_RUNTIME_READY = False

_NOT_IMPLEMENTED = (
    "XUI_RUNTIME_ENGINE=python is not implemented until main orchestrator is ready"
)


def cli(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="xui_runtime")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("check", "plan", "apply"),
        help="Runtime mode (check, plan, or apply)",
    )
    parser.parse_args(argv)

    if not PYTHON_RUNTIME_READY:
        print(_NOT_IMPLEMENTED, file=sys.stderr)
        raise SystemExit(2)

    print("xui_runtime: unexpected ready state", file=sys.stderr)
    raise SystemExit(1)


if __name__ == "__main__":
    cli()