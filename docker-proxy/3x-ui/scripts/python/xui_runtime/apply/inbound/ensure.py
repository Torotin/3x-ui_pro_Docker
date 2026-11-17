"""Inbound ensure: create/delete inbounds, streams, TLS (library-only)."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import secrets
import time
from collections.abc import Mapping, Sequence
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.builders.inbounds import (
    build_amneziawg_settings_json,
    build_hysteria2_settings_json,
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
from xui_runtime.common import ApplyStats, api_obj_json, plan_or_apply
from xui_runtime.crypto_cmd import openssl_self_signed_cert
from xui_runtime.desired import inbound_remark_slug

_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


_UUID32_RE = re.compile(
    r"^[0-9a-f]{12}[1-8][0-9a-f]{3}[89ab][0-9a-f]{15}$"
)


class InboundApplyError(RuntimeError):
    """Inbound apply could not complete."""


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
