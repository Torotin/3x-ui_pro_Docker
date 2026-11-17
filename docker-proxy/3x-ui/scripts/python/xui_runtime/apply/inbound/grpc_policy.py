"""gRPC inbound policy when ENABLE_VLESS_GRPC is false."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.apply.inbound.ensure import (
    InboundApplyError,
    _list_inbounds,
    delete_managed_inbound_kind,
    find_inbound_by_port,
    managed_inbound_remarks,
)
from xui_runtime.common import ApplyStats, plan_or_apply


def ensure_grpc_when_disabled(
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if (env.get("ENABLE_VLESS_GRPC") or "false").strip().lower() == "true":
        return
    policy = (env.get("VLESS_GRPC_WHEN_DISABLED") or "disable").strip()
    if policy == "leave":
        return
    if policy == "delete":
        delete_managed_inbound_kind("grpc", desired, api, mode, stats)
        return

    kind = "grpc"
    inbounds = _list_inbounds(api)
    expected = managed_inbound_remarks(kind, desired)
    port = int(desired["inbounds"][kind]["port"])
    protocol = desired["inbounds"][kind]["protocol"]
    inbound_id = find_inbound_by_port(inbounds, port, protocol)
    if not inbound_id:
        for row in inbounds:
            remark = str(row.get("remark") or "")
            if remark in expected:
                inbound_id = str(row.get("id"))
                break
    if not inbound_id:
        log.log("INFO", "managed gRPC inbound not found; skip disable")
        return

    current = next(
        (row for row in inbounds if str(row.get("id")) == inbound_id),
        None,
    )
    remark = str((current or {}).get("remark") or "")
    if remark not in expected:
        log.log(
            "WARN",
            f"skip gRPC disable id={inbound_id} remark={remark} (not managed grpc)",
        )
        return

    if current is not None and not bool(current.get("enable", True)):
        log.log("INFO", f"managed gRPC inbound id={inbound_id} already disabled")
        return

    if not plan_or_apply(mode, stats, f"disable managed gRPC inbound id={inbound_id}"):
        return

    result = api.set_inbound_enable(inbound_id, False)
    if not result.ok or not api.session.success_json():
        raise InboundApplyError(
            f"gRPC inbound disable failed id={inbound_id}: {api.session.body()}"
        )
    stats.restart_xray_required = True