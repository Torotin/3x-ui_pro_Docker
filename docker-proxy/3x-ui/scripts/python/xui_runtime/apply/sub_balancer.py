"""JSON subscription balancer helpers (bash ``sub_balancer.bash`` parity, library-only)."""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.apply.sub_routing import admin_sub_auto_policy_name
from xui_runtime.common import ApplyStats, plan_or_apply


def build_admin_sub_json_observatory() -> dict[str, Any]:
    return {
        "destination": "https://www.gstatic.com/generate_204",
        "connectivity": "",
        "interval": "300s",
        "sampling": 2,
        "timeout": "5s",
        "httpMethod": "HEAD",
    }


def sub_balancer_ids_csv(ids: Sequence[str | int]) -> str:
    parts: list[str] = []
    for raw in ids:
        text = str(raw).strip()
        if text:
            parts.append(text)
    return ",".join(parts)


def sub_balancer_ids_json(ids: Sequence[str | int]) -> list[int]:
    numeric: list[int] = []
    for raw in ids:
        text = str(raw).strip()
        if not text:
            continue
        numeric.append(int(text))
    return sorted(numeric)


def sub_balancer_form_args(remark: str, inbound_ids: Sequence[str | int]) -> list[tuple[str, str]]:
    form: list[tuple[str, str]] = [
        ("remark", remark),
        ("strategy", "leastPing"),
        ("sortOrder", "1"),
        ("enabled", "true"),
    ]
    for raw in inbound_ids:
        text = str(raw).strip()
        if text:
            form.append(("inboundIds", text))
    return form


def _pick_current_auto_row(
    current_rows: list[dict[str, Any]],
    remark: str,
) -> dict[str, Any] | None:
    matches = [
        row
        for row in current_rows
        if isinstance(row, dict) and row.get("remark") in (remark, "AUTO")
    ]
    if not matches:
        return None
    matches.sort(key=lambda row: 0 if row.get("remark") == remark else 1)
    return matches[0]


def ensure_auto_sub_balancer(
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *inbound_ids: str | int,
) -> None:
    """Ensure AUTO-<WEBDOMAIN> JSON sub balancer uses leastPing (no live wiring)."""
    remark = admin_sub_auto_policy_name(env=env)
    if not remark:
        log.log("WARN", "AUTO sub balancer skipped: WEBDOMAIN empty.")
        return

    ids = [raw for raw in inbound_ids if str(raw).strip()]
    if not ids:
        log.log("WARN", f"{remark} sub balancer skipped: no inbound IDs.")
        return

    ids_csv = sub_balancer_ids_csv(ids)
    if not plan_or_apply(mode, stats, f"{remark} sub balancer ensured inboundIds={ids_csv}"):
        return

    result = api.list_sub_balancers()
    if not result.ok:
        log.log("WARN", f"{remark} sub balancer skipped: list API request failed.")
        return
    if not api.session.success_json():
        log.log("WARN", f"{remark} sub balancer skipped: list API returned failure: {api.session.body()}")
        return

    try:
        parsed = json.loads(api.session.body())
    except json.JSONDecodeError:
        log.log("WARN", f"{remark} sub balancer skipped: invalid list API JSON.")
        return
    obj = parsed.get("obj")
    current_rows: list[dict[str, Any]] = []
    if isinstance(obj, list):
        current_rows = [row for row in obj if isinstance(row, dict)]

    desired_ids = sub_balancer_ids_json(ids)
    form = sub_balancer_form_args(remark, ids)
    current_auto = _pick_current_auto_row(current_rows, remark)

    if current_auto is None:
        create = api.add_sub_balancer(form)
        if create.ok and api.session.success_json():
            log.log("INFO", f"{remark} sub balancer created inboundIds={ids_csv}.")
        else:
            log.log("WARN", f"{remark} sub balancer create skipped after API failure: {api.session.body()}")
        return

    current_id = str(current_auto.get("id") or "").strip()
    current_strategy = str(current_auto.get("strategy") or "")
    current_enabled = current_auto.get("enabled", True)
    if isinstance(current_enabled, str):
        current_enabled = current_enabled.lower() in ("true", "1", "yes", "on")
    inbound_raw = current_auto.get("inboundIds") or []
    current_ids = sorted(int(str(x)) for x in inbound_raw if str(x).strip())
    current_remark = str(current_auto.get("remark") or "")

    if (
        current_remark == remark
        and current_strategy == "leastPing"
        and current_enabled is True
        and current_ids == desired_ids
    ):
        log.log("INFO", f"{remark} sub balancer already matches desired state.")
        return

    if not current_id:
        log.log("WARN", f"{remark} sub balancer update skipped: existing row has no id.")
        return

    update = api.update_sub_balancer(current_id, form)
    if update.ok and api.session.success_json():
        log.log("INFO", f"{remark} sub balancer updated inboundIds={ids_csv}.")
    else:
        log.log("WARN", f"{remark} sub balancer update skipped after API failure: {api.session.body()}")