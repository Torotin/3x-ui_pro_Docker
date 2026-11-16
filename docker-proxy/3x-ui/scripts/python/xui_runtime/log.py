import sys
from datetime import datetime, timezone

_LEVELS = ("INFO", "WARN", "ERROR")


def log(level: str, message: str) -> None:
    level = level.upper()
    if level not in _LEVELS:
        level = "INFO"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts} [{level}] {message}", file=sys.stderr)