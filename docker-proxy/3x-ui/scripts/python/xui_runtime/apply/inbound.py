"""Inbound apply (bash ``inbound_runtime.bash`` parity, library-only)."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.inbounds import (
    _normalize_tg_id,
    build_amneziawg_settings_json,
    build_hysteria2_settings_json,
    new_client_secret,
)
from xui_runtime.builders.streams import (
    build_grpc_stream_json,
    build_hysteria2_stream_json,
    build_sockopt_json,
    build_vision_stream_json,
    build_xhttp_stream_json,
    select_tls_fingerprint,
    tls_fingerprint_allowed,
    xray_trusted_xff_header,
)
from xui_runtime.common import ApplyStats, api_obj_json, json_equal, plan_or_apply
from xui_runtime.crypto_cmd import openssl_self_signed_cert
from xui_runtime.desired import build_desired_state, inbound_remark_slug

_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_UUID32_RE = re.compile(
    r"^[0-9a-f]{12}[1-8][0-9a-f]{3}[89ab][0-9a-f]{15}$"
)


class InboundApplyError(RuntimeError):
    """Inbound apply could not complete."""


@dataclass
class SharedClientSecrets:
    client_id: str = ""
    password: str = ""
    auth: str = ""


def _env_str(env: Mapping[str, str], key: str, default: str = "") -> str:
    value = env.get(key)
    if value is None or value == "":
        return default
    return value


def _env_bool(env: Mapping[str, str], key: str, default: bool = False) -> bool:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _default_tls_paths(env: Mapping[str, str]) -> tuple[str, str]:
    domain = _env_str(env, "WEBDOMAIN", "localhost") or "localhost"
    cert = _env_str(
        env,
        "XRAY_TLS_CERT_FILE",
        f"/etc/traefik/pem/{domain}-cert.pem",
    )
    key = _env_str(
        env,
        "XRAY_TLS_KEY_FILE",
        f"/etc/traefik/pem/{domain}-key.pem",
    )
    return cert, key


def json_field_object(obj: Mapping[str, Any], field: str) -> dict[str, Any]:
    raw = obj.get(field)
    if isinstance(raw, dict):
        return dict(raw)
    if isinstance(raw, str) and raw:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        if isinstance(parsed, dict):
            return parsed
    return {}


def legacy_managed_inbound_remark(kind: str) -> str:
    return f"managed:{inbound_remark_slug(kind)}"


def managed_inbound_remarks(kind: str, desired: Mapping[str, Any]) -> list[str]:
    desired_remark = desired["inbounds"][kind]["remark"]
    legacy = legacy_managed_inbound_remark(kind)
    if kind == "mixed":
        return list(
            dict.fromkeys(
                [desired_remark, legacy, "telemt-egress", "managed:telemt-egress"]
            )
        )
    if kind == "amneziawg":
        return list(dict.fromkeys([desired_remark, legacy, "awg-spike-443"]))
    return [desired_remark, legacy]


def _remark_managed(remark: str, expected: Sequence[str]) -> bool:
    if remark in expected:
        return True
    return any(expected_remark in remark for expected_remark in expected if expected_remark)


def new_uuid(env: Mapping[str, str]) -> str:
    proc_path = "/proc/sys/kernel/random/uuid"
    if os.path.isfile(proc_path):
        with open(proc_path, encoding="utf-8") as handle:
            return handle.read().strip()
    # Fallback matches bash jq sha256 shortcut when /proc unavailable.
    blob = f"{time.time()}".encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:32]


def normalize_uuid(value: str) -> str | None:
    text = (value or "").strip().lower()
    if not text:
        return None
    if _UUID_RE.match(text):
        return text
    if _UUID32_RE.match(text):
        return (
            f"{text[0:8]}-{text[8:12]}-{text[12:16]}-{text[16:20]}-{text[20:32]}"
        )
    return None


def _list_inbounds(api: PanelApi) -> list[dict[str, Any]]:
    api.list_inbounds()
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound list API failed: {api.session.body()}")
    try:
        payload = json.loads(api.session.body())
    except json.JSONDecodeError as exc:
        raise InboundApplyError("Inbound list response is not JSON.") from exc
    obj = payload.get("obj")
    if isinstance(obj, list):
        return [dict(item) for item in obj if isinstance(item, dict)]
    return []


def find_inbound_by_port(
    inbounds: Sequence[Mapping[str, Any]],
    port: int,
    protocol: str,
) -> str:
    for inbound in inbounds:
        try:
            inbound_port = int(inbound.get("port", -1))
        except (TypeError, ValueError):
            continue
        if inbound_port == port and inbound.get("protocol") == protocol:
            inbound_id = inbound.get("id")
            if inbound_id is not None:
                return str(inbound_id)
    return ""


def managed_conflict_check(
    inbound: Mapping[str, Any] | None,
    expected_remarks: Sequence[str],
    port: int,
) -> None:
    if not inbound:
        return
    remark = str(inbound.get("remark") or "")
    if _remark_managed(remark, expected_remarks):
        return
    raise InboundApplyError(
        f"Inbound port {port} is occupied by unmanaged inbound remark={remark!r}. "
        "Refusing to overwrite."
    )


def client_vless_uuid(client: Mapping[str, Any], *, include_auth: bool = True) -> str | None:
    fields = ("uuid", "id", "password", "auth") if include_auth else ("uuid", "id")
    for field in fields:
        normalized = normalize_uuid(str(client.get(field) or ""))
        if normalized:
            return normalized
    return None


def inbound_vless_client_uuid(
    api: PanelApi,
    inbound_id: str | int,
    email: str,
) -> str | None:
    if not inbound_id or not email:
        return None
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        return None
    inbound = api_obj_json(api.session)
    settings = json_field_object(inbound, "settings")
    for client in settings.get("clients") or []:
        if client.get("email") != email:
            continue
        for field in ("uuid", "id", "auth", "password"):
            normalized = normalize_uuid(str(client.get(field) or ""))
            if normalized:
                return normalized
    return None


_MANAGED_VLESS_CLIENT_KEYS = (
    "id",
    "uuid",
    "email",
    "subId",
    "flow",
    "enable",
    "limitIp",
    "totalGB",
    "expiryTime",
    "tgId",
)


def _normalize_empty_default(value: Any) -> Any:
    if value is None:
        return ""
    return value


def managed_vless_client_projection(client: Mapping[str, Any]) -> dict[str, Any]:
    """Project fields AfterStart owns; drop empty panel defaults that cause churn."""
    out: dict[str, Any] = {}
    for key in _MANAGED_VLESS_CLIENT_KEYS:
        if key in client:
            out[key] = client.get(key)
    for key in ("password", "auth"):
        raw = _normalize_empty_default(client.get(key))
        if str(raw).strip() != "":
            out[key] = raw
    if "uuid" not in out and "id" in out:
        out["uuid"] = out["id"]
    if "id" not in out and "uuid" in out:
        out["id"] = out["uuid"]
    out["tgId"] = _normalize_tg_id(out.get("tgId", 0))
    return out


def _vless_settings_without_clients(settings: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in settings.items() if key != "clients"}


def _sorted_vless_client_projections(
    settings: Mapping[str, Any],
) -> list[dict[str, Any]]:
    clients = settings.get("clients") or []
    projected = [managed_vless_client_projection(client) for client in clients]
    return sorted(projected, key=lambda row: str(row.get("email") or ""))


def vless_inbound_settings_match(
    current: Mapping[str, Any],
    desired: Mapping[str, Any],
) -> bool:
    if not json_equal(
        _vless_settings_without_clients(current),
        _vless_settings_without_clients(desired),
    ):
        return False
    return json_equal(
        _sorted_vless_client_projections(current),
        _sorted_vless_client_projections(desired),
    )


def _vless_client_field_for_compare(
    secrets: SharedClientSecrets | None,
    inbound_client: Mapping[str, Any] | None,
    field: str,
) -> str:
    if inbound_client is not None and field in inbound_client:
        return str(inbound_client.get(field) or "")
    if secrets:
        value = getattr(secrets, field, "") or ""
        if str(value).strip():
            return str(value)
    return ""


def _vless_client_field_for_write(
    secrets: SharedClientSecrets | None,
    inbound_client: Mapping[str, Any] | None,
    field: str,
) -> str:
    if secrets:
        value = getattr(secrets, field, "") or ""
        if str(value).strip():
            return str(value)
    if inbound_client is not None:
        value = str(inbound_client.get(field) or "").strip()
        if value:
            return value
    return new_client_secret()


def vless_client_api_json(
    client_id: str,
    email: str,
    sub_id: str,
    flow: str,
    password: str = "",
    auth: str = "",
) -> dict[str, Any]:
    return {
        "id": client_id,
        "uuid": client_id,
        "password": password,
        "auth": auth,
        "flow": flow,
        "security": "auto",
        "email": email,
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "reset": 0,
        "tgId": 0,
        "group": "",
        "comment": "",
        "enable": True,
        "subId": sub_id,
    }


def vless_client_create_payload_json(
    inbound_ids: Sequence[int],
    client: Mapping[str, Any],
) -> dict[str, Any]:
    return {"client": dict(client), "inboundIds": [int(x) for x in inbound_ids]}


def current_inbound_components_json(inbound: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "up": inbound.get("up") or 0,
        "down": inbound.get("down") or 0,
        "total": inbound.get("total") or 0,
        "remark": inbound.get("remark") or "",
        "enable": inbound.get("enable", True),
        "expiryTime": inbound.get("expiryTime") or 0,
        "listen": inbound.get("listen") or "",
        "port": int(inbound.get("port", 0)),
        "protocol": inbound.get("protocol") or "",
        "settings": json_field_object(inbound, "settings"),
        "streamSettings": json_field_object(inbound, "streamSettings"),
        "sniffing": json_field_object(inbound, "sniffing"),
        "allocate": json_field_object(inbound, "allocate"),
    }


def _strip_removed_xray_stream_fields(obj: Any) -> Any:
    if isinstance(obj, dict):
        cleaned = {
            key: _strip_removed_xray_stream_fields(value)
            for key, value in obj.items()
            if key not in ("allowInsecure", "penetrate")
        }
        return cleaned
    if isinstance(obj, list):
        return [_strip_removed_xray_stream_fields(item) for item in obj]
    return obj


def sanitize_vision_stream_json(stream: Mapping[str, Any], env: Mapping[str, str]) -> dict[str, Any]:
    sanitized = _strip_removed_xray_stream_fields(copy.deepcopy(stream))
    reality = sanitized.get("realitySettings") or {}
    settings = reality.get("settings") or {}
    fingerprint = str(settings.get("fingerprint") or "")
    if not tls_fingerprint_allowed(fingerprint):
        fingerprint = select_tls_fingerprint()
    target_host = _env_str(env, "REALITY_TARGET_HOST") or _env_str(
        env, "VISION_FALLBACK_HOST", "telemt"
    )
    target_port = (
        _env_str(env, "REALITY_TARGET_PORT")
        or _env_str(env, "VISION_FALLBACK_PORT")
        or _env_str(env, "PORT_LOCAL_TELEMT_PROXY", "9443")
    )
    target = f"{target_host}:{target_port}"
    xver = int(
        _env_str(env, "REALITY_TARGET_XVER")
        or _env_str(env, "VISION_FALLBACK_XVER", "1")
    )
    if isinstance(reality, dict):
        reality.pop("maxTimediff", None)
        reality.pop("dest", None)
        reality["maxTimeDiff"] = reality.get(
            "maxTimeDiff", reality.get("maxTimediff", 0)
        )
        reality["target"] = target
        reality["xver"] = xver
        settings["fingerprint"] = fingerprint
        reality["settings"] = settings
        sanitized["realitySettings"] = reality
    return sanitized


def _sanitize_external_proxy_tls(
    stream: Mapping[str, Any],
    host: str,
    alpn: Sequence[str],
) -> dict[str, Any]:
    sanitized = _strip_removed_xray_stream_fields(copy.deepcopy(stream))
    proxy = sanitized.get("externalProxy") or []
    first = dict(proxy[0]) if proxy else {}
    fingerprint = str(first.get("fingerprint") or "")
    if not tls_fingerprint_allowed(fingerprint):
        fingerprint = select_tls_fingerprint()
    entry: dict[str, Any] = {
        **first,
        "forceTls": "tls",
        "dest": host,
        "port": 443,
        "remark": "",
        "sni": host,
        "fingerprint": fingerprint,
    }
    if alpn:
        entry["alpn"] = list(alpn)
    sanitized["externalProxy"] = [entry]
    return sanitized


def sanitize_xhttp_stream_json(
    stream: Mapping[str, Any],
    path: str,
    host: str,
    env: Mapping[str, str],
) -> dict[str, Any]:
    sanitized = _sanitize_external_proxy_tls(stream, host, ["h2", "http/1.1"])
    sanitized["network"] = "xhttp"
    sanitized["security"] = "none"
    xhttp = dict(sanitized.get("xhttpSettings") or {})
    xhttp["path"] = path
    xhttp["host"] = host
    sanitized["xhttpSettings"] = xhttp
    trusted = [xray_trusted_xff_header(env)]
    sockopt = dict(sanitized.get("sockopt") or {})
    sockopt["trustedXForwardedFor"] = trusted
    sanitized["sockopt"] = sockopt
    return sanitized


def sanitize_grpc_stream_json(
    stream: Mapping[str, Any],
    path: str,
    host: str,
    cert_file: str,
    key_file: str,
    env: Mapping[str, str],
) -> dict[str, Any]:
    service_name = path.lstrip("/").rstrip("/")
    sanitized = _sanitize_external_proxy_tls(stream, host, ["h2"])
    tls = dict(sanitized.get("tlsSettings") or {})
    settings = dict(tls.get("settings") or {})
    fingerprint = str(
        settings.get("fingerprint")
        or (sanitized.get("externalProxy") or [{}])[0].get("fingerprint")
        or ""
    )
    if not tls_fingerprint_allowed(fingerprint):
        fingerprint = select_tls_fingerprint()
    tls.setdefault("minVersion", "1.2")
    tls.setdefault("maxVersion", "1.3")
    tls["serverName"] = host
    tls["alpn"] = ["h2"]
    tls["certificates"] = [
        {
            "certificateFile": cert_file,
            "keyFile": key_file,
            "oneTimeLoading": False,
            "usage": "encipherment",
        }
    ]
    settings["fingerprint"] = fingerprint
    tls["settings"] = settings
    sanitized["tlsSettings"] = tls
    if sanitized.get("externalProxy"):
        sanitized["externalProxy"][0]["fingerprint"] = fingerprint
    grpc = dict(sanitized.get("grpcSettings") or {})
    grpc["serviceName"] = service_name
    grpc.setdefault("authority", "")
    grpc.setdefault("multiMode", False)
    sanitized["grpcSettings"] = grpc
    sanitized["network"] = "grpc"
    sanitized["security"] = "tls"
    trusted = [xray_trusted_xff_header(env)]
    sockopt = dict(sanitized.get("sockopt") or {})
    sockopt["trustedXForwardedFor"] = trusted
    sanitized["sockopt"] = sockopt
    return sanitized


def generate_short_ids_json(count: int = 8, max_bytes: int = 8) -> list[str]:
    ids: list[str] = []
    for _ in range(count):
        length = 2 + secrets.randbelow(max(1, max_bytes - 1))
        ids.append(secrets.token_hex(length))
    return ids


def _get_vless_auth(api: PanelApi, env: Mapping[str, str]) -> tuple[str, str, str]:
    if not _env_bool(env, "USE_VLESS_PQ", default=True):
        return "none", "none", ""
    api.get_vless_enc()
    if not api.session.success_json():
        log.log("WARN", "VLESS auth API failed; falling back to none.")
        return "none", "none", ""
    try:
        payload = json.loads(api.session.body())
    except json.JSONDecodeError:
        return "none", "none", ""
    obj = payload.get("obj") or {}
    auths = obj.get("auths") or []
    picked: dict[str, Any] | None = None
    for entry in auths:
        if not isinstance(entry, dict):
            continue
        label = str(entry.get("label") or "").lower()
        if "post-quantum" in label or "ml-kem" in label:
            picked = entry
            break
    if picked is None and auths and isinstance(auths[0], dict):
        picked = auths[0]
    if not picked:
        return "none", "none", ""
    return (
        str(picked.get("decryption") or "none"),
        str(picked.get("encryption") or "none"),
        str(picked.get("label") or ""),
    )


def _get_x25519_keys(api: PanelApi) -> tuple[str, str]:
    api.get_x25519()
    if not api.session.success_json():
        raise InboundApplyError("Failed to get X25519 keys for Vision inbound.")
    obj = api_obj_json(api.session)
    private_key = str(obj.get("privateKey") or "")
    public_key = str(obj.get("publicKey") or "")
    if not private_key or not public_key:
        raise InboundApplyError("X25519 API returned empty keys.")
    return private_key, public_key


def build_vless_settings_json(
    kind: str,
    current: Mapping[str, Any] | None,
    *,
    api: PanelApi | None,
    env: Mapping[str, str],
) -> dict[str, Any]:
    clients: list[dict[str, Any]] = []
    dec = enc = label = ""
    if current:
        existing = json_field_object(current, "settings")
        raw_clients = existing.get("clients")
        if isinstance(raw_clients, list):
            clients = [dict(item) for item in raw_clients]
        dec = str(existing.get("decryption") or "")
        enc = str(existing.get("encryption") or "")
        label = str(existing.get("selectedAuth") or "")
    if (not dec or not enc) and api is not None:
        fetched_dec, fetched_enc, fetched_label = _get_vless_auth(api, env)
        dec = dec or fetched_dec
        enc = enc or fetched_enc
        label = label or fetched_label
    if not _env_bool(env, "USE_VLESS_PQ", default=True):
        dec, enc, label = "none", "none", ""
    fallback_host = _env_str(env, "VISION_FALLBACK_HOST", "telemt")
    fallback_port = _env_str(
        env, "VISION_FALLBACK_PORT", _env_str(env, "PORT_LOCAL_TELEMT_PROXY", "9443")
    )
    fallback_dest = f"{fallback_host}:{fallback_port}"
    fallback_xver = int(_env_str(env, "VISION_FALLBACK_XVER", "1"))
    if kind == "vision":
        return {
            "clients": clients,
            "decryption": "none",
            "encryption": "none",
            "fallbacks": [{"dest": fallback_dest, "xver": fallback_xver}],
        }
    if kind == "grpc":
        return {
            "clients": clients,
            "decryption": "none",
            "encryption": "none",
        }
    body: dict[str, Any] = {
        "clients": clients,
        "decryption": dec or "none",
        "encryption": enc or "none",
    }
    if label:
        body["selectedAuth"] = label
    return body


def build_inbound_stream_json(
    kind: str,
    env: Mapping[str, str],
    *,
    current: Mapping[str, Any] | None = None,
    api: PanelApi | None = None,
    hysteria_auth: str = "",
) -> dict[str, Any]:
    cert_file, key_file = _default_tls_paths(env)
    domain = _env_str(env, "WEBDOMAIN", "localhost") or "localhost"
    if current:
        stream = json_field_object(current, "streamSettings")
        if kind == "vision":
            return sanitize_vision_stream_json(stream, env)
        if kind == "xhttp":
            path = _env_str(env, "URI_VLESS_XHTTP", "/xhttp") or "/xhttp"
            return sanitize_xhttp_stream_json(stream, path, domain, env)
        if kind == "grpc":
            path = _env_str(env, "URI_VLESS_GRPC", "/grpc") or "/grpc"
            return sanitize_grpc_stream_json(stream, path, domain, cert_file, key_file, env)

    if kind == "vision":
        if api is None:
            raise InboundApplyError("Vision inbound create requires PanelApi for X25519.")
        private_key, public_key = _get_x25519_keys(api)
        target_host = _env_str(env, "REALITY_TARGET_HOST", "telemt")
        target_port = _env_str(
            env, "REALITY_TARGET_PORT", _env_str(env, "PORT_LOCAL_TELEMT_PROXY", "9443")
        )
        target = f"{target_host}:{target_port}"
        xver = int(_env_str(env, "REALITY_TARGET_XVER", "1"))
        sockopt = build_sockopt_json(False, "AsIs", "off")
        return build_vision_stream_json(
            target=target,
            sni=domain,
            private_key=private_key,
            public_key=public_key,
            short_ids=generate_short_ids_json(),
            sockopt=sockopt,
            target_xver=xver,
        )
    if kind == "xhttp":
        path = _env_str(env, "URI_VLESS_XHTTP", "/xhttp") or "/xhttp"
        return build_xhttp_stream_json(path, domain, env=env)
    if kind == "grpc":
        path = _env_str(env, "URI_VLESS_GRPC", "/grpc") or "/grpc"
        return build_grpc_stream_json(path, domain, cert_file, key_file, env=env)
    if kind == "hysteria2":
        return build_hysteria2_stream_json(domain, cert_file, key_file, auth=hysteria_auth, env=env)
    if kind == "amneziawg":
        return {}
    if kind == "mixed":
        return {"network": "tcp", "security": "none"}
    raise InboundApplyError(f"Unsupported inbound kind: {kind}")


def build_inbound_components_json(
    kind: str,
    desired: Mapping[str, Any],
    env: Mapping[str, str],
    *,
    current: Mapping[str, Any] | None = None,
    api: PanelApi | None = None,
    shared_auth: str = "",
) -> dict[str, Any]:
    port = int(desired["inbounds"][kind]["port"])
    remark = desired["inbounds"][kind]["remark"]
    protocol = desired["inbounds"][kind]["protocol"]
    hysteria_auth = ""
    if kind == "hysteria2":
        settings = build_hysteria2_settings_json(current, desired, preferred_auth=shared_auth, env=env)
        hysteria_auth = str((settings.get("clients") or [{}])[0].get("auth") or "")
    elif kind == "amneziawg":
        settings = build_amneziawg_settings_json(desired, env)
    elif kind == "mixed":
        settings = {"auth": "noauth", "udp": True, "accounts": []}
    else:
        settings = build_vless_settings_json(kind, current, api=api, env=env)
    stream = build_inbound_stream_json(
        kind,
        env,
        current=current,
        api=api,
        hysteria_auth=hysteria_auth,
    )
    if kind == "amneziawg":
        sniffing: dict[str, Any] = {}
    elif kind == "hysteria2":
        sniffing = {
            "enabled": False,
            "destOverride": ["http", "tls", "quic", "fakedns"],
            "metadataOnly": False,
            "routeOnly": True,
        }
    elif kind == "mixed":
        sniffing = {
            "enabled": True,
            "destOverride": ["http", "tls", "quic", "fakedns"],
            "metadataOnly": False,
            "routeOnly": True,
        }
    else:
        sniffing = {
            "enabled": True,
            "destOverride": ["http", "tls", "quic", "fakedns"],
            "metadataOnly": False,
            "routeOnly": True,
        }
    # Mixed listens on all interfaces (bash ensure_inbound listen=0.0.0.0).
    listen = "0.0.0.0" if kind == "mixed" else ""
    return {
        "up": 0,
        "down": 0,
        "total": 0,
        "remark": remark,
        "enable": True,
        "expiryTime": 0,
        "listen": listen,
        "port": port,
        "protocol": protocol,
        "settings": settings,
        "streamSettings": stream,
        "sniffing": sniffing,
        "allocate": {},
    }


def ensure_xray_tls_certificate(
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    cert_file, key_file = _default_tls_paths(env)
    if os.path.isfile(cert_file) and os.path.getsize(cert_file) > 0:
        if os.path.isfile(key_file) and os.path.getsize(key_file) > 0:
            return
    traefik_prefix = "/etc/traefik/pem/"
    if cert_file.startswith(traefik_prefix) or key_file.startswith(traefik_prefix):
        if mode == "plan":
            plan_or_apply(mode, stats, "Traefik PEM missing; self-signed fallback under /etc/x-ui")
            return
        log.log(
            "WARN",
            f"Traefik PEM missing (cert={cert_file} key={key_file}); "
            "using self-signed /etc/x-ui/xray-managed.{crt,key}",
        )
        cert_file = "/etc/x-ui/xray-managed.crt"
        key_file = "/etc/x-ui/xray-managed.key"
        env = dict(env)
        env["XRAY_TLS_CERT_FILE"] = cert_file
        env["XRAY_TLS_KEY_FILE"] = key_file
        if os.path.isfile(cert_file) and os.path.getsize(cert_file) > 0:
            if os.path.isfile(key_file) and os.path.getsize(key_file) > 0:
                return
    if mode == "plan":
        plan_or_apply(mode, stats, "Xray TLS certificate generated at configured paths")
        return
    if mode != "apply":
        return
    openssl_bin = _env_str(env, "OPENSSL_BIN", "openssl")
    days = int(_env_str(env, "XRAY_TLS_SELF_SIGNED_DAYS", "3650"))
    cn = _env_str(env, "WEBDOMAIN", "localhost") or "localhost"
    os.makedirs(os.path.dirname(cert_file), exist_ok=True)
    os.makedirs(os.path.dirname(key_file), exist_ok=True)
    plan_or_apply(mode, stats, "Xray TLS certificate generated at configured paths")
    openssl_self_signed_cert(openssl_bin, key_file, cert_file, days=days, cn=cn)
    try:
        os.chmod(key_file, 0o600)
        os.chmod(cert_file, 0o644)
    except OSError:
        pass


def ensure_inbound(
    kind: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> str | None:
    inbounds = _list_inbounds(api)
    port = int(desired["inbounds"][kind]["port"])
    protocol = desired["inbounds"][kind]["protocol"]
    expected = managed_inbound_remarks(kind, desired)
    inbound_id = find_inbound_by_port(inbounds, port, protocol)
    if not inbound_id and kind == "hysteria2":
        inbound_id = find_inbound_by_port(inbounds, port, "hysteria2")
    current = next(
        (row for row in inbounds if str(row.get("id")) == inbound_id),
        None,
    )
    managed_conflict_check(current, expected, port)
    if inbound_id:
        log.log(
            "INFO",
            f"{kind} inbound already exists id={inbound_id} port={port}; "
            "preserving existing configuration.",
        )
        return inbound_id
    components = build_inbound_components_json(kind, desired, env, api=api)
    if mode == "plan":
        plan_or_apply(mode, stats, f"{kind} inbound created port={port}")
        return None
    plan_or_apply(mode, stats, f"{kind} inbound created port={port}")
    api.add_inbound(components)
    if not api.session.success_json():
        raise InboundApplyError(f"{kind} inbound add failed: {api.session.body()}")
    obj = api_obj_json(api.session)
    created_id = obj.get("id")
    stats.restart_xray_required = True
    return str(created_id) if created_id is not None else None


def delete_managed_inbound_kind(
    kind: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    mode: str,
    stats: ApplyStats,
) -> None:
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
        return
    current = next(
        (row for row in inbounds if str(row.get("id")) == inbound_id),
        None,
    )
    remark = str((current or {}).get("remark") or "")
    if remark not in expected:
        log.log("WARN", f"skip delete id={inbound_id} remark={remark} (not managed {kind})")
        return
    if mode == "plan":
        plan_or_apply(mode, stats, f"delete managed {kind} inbound id={inbound_id}")
        return
    plan_or_apply(mode, stats, f"delete managed {kind} inbound id={inbound_id}")
    api.del_inbound(inbound_id)
    if not api.session.success_json():
        raise InboundApplyError(f"delete {kind} failed: {api.session.body()}")
    stats.restart_xray_required = True


def _list_clients(api: PanelApi) -> list[dict[str, Any]]:
    api.list_clients()
    if not api.session.success_json():
        raise InboundApplyError(f"Client list API failed: {api.session.body()}")
    try:
        payload = json.loads(api.session.body())
    except json.JSONDecodeError as exc:
        raise InboundApplyError("Client list response is not JSON.") from exc
    obj = payload.get("obj")
    if isinstance(obj, list):
        return [dict(item) for item in obj if isinstance(item, dict)]
    return []


def _target_inbound_ids(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    hysteria2_id: str,
    amneziawg_id: str,
) -> list[int]:
    ids: list[int] = []
    for value in (vision_id, xhttp_id, grpc_id, hysteria2_id, amneziawg_id):
        text = (value or "").strip()
        if not text:
            continue
        ids.append(int(text))
    return ids


def _client_needs_update(
    current: Mapping[str, Any],
    sub_id: str,
    flow: str,
    password: str,
    auth: str,
) -> bool:
    return not (
        str(current.get("subId") or "") == sub_id
        and str(current.get("flow") or "") == flow
        and str(current.get("password") or "") == password
        and str(current.get("auth") or "") == auth
    )


def ensure_shared_client(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    hysteria2_id: str,
    amneziawg_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    secrets: SharedClientSecrets | None = None,
) -> SharedClientSecrets:
    bucket = secrets if secrets is not None else SharedClientSecrets()
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    flow = desired["clients"]["shared"]["flow"]
    target_ids = _target_inbound_ids(
        vision_id, xhttp_id, grpc_id, hysteria2_id, amneziawg_id
    )
    clients = _list_clients(api)
    current = next((row for row in clients if row.get("email") == email), None)

    created = False
    if current is None:
        client_id = str(uuid.uuid4())
        password = new_client_secret()
        auth = new_client_secret()
        client = vless_client_api_json(client_id, email, sub_id, flow, password, auth)
        bucket.client_id, bucket.password, bucket.auth = client_id, password, auth
        target_text = ",".join(str(x) for x in target_ids)
        if mode == "plan":
            plan_or_apply(mode, stats, f"shared client created email={email} inbounds={target_text}")
            return bucket
        plan_or_apply(mode, stats, f"shared client created email={email} inbounds={target_text}")
        api.add_client(vless_client_create_payload_json(target_ids, client))
        if not api.session.success_json():
            raise InboundApplyError(f"shared client add failed: {api.session.body()}")
        repair_shared_client_db(
            email,
            client_id,
            sub_id,
            flow,
            password,
            auth,
            env=env,
            mode=mode,
        )
        stats.restart_xray_required = True
        current = {
            "email": email,
            "subId": sub_id,
            "sub_id": sub_id,
            "uuid": client_id,
            "id": client_id,
            "password": password,
            "auth": auth,
            "flow": flow,
            "inboundIds": target_ids,
        }
        created = True
    else:
        client_id = client_vless_uuid(current, include_auth=False) or ""
        if not client_id:
            client_id = (
                inbound_vless_client_uuid(api, vision_id, email)
                or inbound_vless_client_uuid(api, xhttp_id, email)
                or ""
            )
        if not client_id:
            client_id = client_vless_uuid(current) or ""
        if not client_id:
            client_id = str(uuid.uuid4())
            log.log(
                "WARN",
                f"Existing shared client email={email} has no valid VLESS UUID; "
                "generating a replacement.",
            )
        password = str(current.get("password") or "") or new_client_secret()
        auth = str(current.get("auth") or "") or new_client_secret()
        bucket.client_id, bucket.password, bucket.auth = client_id, password, auth
        client = vless_client_api_json(client_id, email, sub_id, flow, password, auth)
        if _client_needs_update(current, sub_id, flow, password, auth):
            if plan_or_apply(mode, stats, f"shared client updated email={email}"):
                api.update_client(email, client)
                if not api.session.success_json():
                    raise InboundApplyError(
                        f"shared client update failed: {api.session.body()}"
                    )
                repair_shared_client_db(
                    email, client_id, sub_id, flow, password, auth, env=env, mode=mode
                )
                stats.restart_xray_required = True
        repair_shared_client_db(
            email, client_id, sub_id, flow, password, auth, env=env, mode=mode
        )

    if not created:
        current_ids = {int(x) for x in (current.get("inboundIds") or [])}
        missing = [inbound_id for inbound_id in target_ids if inbound_id not in current_ids]
        if missing:
            attach_text = ",".join(str(x) for x in missing)
            if plan_or_apply(
                mode,
                stats,
                f"shared client attached email={email} inbounds={attach_text}",
            ):
                api.attach_client(email, {"inboundIds": missing})
                if not api.session.success_json():
                    raise InboundApplyError(
                        f"shared client attach failed: {api.session.body()}"
                    )
                stats.restart_xray_required = True
        else:
            attached = ",".join(str(x) for x in target_ids)
            log.log(
                "INFO",
                f"shared client already attached email={email} inbounds={attached}.",
            )

    vision_flow = desired["clients"]["shared"]["visionFlow"]
    xhttp_flow = desired["clients"]["shared"]["xhttpFlow"]
    ensure_vless_inbound_client(
        vision_id,
        bucket.client_id,
        desired,
        vision_flow,
        "Vision",
        api,
        env,
        mode,
        stats,
        secrets=bucket,
    )
    ensure_vless_inbound_client(
        xhttp_id,
        bucket.client_id,
        desired,
        xhttp_flow,
        "XHTTP",
        api,
        env,
        mode,
        stats,
        secrets=bucket,
    )
    ensure_vless_stream(vision_id, "vision", "Vision", api, env, mode, stats)
    ensure_vless_stream(xhttp_id, "xhttp", "XHTTP", api, env, mode, stats)
    return bucket


def _legacy_emails(env: Mapping[str, str]) -> tuple[str, str]:
    legacy = env.get("CLIENT_EMAIL_LEGACY", "autogen")
    hysteria_override = env.get("CLIENT_EMAIL_HYSTERIA2", "")
    legacy_hysteria = hysteria_override or f"{legacy}-hysteria2"
    return legacy, legacy_hysteria


def ensure_vless_inbound_client(
    inbound_id: str,
    client_id: str,
    desired: Mapping[str, Any],
    flow: str,
    label: str,
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    secrets: SharedClientSecrets | None = None,
) -> None:
    if not inbound_id:
        return
    if not client_id:
        log.log("WARN", f"Skipping {label} VLESS client sync because shared client id is unknown.")
        return
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={inbound_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    current_settings = json_field_object(inbound, "settings")
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    legacy, legacy_hysteria = _legacy_emails(env)
    existing_managed = next(
        (
            client
            for client in current_settings.get("clients") or []
            if client.get("email") == email
        ),
        None,
    )
    password = _vless_client_field_for_compare(secrets, existing_managed, "password")
    auth = _vless_client_field_for_compare(secrets, existing_managed, "auth")
    desired_client = vless_client_api_json(
        client_id, email, sub_id, "", password, auth
    )
    desired_client["flow"] = flow
    filtered: list[dict[str, Any]] = []
    for client in current_settings.get("clients") or []:
        client_email = client.get("email")
        if client_email in (email, legacy, legacy_hysteria):
            continue
        normalized = dict(client)
        normalized["tgId"] = _normalize_tg_id(client.get("tgId"))
        filtered.append(normalized)
    filtered.append(desired_client)
    desired_settings = {**current_settings, "decryption": "none", "encryption": "none", "clients": filtered}
    if vless_inbound_settings_match(current_settings, desired_settings):
        log.log("INFO", f"{label} VLESS inbound client already matches desired state.")
        return
    write_password = _vless_client_field_for_write(secrets, existing_managed, "password")
    write_auth = _vless_client_field_for_write(secrets, existing_managed, "auth")
    if write_password != password or write_auth != auth:
        desired_client = vless_client_api_json(
            client_id, email, sub_id, "", write_password, write_auth
        )
        desired_client["flow"] = flow
        filtered[-1] = desired_client
        desired_settings = {
            **current_settings,
            "decryption": "none",
            "encryption": "none",
            "clients": filtered,
        }
    components = current_inbound_components_json(inbound)
    components["settings"] = desired_settings
    if plan_or_apply(mode, stats, f"{label} VLESS inbound client synchronized"):
        api.update_inbound(inbound_id, components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={inbound_id}: {api.session.body()}")
        stats.restart_xray_required = True


def ensure_vless_stream(
    inbound_id: str,
    kind: str,
    label: str,
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if not inbound_id:
        return
    api.get_inbound(inbound_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={inbound_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    desired_stream = build_inbound_stream_json(kind, env, current=inbound, api=api)
    components = current_inbound_components_json(inbound)
    desired_components = {**components, "streamSettings": desired_stream}
    if json_equal(components, desired_components):
        log.log("INFO", f"{label} stream already matches desired state.")
        return
    if plan_or_apply(mode, stats, f"{label} stream synchronized"):
        api.update_inbound(inbound_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={inbound_id}: {api.session.body()}")
        stats.restart_xray_required = True


def ensure_grpc_client(
    grpc_id: str,
    client_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    secrets: SharedClientSecrets | None = None,
) -> None:
    grpc_flow = desired["clients"]["shared"].get("grpcFlow", "")
    ensure_vless_inbound_client(
        grpc_id,
        client_id,
        desired,
        grpc_flow,
        "gRPC",
        api,
        env,
        mode,
        stats,
        secrets=secrets,
    )
    if not grpc_id:
        return
    api.get_inbound(grpc_id)
    if not api.session.success_json():
        raise InboundApplyError(f"Inbound get failed id={grpc_id}: {api.session.body()}")
    inbound = api_obj_json(api.session)
    desired_stream = build_inbound_stream_json("grpc", env, current=inbound, api=api)
    components = current_inbound_components_json(inbound)
    desired_components = {**components, "streamSettings": desired_stream}
    if json_equal(components, desired_components):
        log.log("INFO", "gRPC stream already matches desired state.")
        return
    if plan_or_apply(mode, stats, "gRPC stream synchronized"):
        api.update_inbound(grpc_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(f"Inbound update failed id={grpc_id}: {api.session.body()}")
        stats.restart_xray_required = True


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
    patched["mtu"] = desired_settings.get("mtu", mtu)
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
    patched["server"] = server
    clients = patched.get("clients") or []
    patched["clients"] = [dict(client, keepAlive=25) for client in clients]
    current = settings
    if (
        current.get("mtu") == patched.get("mtu")
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


def ensure_hysteria2_client(
    hysteria2_id: str,
    desired: Mapping[str, Any],
    api: PanelApi,
    env: Mapping[str, str],
    mode: str,
    stats: ApplyStats,
    *,
    shared_auth: str = "",
) -> None:
    if not hysteria2_id:
        return
    api.get_inbound(hysteria2_id)
    if not api.session.success_json():
        raise InboundApplyError(
            f"Inbound get failed id={hysteria2_id}: {api.session.body()}"
        )
    inbound = api_obj_json(api.session)
    desired_settings = build_hysteria2_settings_json(
        inbound, desired, preferred_auth=shared_auth, env=env
    )
    hysteria_auth = str((desired_settings.get("clients") or [{}])[0].get("auth") or "")
    desired_stream = build_inbound_stream_json(
        "hysteria2",
        env,
        current=inbound,
        hysteria_auth=hysteria_auth,
    )
    components = current_inbound_components_json(inbound)
    desired_components = {
        **components,
        "protocol": desired["inbounds"]["hysteria2"]["protocol"],
        "settings": desired_settings,
        "streamSettings": desired_stream,
    }
    if json_equal(components, desired_components):
        log.log("INFO", "Hysteria2 inbound client already matches desired state.")
        return
    if plan_or_apply(mode, stats, "Hysteria2 inbound client synchronized"):
        api.update_inbound(hysteria2_id, desired_components)
        if not api.session.success_json():
            raise InboundApplyError(
                f"Inbound update failed id={hysteria2_id}: {api.session.body()}"
            )
        stats.restart_xray_required = True


def _db_path(env: Mapping[str, str]) -> str:
    return env.get("XUI_DB_PATH") or "/etc/x-ui/x-ui.db"


def repair_shared_client_db(
    email: str,
    client_id: str,
    sub_id: str,
    flow: str,
    password: str,
    auth: str,
    *,
    env: Mapping[str, str],
    mode: str,
) -> None:
    if mode != "apply":
        return
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return
    sql = (
        "pragma busy_timeout=5000; "
        "update clients set uuid=?, password=?, auth=?, flow=?, sub_id=? "
        "where email=?;"
    )
    for _attempt in range(5):
        try:
            con = sqlite3.connect(db_path, timeout=10.0)
            try:
                con.execute(
                    sql,
                    (client_id, password, auth, flow, sub_id, email),
                )
                con.commit()
                return
            finally:
                con.close()
        except sqlite3.Error:
            time.sleep(0.2)
    log.log("WARN", f"Managed client DB repair skipped email={email}; sqlite update failed.")


def repair_inbound_client_tg_ids_db(
    *,
    env: Mapping[str, str],
    mode: str,
) -> int:
    if mode != "apply":
        return 0
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return 0
    changed = 0
    con = sqlite3.connect(db_path, timeout=10.0)
    try:
        cur = con.cursor()
        for inbound_id, settings_text in cur.execute("select id, settings from inbounds"):
            if not settings_text:
                continue
            try:
                obj = json.loads(settings_text)
            except json.JSONDecodeError:
                continue
            dirty = False
            for client in obj.get("clients") or []:
                tg = client.get("tgId", 0)
                if isinstance(tg, str):
                    text = tg.strip()
                    client["tgId"] = int(text) if text.lstrip("-").isdigit() else 0
                    dirty = True
                elif tg is None:
                    client["tgId"] = 0
                    dirty = True
            if dirty:
                cur.execute(
                    "update inbounds set settings=? where id=?",
                    (json.dumps(obj, separators=(",", ":")), inbound_id),
                )
                changed += 1
        con.commit()
    finally:
        con.close()
    if changed:
        log.log(
            "INFO",
            f"Normalized string tgId values in {changed} inbound settings row(s).",
        )
    return changed


def repair_inbound_vless_client_flows_db(
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    desired: Mapping[str, Any],
    *,
    env: Mapping[str, str],
    mode: str,
) -> int:
    if mode != "apply":
        return 0
    db_path = _db_path(env)
    if not os.path.isfile(db_path) or os.path.getsize(db_path) == 0:
        return 0
    email = desired["clients"]["shared"]["email"]
    targets: list[tuple[int, str]] = []
    flows = {
        "vision": desired["clients"]["shared"]["visionFlow"],
        "xhttp": desired["clients"]["shared"]["xhttpFlow"],
        "grpc": desired["clients"]["shared"].get("grpcFlow", ""),
    }
    for inbound_id, flow_key in (
        (vision_id, flows["vision"]),
        (xhttp_id, flows["xhttp"]),
        (grpc_id, flows["grpc"]),
    ):
        text = (inbound_id or "").strip()
        if not text:
            continue
        targets.append((int(text), flow_key))
    changed = 0
    con = sqlite3.connect(db_path, timeout=10.0)
    try:
        cur = con.cursor()
        for inbound_id, flow in targets:
            row = cur.execute(
                "select settings from inbounds where id=?", (inbound_id,)
            ).fetchone()
            if not row or not row[0]:
                continue
            try:
                obj = json.loads(row[0])
            except json.JSONDecodeError:
                continue
            dirty = False
            for client in obj.get("clients") or []:
                if client.get("email") != email:
                    continue
                if (client.get("flow") or "") != flow:
                    client["flow"] = flow
                    dirty = True
            if dirty:
                cur.execute(
                    "update inbounds set settings=? where id=?",
                    (json.dumps(obj, separators=(",", ":")), inbound_id),
                )
                changed += 1
        con.commit()
    finally:
        con.close()
    if changed:
        log.log("INFO", f"Repaired VLESS client flow in {changed} inbound settings row(s).")
    return changed


def repair_shared_client_after_inbound_sync(
    desired: Mapping[str, Any],
    vision_id: str,
    xhttp_id: str,
    grpc_id: str,
    secrets: SharedClientSecrets,
    *,
    env: Mapping[str, str],
    mode: str,
) -> None:
    if not secrets.client_id:
        return
    email = desired["clients"]["shared"]["email"]
    sub_id = desired["clients"]["shared"]["subId"]
    flow = desired["clients"]["shared"]["flow"]
    repair_shared_client_db(
        email,
        secrets.client_id,
        sub_id,
        flow,
        secrets.password,
        secrets.auth,
        env=env,
        mode=mode,
    )
    repair_inbound_vless_client_flows_db(
        vision_id,
        xhttp_id,
        grpc_id,
        desired,
        env=env,
        mode=mode,
    )