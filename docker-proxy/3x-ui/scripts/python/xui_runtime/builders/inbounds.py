"""Inbound settings JSON builders matching bash inbound_runtime.bash."""

from __future__ import annotations

import re
import secrets
from collections.abc import Mapping
from typing import Any

from xui_runtime.desired import build_desired_state


def _parse_subnet(subnet: str) -> tuple[str, int]:
    match = re.match(r"^([0-9a-fA-F:.]+)/([0-9]+)$", subnet)
    if not match:
        return "10.8.1.0", 24
    return match.group(1), int(match.group(2))


def build_amneziawg_settings_json(
    desired: Mapping[str, Any] | None = None,
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    if desired is None:
        desired = build_desired_state(env)
    awg = desired.get("inbounds", {}).get("amneziawg", {})
    mtu = awg.get("mtu", 1280)
    subnet = awg.get("subnet", "10.8.1.0/24")
    dns1 = awg.get("dns1", "8.8.8.8")
    dns2 = awg.get("dns2", "8.8.4.4")
    subnet_ip, subnet_cidr = _parse_subnet(str(subnet))
    return {
        "mtu": mtu,
        "subnet": subnet,
        "subnetIp": subnet_ip,
        "subnetCidr": subnet_cidr,
        "dns1": dns1,
        "dns2": dns2,
        "server": {
            "mtu": mtu,
            "subnetIp": subnet_ip,
            "subnetCidr": subnet_cidr,
            "primaryDns": dns1,
            "secondaryDns": dns2,
            "s1": 16,
            "s2": 16,
            "s3": 16,
            "s4": 16,
            "h1": "1",
            "h2": "2",
            "h3": "3",
            "h4": "4",
            "jc": 4,
            "jmin": 50,
            "jmax": 120,
            "contentPaddingAddition": "0-16",
            "keepaliveTimeout": "9-17",
            "randomTrailers": True,
            "disableCookies": False,
            "i1": "<r 55>",
        },
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