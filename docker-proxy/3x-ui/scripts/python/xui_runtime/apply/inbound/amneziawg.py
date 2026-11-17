"""AmneziaWG inbound profile and client helpers (library-only)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.inbounds import build_amneziawg_settings_json
from xui_runtime.common import ApplyStats, api_obj_json, json_equal, plan_or_apply

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
    mtu = int(desired.get("inbounds", {}).get("amneziawg", {}).get("mtu", 1280))
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
    patched["mtu"] = target_mtu
    patched.setdefault("subnet", desired_settings.get("subnet"))
    patched.setdefault("subnetIp", desired_settings.get("subnetIp") or server_old.get("subnetIp"))
    patched.setdefault(
        "subnetCidr", desired_settings.get("subnetCidr") or server_old.get("subnetCidr")
    )
    patched.setdefault("dns1", desired_settings.get("dns1"))
    patched.setdefault("dns2", desired_settings.get("dns2"))
    server = {**server_old, **(desired_settings.get("server") or {})}
    server["privateKey"] = server_old.get("privateKey") or server_old.get("secretKey")
    server.setdefault("publicKey", server_old.get("publicKey"))
    server.setdefault("headerProtectionKey", server_old.get("headerProtectionKey"))
    server["subnetIp"] = server_old.get("subnetIp") or desired_settings["server"]["subnetIp"]
    server["subnetCidr"] = server_old.get("subnetCidr") or desired_settings["server"]["subnetCidr"]
    server["primaryDns"] = server_old.get("primaryDns") or desired_settings["server"]["primaryDns"]
    server["secondaryDns"] = (
        server_old.get("secondaryDns") or desired_settings["server"]["secondaryDns"]
    )
    # Newer panels store MTU under server.mtu and leave top-level mtu null.
    server["mtu"] = server_old.get("mtu") if server_old.get("mtu") is not None else target_mtu
    patched["server"] = server
    clients = patched.get("clients") or []
    patched["clients"] = [dict(client, keepAlive=25) for client in clients]
    current = settings
    current_mtu = current.get("mtu")
    if current_mtu is None:
        current_mtu = (current.get("server") or {}).get("mtu")
    if (
        current_mtu == target_mtu
        and (current.get("server") or {}).get("s1") == server.get("s1")
        and (current.get("server") or {}).get("randomTrailers") == server.get("randomTrailers")
    ):
        log.log("INFO", "AmneziaWG profile already matches desired hygiene (mtu/S/trailers).")
        return
    components = current_inbound_components_json(inbound)
    components["settings"] = patched
    if plan_or_apply(mode, stats, f"AmneziaWG profile synced id={amneziawg_id} mtu={mtu} trailers=on"):
        api.update_inbound(amneziawg_id, components)
        if not api.session.success_json():
            raise InboundApplyError(
                f"Inbound update failed id={amneziawg_id}: {api.session.body()}"
            )
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
