"""Shared apply utilities (plan/apply, change counting, JSON helpers)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from xui_runtime import log


@dataclass
class ApplyStats:
    change_count: int = 0
    restart_panel_required: bool = False
    restart_xray_required: bool = False


def record_change(stats: ApplyStats, message: str) -> None:
    stats.change_count += 1
    log.log("INFO", message)


def plan_or_apply(mode: str, stats: ApplyStats, message: str) -> bool:
    """Return True when apply mutations should run (MODE=apply)."""
    if mode == "plan":
        record_change(stats, f"PLAN: {message}")
        return False
    record_change(stats, f"APPLY: {message}")
    return True


def canonical_json(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def json_equal(left: Any, right: Any) -> bool:
    return canonical_json(left) == canonical_json(right)


def api_obj_json(session) -> dict[str, Any]:
    """Parse ``.obj`` from the last successful panel API JSON body."""
    try:
        payload = json.loads(session.body())
    except json.JSONDecodeError:
        return {}
    obj = payload.get("obj")
    if isinstance(obj, dict):
        return dict(obj)
    return {}