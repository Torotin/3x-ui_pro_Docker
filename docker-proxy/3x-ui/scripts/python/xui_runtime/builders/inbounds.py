"""Inbound settings JSON builders matching bash inbound_runtime.bash."""

from __future__ import annotations

import re
import secrets
from collections.abc import Mapping
from typing import Any

from xui_runtime.desired import build_desired_state
from xui_runtime.env import resolve_awg_mtu


def _parse_subnet(subnet: str) -> tuple[str, int]:
    match = re.match(r"^([0-9a-fA-F:.]+)/([0-9]+)$", subnet)
    if not match:
        return "10.8.1.0", 24
    return match.group(1), int(match.group(2))


def _env_bool(env: Mapping[str, str], key: str, default: bool = False) -> bool:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return str(raw).strip().lower() in ("1", "true", "yes", "on")


def build_amneziawg_settings_json(
    desired: Mapping[str, Any] | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    env_map: Mapping[str, str] = env or {}
    if desired is None:
        desired = build_desired_state(env_map)
    awg = desired.get("inbounds", {}).get("amneziawg", {})
    mtu = resolve_awg_mtu(env_map)
    subnet = awg.get("subnet", "10.8.1.0/24")
    dns1 = awg.get("dns1", "8.8.8.8")
    dns2 = awg.get("dns2", "8.8.4.4")
    subnet_ip, subnet_cidr = _parse_subnet(str(subnet))
    server: dict[str, Any] = {
        "mtu": mtu,
        "subnetIp": subnet_ip,
        "subnetCidr": subnet_cidr,
        "primaryDns": dns1,
        "secondaryDns": dns2,
        "s1": int(env_map.get("AWG_S1") or 16),
        "s2": int(env_map.get("AWG_S2") or 16),
        "s3": int(env_map.get("AWG_S3") or 16),
        "s4": int(env_map.get("AWG_S4") or 16),
        "h1": (env_map.get("AWG_H1") or "1").strip(),
        "h2": (env_map.get("AWG_H2") or "2").strip(),
        "h3": (env_map.get("AWG_H3") or "3").strip(),
        "h4": (env_map.get("AWG_H4") or "4").strip(),
        "jc": int(env_map.get("AWG_JC") or 4),
        "jmin": int(env_map.get("AWG_JMIN") or 50),
        "jmax": int(env_map.get("AWG_JMAX") or 120),
        "contentPaddingAddition": (env_map.get("AWG_CONTENT_PADDING") or "0-16").strip(),
        "keepaliveTimeout": (env_map.get("AWG_KEEPALIVE_TIMEOUT") or "9-17").strip(),
        "randomTrailers": _env_bool(env_map, "AWG_RANDOM_TRAILERS", True),
        "disableCookies": _env_bool(env_map, "AWG_DISABLE_COOKIES", False),
        "i1": (env_map.get("AWG_I1") or "<r 55>").strip(),
    }
    for idx, key in enumerate(("AWG_I2", "AWG_I3", "AWG_I4", "AWG_I5"), start=2):
        val = (env_map.get(key) or "").strip()
        if val:
            server[f"i{idx}"] = val
    for env_key, field in (
        ("AWG_REKEY_AFTER_TIME", "rekeyAfterTime"),
        ("AWG_REKEY_TIMEOUT", "rekeyTimeout"),
        ("AWG_REJECT_AFTER_TIME", "rejectAfterTime"),
        ("AWG_MAX_HANDSHAKE_ATTEMPTS", "maxHandshakeAttempts"),
    ):
        val = (env_map.get(env_key) or "").strip()
        if val:
            server[field] = val
    return {
        "mtu": mtu,
        "subnet": subnet,
        "subnetIp": subnet_ip,
        "subnetCidr": subnet_cidr,
        "dns1": dns1,
        "dns2": dns2,
        "server": server,
    }


def _normalize_tg_id(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    text = str(value) if value is not None else ""
    if not text:
        return 0
    try:
        return int(text)
    except ValueError:
        return 0


def new_client_secret() -> str:
    return secrets.token_hex(8)


def build_hysteria2_settings_json(
    current: Mapping[str, Any] | None = None,
    desired: Mapping[str, Any] | None = None,
    preferred_auth: str = "",
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    if desired is None:
        desired = build_desired_state(env)
    clients: list[dict[str, Any]] = []
    if current:
        settings = current.get("settings")
        if isinstance(settings, str):
            import json

            settings = json.loads(settings)
        if isinstance(settings, dict):
            raw_clients = settings.get("clients")
            if isinstance(raw_clients, list):
                clients = [dict(c) for c in raw_clients]

    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    if env is None:
        import os

        env = os.environ
    legacy_email = env.get("CLIENT_EMAIL_LEGACY", "autogen")
    hysteria_override = env.get("CLIENT_EMAIL_HYSTERIA2", "")
    legacy_hysteria = hysteria_override or f"{legacy_email}-hysteria2"

    auth = ""
    for client in clients:
        if client.get("email") == email:
            auth = str(client.get("auth") or "")
            if auth:
                break
    if not auth:
        auth = preferred_auth
    if not auth:
        auth = new_client_secret()

    new_client = {
        "auth": auth,
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

    filtered: list[dict[str, Any]] = []
    for client in clients:
        client_email = client.get("email")
        if client_email in (email, legacy_email, legacy_hysteria):
            continue
        normalized = dict(client)
        normalized["tgId"] = _normalize_tg_id(client.get("tgId"))
        filtered.append(normalized)
    filtered.append(new_client)

    return {
        "version": 2,
        "clients": filtered,
    }