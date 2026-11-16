"""Apply managed Xray template (bash ``lib/xray_runtime.bash`` parity, mockable probes)."""

from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.http_client import HttpSession
from xui_runtime.json_state import (
    apply_geodata_block,
    apply_managed_xray_state,
    geodata_outbound_tag,
    json_equal,
    remove_managed_xray_artifacts,
)

_GEODATA_DEFAULT_RESOURCES = """geosite|geosite_refilter|https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat
geosite|geosite_v2fly|https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
geosite|geosite_zkeen|https://github.com/jameszeroX/zkeen-domains/releases/latest/download/zkeen.dat
geoip|geoip_zkeenip|https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat
geoip|geoip_v2fly|https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
geoip|geoip_refilter|https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geoip.dat
geosite|adlist|https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat
geosite|geosite_RU|https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
"""

_FALLBACK_DNS_SERVERS = [
    "https://dns10.quad9.net/dns-query",
    "https://dns.alidns.com/dns-query",
    "https://doh.sandbox.opendns.com/dns-query",
    "https://freedns.controld.com/p0",
    "https://doh.dns.sb/dns-query",
    "https://dns.google/dns-query",
    "https://dns.nextdns.io",
    "https://dns.quad9.net/dns-query",
    "https://dns11.quad9.net/dns-query",
    "https://dns.rabbitdns.org/dns-query",
    "https://basic.rethinkdns.com/",
    "https://wikimedia-dns.org/dns-query",
    "https://doh.libredns.gr/dns-query",
    "https://doh.libredns.gr/ads",
    "https://dns.twnic.tw/dns-query",
    "https://dns.switch.ch/dns-query",
    "tls://dns.alidns.com",
    "tls://sandbox.opendns.com",
    "tls://p0.freedns.controld.com",
    "tls://dot.sb",
    "tls://dns.google",
    "tls://dns.mullvad.net",
    "tls://dns.nextdns.io",
    "tls://dns.quad9.net",
    "tls://dns11.quad9.net",
    "tls://dot.libredns.gr",
]


def _env_bool(env: Mapping[str, str], key: str, default: bool = False) -> bool:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_str(env: Mapping[str, str], key: str, default: str = "") -> str:
    value = env.get(key)
    if value is None or value == "":
        return default
    return value


def _env_int(env: Mapping[str, str], key: str, default: int) -> int:
    raw = _env_str(env, key, "")
    if not raw:
        return default
    return int(raw)


def geodata_resources_json(custom_geo_resources: str | None = None) -> list[dict[str, str]]:
    text = (custom_geo_resources or "").strip()
    if not text:
        text = _GEODATA_DEFAULT_RESOURCES
    resources: list[dict[str, str]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split("|", 2)]
        if len(parts) < 3:
            continue
        typ, alias, url = parts[0], parts[1], parts[2]
        if typ and alias and url:
            resources.append({"type": typ, "alias": alias, "url": url})
    return resources


def geodata_assets_json(resources: list[dict[str, str]] | None = None) -> list[dict[str, str]]:
    if resources is None:
        resources = geodata_resources_json()
    return [{"url": item["url"], "file": f"{item['alias']}.dat"} for item in resources]


