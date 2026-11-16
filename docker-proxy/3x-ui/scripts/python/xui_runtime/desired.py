"""Declarative desired state for 3x-ui panel / inbounds (bash parity)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from xui_runtime.env import deterministic_sub_id

_DEFAULT_EMOJI_FLAG = "\u26a0"

_INBOUND_SLUGS: dict[str, str] = {
    "vision": "vless-tcp-reality",
    "xhttp": "vless-xhttp",
    "grpc": "vless-grpc-tls",
    "hysteria2": "hysteria2",
    "amneziawg": "amneziawg",
    "mixed": "mixed-docker-net",
}


def inbound_remark_slug(kind: str) -> str:
    """Stable slug suffix for a managed inbound kind."""
    try:
        return _INBOUND_SLUGS[kind]
    except KeyError as exc:
        raise ValueError(f"unknown inbound kind: {kind}") from exc


def country_code_to_flag(code: str) -> str:
    """Convert ISO 3166-1 alpha-2 code to regional-indicator flag emoji."""
    if not code or len(code) != 2 or not code.isalpha():
        raise ValueError(f"invalid country code: {code!r}")
    upper = code.upper()
    return "".join(chr(ord(ch) + 127397) for ch in upper)


def inbound_remark(kind: str, emoji_flag: str | None = None) -> str:
    """Display remark: flag + slug (matches bash ``inbound_remark``)."""
    flag = emoji_flag if emoji_flag is not None else _DEFAULT_EMOJI_FLAG
    return f"{flag} {inbound_remark_slug(kind)}"


def _env_str(env: Mapping[str, str], key: str, default: str = "") -> str:
    value = env.get(key)
    if value is None or value == "":
        return default
    return value


def _env_int(env: Mapping[str, str], key: str, default: str) -> int:
    return int(_env_str(env, key, default))


def _shared_email_prefix(env: Mapping[str, str]) -> str:
    explicit = _env_str(env, "CLIENT_EMAIL_PREFIX")
    if explicit:
        return explicit
    webdomain = _env_str(env, "WEBDOMAIN")
    if webdomain:
        return f"{webdomain}-autogen"
    return "autogen"


def _udp443_port(env: Mapping[str, str]) -> int:
    raw = env.get("PORT_LOCAL_UDP443") or env.get("PORT_LOCAL_HYSTERIA") or "443"
    return int(raw)


def build_desired_state(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Build desired-state dict matching bash ``build_desired_state`` jq output."""
    if env is None:
        import os

        env = os.environ

    prefix = _shared_email_prefix(env)
    shared_email = _env_str(env, "CLIENT_EMAIL_SHARED", prefix)
    sub_id = _env_str(env, "CLIENT_SUB_ID")
    if not sub_id:
        webdomain = _env_str(env, "WEBDOMAIN", "localhost")
        sub_id = deterministic_sub_id(webdomain, shared_email)

    tls_domain = _env_str(env, "WEBDOMAIN", "localhost") or "localhost"
    emoji_flag = env.get("EMOJI_FLAG")
    if emoji_flag is None or emoji_flag == "":
        emoji_flag = _DEFAULT_EMOJI_FLAG

    xray_tls_cert = _env_str(
        env,
        "XRAY_TLS_CERT_FILE",
        f"/etc/traefik/pem/{tls_domain}-cert.pem",
    )
    xray_tls_key = _env_str(
        env,
        "XRAY_TLS_KEY_FILE",
        f"/etc/traefik/pem/{tls_domain}-key.pem",
    )

    udp443 = _udp443_port(env)

    return {
        "panel": {
            "webListen": _env_str(env, "webListen", "0.0.0.0"),
            "webDomain": _env_str(env, "webDomain"),
            "webPort": _env_str(env, "webPort", "2053"),
            "webBasePath": _env_str(env, "webBasePath"),
        },
        "inbounds": {
            "vision": {
                "managed": True,
                "protocol": "vless",
                "port": _env_int(env, "PORT_LOCAL_VISION", "443"),
                "remark": inbound_remark("vision", emoji_flag),
            },
            "xhttp": {
                "managed": True,
                "protocol": "vless",
                "port": _env_int(env, "PORT_LOCAL_XHTTP", "8443"),
                "remark": inbound_remark("xhttp", emoji_flag),
                "path": _env_str(env, "URI_VLESS_XHTTP", "/xhttp"),
            },
            "grpc": {
                "managed": True,
                "protocol": "vless",
                "port": _env_int(env, "PORT_LOCAL_GRPC", "9444"),
                "remark": inbound_remark("grpc", emoji_flag),
                "path": _env_str(env, "URI_VLESS_GRPC", "/grpc"),
            },
            "hysteria2": {
                "managed": True,
                "protocol": "hysteria",
                "port": udp443,
                "remark": inbound_remark("hysteria2", emoji_flag),
            },
            "amneziawg": {
                "managed": True,
                "protocol": "amneziawg",
                "port": udp443,
                "remark": inbound_remark("amneziawg", emoji_flag),
                "subnet": "10.8.1.0/24",
                "mtu": 1280,
                "dns1": "8.8.8.8",
                "dns2": "8.8.4.4",
            },
            "mixed": {
                "managed": True,
                "protocol": "mixed",
                "port": _env_int(env, "PORT_LOCAL_XRAY_MIXED", "10808"),
                "remark": inbound_remark("mixed", emoji_flag),
            },
        },
        "clients": {
            "shared": {
                "email": shared_email,
                "subId": sub_id,
                "flow": "xtls-rprx-vision",
                "visionFlow": "xtls-rprx-vision",
                "xhttpFlow": "",
                "grpcFlow": "",
            },
        },
        "tls": {
            "certFile": xray_tls_cert,
            "keyFile": xray_tls_key,
        },
        "integrations": {
            "warp": {"enabled": True},
            "tor": {"enabled": True},
        },
        "xray": {
            "domain": _env_str(env, "WEBDOMAIN"),
            "dns": {"managed": True},
            "routing": {"managed": True},
            "outbounds": {"managed": True},
        },
    }