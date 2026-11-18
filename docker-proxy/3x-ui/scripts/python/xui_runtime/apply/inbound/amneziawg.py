"""AmneziaWG inbound profile and client helpers (library-only)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.awg_settings import _canon_scalar, awg_managed_equal
from xui_runtime.builders.inbounds import build_amneziawg_settings_json
from xui_runtime.common import ApplyStats, api_obj_json, json_equal, plan_or_apply
from xui_runtime.env import resolve_awg_mtu

from xui_runtime.apply.inbound.clients import (
    current_inbound_components_json,
    vless_client_create_payload_json,
)
from xui_runtime.apply.inbound.ensure import InboundApplyError, json_field_object

def sync_amneziawg_profile(
    amneziawg_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if not amneziawg_id:
        return
    mtu = resolve_awg_mtu(env)
    api.get_inbound(amneziawg_id)
    if not api.session.success_json():
        raise InboundApplyError(
            f"Inbound get failed id={amneziawg_id}: {api.session.body()}"
        )
    inbound = api_obj_json(api.session)
    settings = json_field_object(inbound, "settings")
    desired_settings = build_amneziawg_settings_json(desired, env)
    server_old = dict(settings.get("server") or {})
    patched = dict(settings)
    target_mtu = desired_settings.get("mtu", mtu)
    # Newer panels keep subnet/dns/mtu under settings.server and null top-level
    # mirrors. Do not invent top-level keys on every sync (causes perpetual churn).
    server = {**server_old, **(desired_settings.get("server") or {})}
    server["privateKey"] = server_old.get("privateKey") or server_old.get("secretKey")
    server.setdefault("publicKey", server_old.get("publicKey"))
    server.setdefault("headerProtectionKey", server_old.get("headerProtectionKey"))
    # Preserve panel subnet assignment; always project env/desired DNS + MTU
    # so AWG_DNS* / AWG_MTU flips are not frozen on prior panel values.
    server["subnetIp"] = server_old.get("subnetIp") or desired_settings["server"]["subnetIp"]
    server["subnetCidr"] = server_old.get("subnetCidr") or desired_settings["server"]["subnetCidr"]
    server["primaryDns"] = desired_settings["server"]["primaryDns"]
    server["secondaryDns"] = desired_settings["server"]["secondaryDns"]
    # Newer panels store MTU under server.mtu and leave top-level mtu null.
    # Always project env-resolved MTU (including AWG_MTU=auto); do not freeze
    # the previous server.mtu or Step 6 / MTU flips can never apply.
    server["mtu"] = target_mtu
    patched["server"] = server
    want_ka = _canon_scalar(env.get("AWG_CLIENT_KEEPALIVE") or "25")
    clients = patched.get("clients") or []
    patched["clients"] = [dict(client, keepAlive=want_ka) for client in clients]
    clients_ok = True
    for c in settings.get("clients") or []:
        if "keepAlive" not in c or _canon_scalar(c.get("keepAlive")) != want_ka:
            clients_ok = False
            break
    if awg_managed_equal(settings, patched) and clients_ok:
        log.log("INFO", "AmneziaWG profile already matches desired hygiene.")
        return
    components = current_inbound_components_json(inbound)
    components["settings"] = patched
    if plan_or_apply(
        mode,
        stats,
        f"AmneziaWG profile update id={amneziawg_id} mtu={mtu} trailers=on",
    ):
        api.update_inbound(amneziawg_id, components)
        if not api.session.success_json():
            raise InboundApplyError(
                f"Inbound update failed id={amneziawg_id}: {api.session.body()}"
            )
        log.log("INFO", f"AmneziaWG profile synced id={amneziawg_id} mtu={mtu} trailers=on")
        stats.restart_xray_required = True


def amneziawg_client_email(desired: Mapping[str, Any], env: Mapping[str, str]) -> str:
    shared = desired["clients"]["shared"]["email"]
    return env.get("CLIENT_EMAIL_AMNEZIAWG") or f"{shared}-amneziawg"


def amneziawg_client_api_json(email: str, sub_id: str) -> dict[str, Any]:
    return {
        "email": email,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": True,
        "tgId": 0,
        "subId": sub_id,
        "group": "",
        "comment": "",
        "reset": 0,
    }


def ensure_amneziawg_client(
    amneziawg_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if not amneziawg_id:
        return
    email = amneziawg_client_email(desired, env)
    sub_id = desired["clients"]["shared"]["subId"]
    api.get_inbound(amneziawg_id)
    if not api.session.success_json():
        raise InboundApplyError(
            f"Inbound get failed id={amneziawg_id}: {api.session.body()}"
        )
    inbound = api_obj_json(api.session)
    settings = json_field_object(inbound, "settings")
    clients = settings.get("clients") or (settings.get("server") or {}).get("clients") or []
    if clients:
        log.log(
            "INFO",
            "AmneziaWG inbound already has client configuration; preserving existing clients.",
        )
        return
    payload = vless_client_create_payload_json(
        [int(amneziawg_id)],
        amneziawg_client_api_json(email, sub_id),
    )
    if mode == "plan":
        plan_or_apply(
            mode,
            stats,
            f"AmneziaWG client created email={email} inbound={amneziawg_id}",
        )
        return
    plan_or_apply(
        mode,
        stats,
        f"AmneziaWG client created email={email} inbound={amneziawg_id}",
    )
    api.add_client(payload)
    if not api.session.success_json():
        raise InboundApplyError(f"AmneziaWG client add failed: {api.session.body()}")
    stats.restart_xray_required = True