def default_tcp_endpoint_available(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def default_available_dns_servers() -> list[dict[str, Any]]:
    if default_tcp_endpoint_available("adguard", 53, 2.0):
        return [{"address": "adguard", "port": 53, "skipFallback": False}]
    return [{"address": address, "skipFallback": False} for address in _FALLBACK_DNS_SERVERS]


def extract_warp_obj(payload: Mapping[str, Any]) -> dict[str, Any] | None:
    raw = payload.get("obj")
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None
    if isinstance(raw, dict):
        return dict(raw)
    return None


def warp_config_json_from_obj(obj: Mapping[str, Any]) -> dict[str, Any]:
    config = obj.get("config")
    if isinstance(config, dict):
        nested = config.get("config")
        if isinstance(nested, dict):
            return dict(nested)
        return dict(config)
    return {}


def warp_reserved_json_from_config(config: Mapping[str, Any]) -> list[int] | None:
    client_id = (
        config.get("client_id")
        or (config.get("config") or {}).get("client_id")
        or ((config.get("config") or {}).get("config") or {}).get("client_id")
    )
    if not client_id or not isinstance(client_id, str):
        return None
    try:
        decoded = base64.b64decode(client_id)
    except (ValueError, TypeError):
        return None
    nbytes = decoded[:3]
    if len(nbytes) != 3:
        return None
    return [int(b) for b in nbytes]


def warp_outbound_from_config(
    config: Mapping[str, Any],
    private_key: str,
    reserved_json: list[int] | None = None,
) -> dict[str, Any] | None:
    reserved = reserved_json if reserved_json is not None else [10, 14, 188]
    iface = config.get("interface") or (config.get("config") or {}).get("interface") or {}
    addresses = iface.get("addresses") or {}
    v4 = addresses.get("v4") or ""
    v6 = addresses.get("v6") or ""
    peers = config.get("peers") or (config.get("config") or {}).get("peers") or []
    if not peers:
        return None
    peer = peers[0]
    peer_pub = peer.get("public_key") or peer.get("publicKey") or ""
    endpoint_host = (peer.get("endpoint") or {}).get("host")
    if not endpoint_host:
        ep = (peer.get("endpoint") or {}).get("v4")
        if ep:
            endpoint_host = f"{str(ep).split(':')[0]}:2408"
    endpoint = endpoint_host or _env_str(os.environ, "WARP_ENDPOINT_HOST", "engage.cloudflareclient.com:2408")
    if not endpoint:
        endpoint = "engage.cloudflareclient.com:2408"
    config_reserved = warp_reserved_json_from_config(config)
    if config_reserved is not None:
        reserved = config_reserved
    if not peer_pub or not private_key:
        return None

    def fmt_addr(addr: str) -> str:
        if not addr:
            return ""
        return f"{addr}/128" if ":" in addr else f"{addr}/32"

    address_list = [fmt_addr(v4), fmt_addr(v6)]
    address_list = [a for a in address_list if a]
    return {
        "tag": "warp",
        "protocol": "wireguard",
        "settings": {
            "mtu": 1420,
            "secretKey": private_key,
            "address": address_list,
            "numWorkers": 2,
            "workers": 2,
            "domainStrategy": "ForceIP",
            "reserved": reserved,
            "peers": [
                {
                    "publicKey": peer_pub,
                    "public_key": peer_pub,
                    "allowedIPs": ["0.0.0.0/0", "::/0"],
                    "allowedIps": ["0.0.0.0/0", "::/0"],
                    "endpoint": endpoint,
                    "keepAlive": 0,
                }
            ],
            "isClient": True,
            "noKernelTun": False,
        },
    }


def normalize_warp_outbound_endpoint(
    outbound: dict[str, Any],
    env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    env = env or os.environ
    endpoint = _env_str(env, "WARP_ENDPOINT_HOST", "engage.cloudflareclient.com:2408")
    if outbound.get("tag") != "warp" or outbound.get("protocol") != "wireguard":
        return outbound
    updated = dict(outbound)
    settings = dict(updated.get("settings") or {})
    peers = [dict(peer) for peer in settings.get("peers") or []]
    for peer in peers:
        peer["endpoint"] = endpoint
    settings["peers"] = peers
    updated["settings"] = settings
    return updated


def _find_xray_bin(env: Mapping[str, str]) -> str | None:
    candidates = [
        _env_str(env, "XRAY_BIN_PATH", ""),
        f"{_env_str(env, 'XUI_BIN_FOLDER', '/app/bin')}/xray-linux-amd64",
        f"{_env_str(env, 'XUI_BIN_FOLDER', '/app/bin')}/xray",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def generate_wg_keys(env: Mapping[str, str]) -> tuple[str, str, list[int]]:
    xray_bin = _find_xray_bin(env)
    if not xray_bin:
        raise RuntimeError("Failed to find xray binary for WARP registration.")
    proc = subprocess.run(
        [xray_bin, "wg"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError("Failed to run xray wg for WARP registration.")
    private_key = ""
    public_key = ""
    hash32 = ""
    for line in proc.stdout.splitlines():
        if ": " not in line:
            continue
        label, value = line.split(": ", 1)
        if label == "PrivateKey":
            private_key = value.strip()
        elif label == "PublicKey":
            public_key = value.strip()
        elif label == "Password" and not public_key:
            public_key = value.strip()
        elif label == "Hash32":
            hash32 = value.strip()
    reserved = [10, 14, 188]
    if hash32:
        try:
            decoded = base64.b64decode(hash32)[:3]
            if len(decoded) == 3:
                reserved = [int(b) for b in decoded]
        except (ValueError, TypeError):
            pass
    if not private_key or not public_key:
        raise RuntimeError("xray wg did not return WARP keys.")
    return private_key, public_key, reserved


def _existing_warp_console_outbound(current: dict[str, Any]) -> dict[str, Any] | None:
    outbounds = (current.get("xraySetting") or {}).get("outbounds") or []
    for item in outbounds:
        if item.get("tag") == "warp" and item.get("protocol") == "wireguard":
            return dict(item)
    return None


def ensure_warp_console_outbound(
    api: PanelApi,
    session: HttpSession,
    current: dict[str, Any],
    *,
    env: Mapping[str, str],
    mode: str,
) -> dict[str, Any] | None:
    existing = _existing_warp_console_outbound(current)
    if existing is not None:
        result = api.warp_config()
        if result.code == "200" and session.success_json():
            try:
                payload = json.loads(session.body())
            except json.JSONDecodeError:
                payload = {}
            obj = extract_warp_obj(payload) or {}
            if obj:
                config = warp_config_json_from_obj(obj)
                private_key = (existing.get("settings") or {}).get("secretKey") or ""
                if private_key:
                    built = warp_outbound_from_config(config, str(private_key))
                    if built:
                        return built
        return normalize_warp_outbound_endpoint(existing, env)

    if _env_bool(env, "WARP_REUSE_PANEL_CONFIG", False):
        result = api.warp_config()
        if result.code == "200" and session.success_json():
            try:
                payload = json.loads(session.body())
            except json.JSONDecodeError:
                payload = {}
            obj = extract_warp_obj(payload) or {}
            if obj:
                config = warp_config_json_from_obj(obj)
                private_key = (
                    config.get("interface", {}).get("private_key")
                    or (config.get("config") or {}).get("interface", {}).get("private_key")
                    or config.get("privateKey")
                    or ""
                )
                if private_key:
                    built = warp_outbound_from_config(config, str(private_key))
                    if built:
                        return built

    if mode == "plan":
        log.log("INFO", "PLAN: WARP console registration would be requested.")
        return None

    private_key, public_key, reserved = generate_wg_keys(env)
    result = api.warp_register(public_key, private_key)
    if result.code != "200" or not session.success_json():
        raise RuntimeError("WARP registration API failed")
    try:
        payload = json.loads(session.body())
    except json.JSONDecodeError as exc:
        raise RuntimeError("WARP registration response is not JSON") from exc
    obj = extract_warp_obj(payload)
    if not obj:
        raise RuntimeError("WARP registration response has no obj.")
    config = warp_config_json_from_obj(obj)
    outbound = warp_outbound_from_config(config, private_key, reserved)
    if not outbound:
        raise RuntimeError("Failed to build WARP outbound from registration response.")
    log.log("INFO", "WARP registered through panel API.")
    return outbound


def _parse_xray_settings_body(session: HttpSession) -> dict[str, Any]:
    try:
        payload = json.loads(session.body())
    except json.JSONDecodeError as exc:
        raise RuntimeError("Xray settings response is not JSON") from exc
    raw = payload.get("obj")
    if isinstance(raw, str):
        return json.loads(raw)
    if isinstance(raw, dict):
        return dict(raw)
    return {}


def _xray_update_payload(updated: dict[str, Any]) -> dict[str, Any]:
    xs = updated.get("xraySetting")
    if not isinstance(xs, dict):
        xs = {}
    payload = dict(xs)
    payload.setdefault("xrayTemplateConfig", {})
    return payload


@dataclass
class ApplyXrayStats:
    changed: bool = False
    applied: bool = False
    restart_panel_required: bool = False
    restart_xray_required: bool = False
    plan_messages: list[str] = field(default_factory=list)


@dataclass
class XrayApplyProbes:
    warp_proxy_available: Callable[[str, int], bool] | None = None
    tor_proxy_available: Callable[[str, int], bool] | None = None
    tcp_endpoint_available: Callable[[str, int, float], bool] | None = None
    available_dns_servers: Callable[[], list[dict[str, Any]]] | None = None


def apply_managed_xray(
    api: PanelApi,
    env: Mapping[str, str],
    desired: Mapping[str, Any] | None,
    mode: str,
    *,
    session: HttpSession | None = None,
    probes: XrayApplyProbes | None = None,
) -> ApplyXrayStats:
    """Reconcile panel Xray template with managed DNS/WARP/TOR/Mihomo/geodata state."""
    _ = desired  # reserved for future declarative overrides; bash path uses env flags.
    session = session or api.session
    probes = probes or XrayApplyProbes()

    tcp_probe = probes.tcp_endpoint_available or default_tcp_endpoint_available
    dns_probe = probes.available_dns_servers or default_available_dns_servers
    warp_probe = probes.warp_proxy_available
    tor_probe = probes.tor_proxy_available

    managed_enabled = any(
        _env_bool(env, key, False)
        for key in (
            "XRAY_MANAGED_DNS",
            "XRAY_MANAGED_TOR",
            "XRAY_MANAGED_WARP",
            "ENABLE_MIHOMO",
        )
    )

    stats = ApplyXrayStats()
    result = api.get_xray_settings()
    if not result.ok or result.code != "200" or not session.success_json():
        raise RuntimeError("Failed to get Xray settings from panel API")

    current = _parse_xray_settings_body(session)

    usque_host = _env_str(env, "USQUE_HOST", "usque")
    usque_port = _env_int(env, "USQUE_PORT", 1080)
    tor_host = _env_str(env, "TOR_PROXY_HOST", "tor-proxy")
    tor_port = _env_int(env, "TOR_PROXY_PORT", 1080)
    mihomo_host = _env_str(env, "MIHOMO_PROXY_HOST", "mihomo")
    mihomo_port = _env_int(env, "MIHOMO_PROXY_PORT", 7890)
    mihomo_timeout = float(_env_str(env, "MIHOMO_PROXY_PROBE_TIMEOUT", "2") or "2")
    webdomain = _env_str(env, "WEBDOMAIN", "")

    warp_endpoints: list[dict[str, Any]] = []
    if warp_probe is None:
        warp_probe = lambda _h, _p: False  # noqa: E731
    if warp_probe(usque_host, usque_port):
        warp_endpoints.append(
            {"tag": "usque", "host": usque_host, "port": usque_port}
        )

    mihomo_endpoints: list[dict[str, Any]] = []
    if tcp_probe(mihomo_host, mihomo_port, mihomo_timeout):
        mihomo_endpoints.append(
            {"tag": "mihomo", "host": mihomo_host, "port": mihomo_port}
        )

    warp_console_ob: dict[str, Any] | None = None

    if managed_enabled:
        if _env_bool(env, "XRAY_MANAGED_WARP", False) and _env_bool(
            env, "XRAY_MANAGED_WARP_CONSOLE", False
        ):
            warp_console_ob = ensure_warp_console_outbound(
                api, session, current, env=env, mode=mode
            )
        elif _env_bool(env, "XRAY_MANAGED_WARP", False):
            log.log(
                "INFO",
                "Console WARP outbound is disabled; managed WARP balancer "
                "will use external SOCKS outbounds only.",
            )

        updated = remove_managed_xray_artifacts(current)

        tor_available = False
        tor_endpoints: list[dict[str, Any]] = []
        if _env_bool(env, "XRAY_MANAGED_TOR", False):
            if tor_probe is not None and tor_probe(tor_host, tor_port):
                tor_available = True
                tor_endpoints.append(
                    {"tag": "tor-proxy", "host": tor_host, "port": tor_port}
                )
            else:
                log.log(
                    "INFO",
                    f"{tor_host}:{tor_port} did not confirm IsTor=true; "
                    "excluding tor-proxy from Xray managed state.",
                )

        if _env_bool(env, "XRAY_MANAGED_WARP", False) and not warp_endpoints:
            log.log(
                "INFO",
                f"{usque_host}:{usque_port} did not confirm warp=on; "
                "excluding usque from Xray managed state.",
            )

        if _env_bool(env, "ENABLE_MIHOMO", False) and not mihomo_endpoints:
            log.log(
                "INFO",
                f"{mihomo_host}:{mihomo_port} is not reachable; "
                "excluding mihomo from Xray managed state.",
            )

        dns_servers = dns_probe()
        updated = apply_managed_xray_state(
            updated,
            dns_servers,
            _env_bool(env, "XRAY_MANAGED_WARP", False),
            tor_available,
            _env_bool(env, "XRAY_MANAGED_DNS", False),
            warp_endpoints,
            webdomain,
            tor_endpoints,
            warp_console_ob or "",
            _env_bool(env, "ENABLE_MIHOMO", False),
            mihomo_endpoints,
        )
    else:
        updated = remove_managed_xray_artifacts(current)

    custom_geo = _env_str(env, "CUSTOM_GEO_RESOURCES", "")
    assets = geodata_assets_json(geodata_resources_json(custom_geo or None))
    outbound_tag = geodata_outbound_tag(warp_endpoints, mihomo_endpoints)
    cron = _env_str(env, "GEODATA_CRON", "0 4 * * *")
    updated = apply_geodata_block(updated, outbound_tag, assets, cron)

    stats.changed = not json_equal(current, updated)
    if not stats.changed:
        log.log("INFO", "Xray settings already match managed desired state.")
        return stats

    plan_message = "xray settings updated"
    if mode == "plan":
        stats.plan_messages.append(f"PLAN: {plan_message}")
        log.log("INFO", f"PLAN: {plan_message}")
        return stats

    obj = _xray_update_payload(updated)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".json",
        delete=False,
    ) as handle:
        json.dump(obj, handle, ensure_ascii=False)
        tmp_path = handle.name

    try:
        post = api.update_xray_settings(tmp_path)
        if not post.ok or post.code != "200" or not session.success_json():
            raise RuntimeError("Xray update failed")
    finally:
        Path(tmp_path).unlink(missing_ok=True)

    stats.applied = True
    stats.restart_panel_required = True
    stats.restart_xray_required = True
    return stats