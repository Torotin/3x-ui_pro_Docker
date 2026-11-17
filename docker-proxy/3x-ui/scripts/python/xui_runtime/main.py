"""CLI entry and AfterStart orchestrator (bash ``3x-ui-upd.sh`` ``main()`` parity)."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from xui_runtime import log
from xui_runtime.api import PanelApi
from xui_runtime.apply.inbound import (
    SharedClientSecrets,
    delete_managed_inbound_kind,
    ensure_grpc_client,
    ensure_grpc_when_disabled,
    ensure_hysteria2_client,
    ensure_inbound,
    ensure_shared_client,
    ensure_xray_tls_certificate,
    find_inbound_by_port,
    repair_inbound_client_tg_ids_db,
    repair_shared_client_after_inbound_sync,
    sync_amneziawg_profile,
)
from xui_runtime.apply.panel import (
    ensure_panel_settings,
    restart_panel_if_needed,
    update_admin_credentials_if_needed,
)
from xui_runtime.apply.sub_balancer import ensure_auto_sub_balancer
from xui_runtime.apply.xhttp_extra import ensure_xhttp_client_extra
from xui_runtime.apply.sub_routing import (
    admin_sub_clash_default_mode,
    build_admin_sub_clash_rules,
    build_admin_sub_json_dns,
    build_admin_sub_json_rules,
    build_mihomo_client_sub_clash_rules,
    clash_subscription_proxy_name_for_kind,
    discover_clash_proxy_node_names,
    mihomo_client_routing_file,
    subscription_panel_env_overrides,
    subscription_url_for_sub_id,
)
from xui_runtime.apply.xray import (
    ApplyXrayStats,
    XrayApplyProbes,
    apply_managed_xray,
    default_tor_proxy_available,
    default_warp_proxy_available,
)
from xui_runtime.common import ApplyStats
from xui_runtime.desired import build_desired_state, country_code_to_flag
from xui_runtime.env import (
    check_dependencies,
    load_runtime_env,
    require_apply_mode,
    resolve_afterstart_dir,
)
from xui_runtime.http_client import HttpSession

PYTHON_RUNTIME_READY = True

_COUNTRY_FLAG_SOURCES: tuple[tuple[str, str, str], ...] = (
    ("http://1.1.1.1/cdn-cgi/trace", "", "trace_loc"),
    ("http://1.0.0.1/cdn-cgi/trace", "", "trace_loc"),
    ("https://ipwho.is/", ".flag.emoji", "emoji"),
    ("https://ipwhois.io/json/", ".country_flag_emoji", "emoji"),
    ("https://ipapi.co/json/", ".country_code", "iso2"),
    ("https://ipinfo.io/json", ".country", "iso2"),
    ("https://api.country.is/", ".country", "iso2"),
    ("http://ip-api.com/json/", ".countryCode", "iso2"),
)

def _jq_get(payload: Any, path: str) -> str:
    if not path or path == ".":
        return ""
    node = payload
    for part in path.lstrip(".").split("."):
        if not isinstance(node, dict):
            return ""
        node = node.get(part)
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    return str(node)


def _country_flag_value(mode: str, value: str) -> str | None:
    if not value:
        return None
    if mode == "emoji":
        return value
    if mode == "iso2":
        try:
            return country_code_to_flag(value)
        except ValueError:
            return None
    if mode == "trace_loc":
        for line in value.splitlines():
            if line.startswith("loc="):
                code = line[4:].strip()
                try:
                    return country_code_to_flag(code)
                except ValueError:
                    return None
    return None


def detect_country_flag(env: dict[str, str]) -> bool:
    """Best-effort public-IP flag detection (bash ``detect_country_flag`` parity)."""
    log.log("INFO", "Detecting country flag by public IP.")
    env["EMOJI_FLAG"] = "\u26a0"
    headers = {"Accept": "application/json"}
    for url, jq_path, mode in _COUNTRY_FLAG_SOURCES:
        try:
            request = urllib.request.Request(url, headers=headers, method="GET")
            with urllib.request.urlopen(request, timeout=4) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            log.log("WARN", f"{url}: country flag request failed ({exc}).")
            continue

        if mode != "trace_loc":
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                log.log("WARN", f"{url}: country flag response is not valid JSON.")
                continue
            value = _jq_get(payload, jq_path)
        else:
            value = raw

        emoji = _country_flag_value(mode, value)
        if emoji:
            env["EMOJI_FLAG"] = emoji
            log.log("INFO", f"Country flag ({url}): {emoji}")
            return True
        log.log("WARN", f"{url}: country flag value is empty.")

    log.log("WARN", "Country flag was not detected, using \u26a0.")
    return False


def log_shared_autogen_subscription_urls(
    desired: dict[str, Any] | None,
    env: dict[str, str],
) -> None:
    """Log STD/JSON/Clash subscription URLs for the shared autogen client."""
    if not desired:
        log.log("WARN", "shared subscription URLs omitted: empty desired state")
        return
    email = desired.get("clients", {}).get("shared", {}).get("email") or ""
    sub_id = desired.get("clients", {}).get("shared", {}).get("subId") or ""
    if not sub_id:
        log.log("WARN", "shared subscription URLs omitted: empty subId")
        return

    webdomain = env.get("WEBDOMAIN", "")
    std_base = env.get("subURI") or f"https://{webdomain}{env.get('URI_SUB_PATH', '')}"
    json_base = env.get("subJsonURI") or f"https://{webdomain}{env.get('URI_JSON_PATH', '')}"
    clash_base = env.get(
        "subClashURI",
        f"https://{webdomain}{env.get('URI_CLASH_PATH', '/clash/')}",
    )

    std = subscription_url_for_sub_id(std_base, sub_id)
    json_url = subscription_url_for_sub_id(json_base, sub_id)
    clash = subscription_url_for_sub_id(clash_base, sub_id)

    log.log("INFO", f"Shared client subscriptions email={email or 'unknown'} subId={sub_id}")
    if std:
        log.log("INFO", f"  STD   {std}")
    if json_url:
        log.log("INFO", f"  JSON  {json_url}")
    if clash:
        log.log("INFO", f"  CLASH {clash}")
    if not std and not json_url and not clash:
        log.log("WARN", "shared subscription URLs omitted: subscription base URIs empty")


def _apply_soft_subscription_env(env: dict[str, str]) -> None:
    env["subClashEnableRouting"] = "true"
    webdomain = (env.get("WEBDOMAIN") or "").strip()
    public_ipv4 = (env.get("PUBLIC_IPV4") or "").strip()
    routing = mihomo_client_routing_file(env)
    if routing is not None and webdomain:
        env["subClashRules"] = build_mihomo_client_sub_clash_rules(
            routing, webdomain, public_ipv4
        )
    else:
        env["subClashRules"] = build_admin_sub_clash_rules(
            webdomain,
            public_ipv4,
            admin_sub_clash_default_mode(),
        )
    rules = build_admin_sub_json_rules(webdomain)
    if rules:
        env["subJsonRules"] = json.dumps(rules, separators=(",", ":"), ensure_ascii=False)
    dns = build_admin_sub_json_dns(webdomain, public_ipv4)
    if dns:
        env["subJsonDns"] = json.dumps(dns, separators=(",", ":"), ensure_ascii=False)
    env["CLEAR_SUB_JSON_ROUTING_RULES"] = "true"
    if not public_ipv4:
        log.log("WARN", "PUBLIC_IPV4 empty: admin Clash/JSON hosts maps omitted")


def _remark_lines_for_clash(desired: dict[str, Any], env: dict[str, str]) -> list[str]:
    lines: list[str] = []
    shared_email = desired.get("clients", {}).get("shared", {}).get("email") or ""
    webdomain = (env.get("WEBDOMAIN") or "").strip()
    vision_remark = desired.get("inbounds", {}).get("vision", {}).get("remark") or ""
    vision_name = clash_subscription_proxy_name_for_kind(
        "vision", vision_remark, webdomain, shared_email
    )
    if vision_name:
        lines.append(vision_name)
    xhttp_remark = desired.get("inbounds", {}).get("xhttp", {}).get("remark") or ""
    if xhttp_remark:
        lines.append(xhttp_remark)
    if env.get("ENABLE_VLESS_GRPC", "false") == "true":
        grpc_remark = desired.get("inbounds", {}).get("grpc", {}).get("remark") or ""
        if grpc_remark:
            lines.append(grpc_remark)
    if env.get("ENABLE_AMNEZIAWG", "false") == "true":
        awg = desired.get("inbounds", {}).get("amneziawg", {}).get("remark") or ""
        if awg:
            lines.append(awg)
    if env.get("ENABLE_HYSTERIA2", "false") == "true":
        hy2 = desired.get("inbounds", {}).get("hysteria2", {}).get("remark") or ""
        if hy2:
            lines.append(hy2)
    return [line for line in lines if line]


def _rebuild_subscription_env_from_desired(
    desired: dict[str, Any],
    env: dict[str, str],
    tmp_root: Path,
) -> None:
    remarks_file = tmp_root / "clash-remarks.txt"
    remarks = _remark_lines_for_clash(desired, env)
    remarks_file.write_text("\n".join(remarks) + ("\n" if remarks else ""), encoding="utf-8")
    env["CLASH_PROXY_NODE_REMARKS_FILE"] = str(remarks_file)

    routing = mihomo_client_routing_file(env)
    webdomain = (env.get("WEBDOMAIN") or "").strip()
    public_ipv4 = (env.get("PUBLIC_IPV4") or "").strip()
    node_names: list[str] | None = None
    if routing is None or not webdomain:
        node_names = discover_clash_proxy_node_names(env)
        if not node_names:
            log.log("WARN", "Clash node names undiscoverable: omitting custom proxy-groups")
    else:
        log.log("INFO", f"Clash routing: mihomo client overlay {routing}")

    overrides = subscription_panel_env_overrides(env, node_names=node_names, routing_file=routing)
    env.update(overrides)
    env["subClashEnableRouting"] = "true"


def _resolve_udp443_backend(env: dict[str, str]) -> str:
    raw = (env.get("UDP443_BACKEND") or "").strip().lower()
    if raw:
        return raw
    if env.get("ENABLE_AMNEZIAWG", "false") == "true":
        return "amneziawg"
    if env.get("ENABLE_HYSTERIA2", "false") == "true":
        return "hysteria2"
    return "off"


def _wait_tcp_port(host: str, port: int, timeout: float, label: str) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                log.log("INFO", f"{label} is listening on {host}:{port}")
                return True
        except OSError:
            time.sleep(0.25)
    log.log("WARN", f"Timed out waiting for {label} after {timeout}s.")
    return False


def _managed_inbound_present(
    inbounds: list[dict[str, Any]],
    port: int,
    protocol: str,
) -> bool:
    return bool(find_inbound_by_port(inbounds, port, protocol))


def wait_managed_xray_ports(api: PanelApi, env: dict[str, str]) -> bool:
    """Wait for managed inbound listeners when present (bash ``wait_managed_xray_ports``)."""
    timeout = float(env.get("XRAY_RESTART_PORT_TIMEOUT", "30") or "30")
    failed = False
    try:
        from xui_runtime.apply.inbound import InboundApplyError, _list_inbounds

        inbounds = _list_inbounds(api)
    except (InboundApplyError, json.JSONDecodeError):
        log.log(
            "WARN",
            "Could not list inbounds before port wait; skipping managed inbound readiness checks.",
        )
        return False

    waiting = False
    vision_port = int(env.get("PORT_LOCAL_VISION", "443") or "443")
    if _managed_inbound_present(inbounds, vision_port, "vless"):
        waiting = True
        if not _wait_tcp_port("127.0.0.1", vision_port, timeout, f"Vision inbound {vision_port}"):
            failed = True
    else:
        log.log("INFO", f"Skipping Vision port wait; inbound on {vision_port} is not present yet.")

    xhttp_port = int(env.get("PORT_LOCAL_XHTTP", "8443") or "8443")
    if _managed_inbound_present(inbounds, xhttp_port, "vless"):
        waiting = True
        if not _wait_tcp_port("127.0.0.1", xhttp_port, timeout, f"XHTTP inbound {xhttp_port}"):
            failed = True
    else:
        log.log("INFO", f"Skipping XHTTP port wait; inbound on {xhttp_port} is not present yet.")

    udp_backend = _resolve_udp443_backend(env)
    udp_port = int(env.get("PORT_LOCAL_UDP443", env.get("PORT_LOCAL_HYSTERIA", "443")) or "443")
    if udp_backend == "amneziawg":
        if _managed_inbound_present(inbounds, udp_port, "amneziawg"):
            waiting = True
            log.log("INFO", f"Skipping UDP listener probe details for AmneziaWG {udp_port}/udp.")
        else:
            log.log(
                "INFO",
                f"Skipping AmneziaWG port wait; inbound on {udp_port}/udp is not present yet.",
            )
    elif udp_backend == "hysteria2":
        present = _managed_inbound_present(inbounds, udp_port, "hysteria") or _managed_inbound_present(
            inbounds, udp_port, "hysteria2"
        )
        if present:
            waiting = True
            log.log("INFO", f"Skipping UDP listener probe details for Hysteria2 {udp_port}/udp.")
        else:
            log.log(
                "INFO",
                f"Skipping Hysteria2 port wait; inbound on {udp_port}/udp is not present yet.",
            )

    if env.get("ENABLE_TELEMT", "false") == "true":
        mixed_port = int(env.get("PORT_LOCAL_XRAY_MIXED", "10808") or "10808")
        if _managed_inbound_present(inbounds, mixed_port, "mixed"):
            waiting = True
            if not _wait_tcp_port(
                "127.0.0.1",
                mixed_port,
                timeout,
                f"Mixed mixed-docker-net {mixed_port}",
            ):
                failed = True
        else:
            log.log(
                "INFO",
                f"Skipping mixed port wait; inbound on {mixed_port} is not present yet.",
            )

    if not waiting:
        log.log("INFO", "No managed inbounds to wait for yet.")
    return not failed


def restart_xray_if_needed(
    api: PanelApi,
    env: dict[str, str],
    mode: str,
    stats: ApplyStats,
) -> None:
    if mode != "apply":
        return
    if not stats.restart_xray_required:
        return
    result = api.restart_xray()
    if not result.ok or not api.session.success_json():
        log.log("WARN", f"Xray restart request failed: {api.session.body()}")
    stats.restart_xray_required = False
    settle = float(env.get("XRAY_RESTART_SETTLE_SECONDS", "5") or "5")
    time.sleep(settle)
    if not wait_managed_xray_ports(api, env):
        log.log("WARN", "One or more managed Xray inbounds are not listening after restart.")


def panel_egress_endpoint(config: Mapping[str, Any]) -> tuple[str, int] | None:
    """Return ``(host, port)`` for the panel-egress SOCKS inbound, if present."""
    inbounds = config.get("inbounds")
    if not isinstance(inbounds, list):
        return None
    for inbound in inbounds:
        if not isinstance(inbound, Mapping):
            continue
        if str(inbound.get("tag") or "") != "panel-egress":
            continue
        port_raw = inbound.get("port")
        try:
            port = int(port_raw)
        except (TypeError, ValueError):
            return None
        listen = inbound.get("listen", "127.0.0.1")
        if isinstance(listen, str):
            host = listen.strip().strip('"') or "127.0.0.1"
        else:
            host = "127.0.0.1"
        return host, port
    return None


def wait_panel_egress_ready(
    env: Mapping[str, str],
    *,
    timeout: float | None = None,
    sleep_fn: Callable[[float], None] | None = None,
    tcp_probe: Callable[[str, int, float], bool] | None = None,
) -> bool:
    """Wait until panel-egress accepts TCP, or proceed if the bridge is absent."""
    from xui_runtime.apply.xray import default_tcp_endpoint_available

    cfg_path = Path(env.get("XRAY_RUNNING_CONFIG", "/app/bin/config.json") or "/app/bin/config.json")
    if timeout is None:
        try:
            timeout = float(env.get("GEOFILES_EGRESS_WAIT_SECONDS", "20") or "20")
        except ValueError:
            timeout = 20.0
    sleeper = sleep_fn or time.sleep
    probe = tcp_probe or default_tcp_endpoint_available
    deadline = time.monotonic() + max(timeout, 0.0)
    while True:
        if cfg_path.is_file():
            try:
                config = json.loads(cfg_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                config = None
            if isinstance(config, dict):
                endpoint = panel_egress_endpoint(config)
                if endpoint is None:
                    return True
                host, port = endpoint
                if probe(host, port, 1.0):
                    return True
        if time.monotonic() >= deadline:
            log.log(
                "WARN",
                "panel-egress not accepting connections before geofile update; continuing.",
            )
            return False
        sleeper(1.0)


def update_builtin_geofiles_if_enabled(api: PanelApi, env: dict[str, str], mode: str) -> None:
    if env.get("GEOFILES_UPDATE_ON_START", "true") != "true":
        log.log("INFO", "Built-in geofile update skipped.")
        return
    if mode == "plan":
        log.log("INFO", "PLAN: built-in geofile update-all would be requested.")
        return
    if mode != "apply":
        return

    wait_panel_egress_ready(env)
    try:
        attempts = int(env.get("GEOFILES_UPDATE_ATTEMPTS", "3") or "3")
    except ValueError:
        attempts = 3
    attempts = max(attempts, 1)
    try:
        retry_sleep = float(env.get("GEOFILES_UPDATE_RETRY_SECONDS", "5") or "5")
    except ValueError:
        retry_sleep = 5.0

    last_body = ""
    for attempt in range(1, attempts + 1):
        result = api.update_geofiles()
        if result.ok and api.session.success_json():
            log.log("INFO", "Built-in geoip/geosite files refreshed through panel API.")
            return
        last_body = api.session.body()
        if attempt < attempts:
            log.log(
                "WARN",
                f"Built-in geofile update attempt {attempt}/{attempts} failed; retrying.",
            )
            time.sleep(retry_sleep)
            wait_panel_egress_ready(env)
    log.log("WARN", f"Built-in geofile update skipped: {last_body}")


def _merge_xray_stats(stats: ApplyStats, xray_stats: ApplyXrayStats, mode: str) -> None:
    stats.restart_panel_required = (
        stats.restart_panel_required or xray_stats.restart_panel_required
    )
    stats.restart_xray_required = stats.restart_xray_required or xray_stats.restart_xray_required
    if xray_stats.changed and mode in ("plan", "apply"):
        stats.change_count += 1


def _default_xray_probes(env: dict[str, str] | None = None) -> XrayApplyProbes:
    return XrayApplyProbes(
        warp_proxy_available=lambda host, port: default_warp_proxy_available(
            host, port, env=env
        ),
        tor_proxy_available=lambda host, port: default_tor_proxy_available(
            host, port, env=env
        ),
    )


def run_managed_runtime(
    env: dict[str, str],
    script_dir: str | Path,
    *,
    api: PanelApi | None = None,
    xray_probes: XrayApplyProbes | None = None,
) -> int:
    """Run full AfterStart pipeline in-process (``MODE=check|plan|apply``)."""
    _ = script_dir  # reserved for future asset paths; env is pre-loaded
    mode = (env.get("MODE") or "apply").strip().lower()
    require_apply_mode()
    engine = (env.get("XUI_RUNTIME_ENGINE") or "python").strip().lower()
    check_dependencies(engine)

    stats = ApplyStats()
    tmp_root = Path(tempfile.mkdtemp(prefix="xui-runtime-"))
    owns_api = api is None
    session: HttpSession | None = None
    try:
        _apply_soft_subscription_env(env)
        log.log("INFO", f"3x-ui managed runtime started MODE={mode} engine={engine}")

        if mode == "check":
            log.log("INFO", "Dependency and environment check passed.")
            desired = build_desired_state(env)
            log_shared_autogen_subscription_urls(desired, env)
            return 0

        if api is None:
            session = HttpSession(
                attempts=int(env.get("HTTP_ATTEMPTS", "4") or "4"),
                max_time=float(env.get("HTTP_MAX_TIME", "8") or "8"),
                log_failures=False,
                sleep_fn=time.sleep,
            )
            session.init(str(tmp_root / "http"))
            api = PanelApi(session, env)

        if not api.resolve_panel_base():
            log.log("ERROR", "Could not resolve and login to 3x-ui panel.")
            return 1

        try:
            detect_country_flag(env)
        except Exception:
            pass

        desired = build_desired_state(env)
        _rebuild_subscription_env_from_desired(desired, env, tmp_root)

        probes = (
            xray_probes if xray_probes is not None else _default_xray_probes(env)
        )
        xray_stats = apply_managed_xray(api, env, desired, mode, probes=probes)
        _merge_xray_stats(stats, xray_stats, mode)
        restart_xray_if_needed(api, env, mode, stats)

        ensure_panel_settings(api, env, stats, mode)
        update_admin_credentials_if_needed(api, env, mode, stats=stats)
        if not api.resolve_panel_base():
            log.log("ERROR", "Could not login after panel settings update.")
            return 1

        repair_inbound_client_tg_ids_db(env=env, mode=mode)

        cert_file = desired.get("tls", {}).get("certFile") or env.get("XRAY_TLS_CERT_FILE", "")
        key_file = desired.get("tls", {}).get("keyFile") or env.get("XRAY_TLS_KEY_FILE", "")
        if cert_file and key_file:
            env["XRAY_TLS_CERT_FILE"] = str(cert_file)
            env["XRAY_TLS_KEY_FILE"] = str(key_file)
        ensure_xray_tls_certificate(env, mode, stats)

        vision_id = ensure_inbound("vision", desired, api, env, mode, stats) or ""
        xhttp_id = ensure_inbound("xhttp", desired, api, env, mode, stats) or ""
        ensure_xhttp_client_extra(api, env, mode, stats)
        grpc_id = ""
        if env.get("ENABLE_VLESS_GRPC", "false") == "true":
            grpc_id = ensure_inbound("grpc", desired, api, env, mode, stats) or ""
        else:
            ensure_grpc_when_disabled(desired, api, env, mode, stats)

        udp_backend = _resolve_udp443_backend(env)
        hysteria2_id = ""
        amneziawg_id = ""
        if udp_backend == "amneziawg":
            delete_managed_inbound_kind("hysteria2", desired, api, mode, stats)
            amneziawg_id = ensure_inbound("amneziawg", desired, api, env, mode, stats) or ""
            if amneziawg_id:
                sync_amneziawg_profile(amneziawg_id, desired, api, env, mode, stats)
        elif udp_backend == "hysteria2":
            delete_managed_inbound_kind("amneziawg", desired, api, mode, stats)
            hysteria2_id = ensure_inbound("hysteria2", desired, api, env, mode, stats) or ""
        elif udp_backend == "off":
            delete_managed_inbound_kind("amneziawg", desired, api, mode, stats)
            delete_managed_inbound_kind("hysteria2", desired, api, mode, stats)
        else:
            log.log("ERROR", f"UDP443_BACKEND invalid: {udp_backend}")
            return 1

        if env.get("ENABLE_TELEMT", "false") == "true":
            ensure_inbound("mixed", desired, api, env, mode, stats)

        secrets = ensure_shared_client(
            vision_id,
            xhttp_id,
            grpc_id,
            hysteria2_id,
            amneziawg_id,
            desired,
            api,
            env,
            mode,
            stats,
        )

        if env.get("ENABLE_VLESS_GRPC", "false") == "true" and grpc_id:
            ensure_grpc_client(grpc_id, secrets.client_id, desired, api, env, mode, stats)

        if udp_backend == "hysteria2" and hysteria2_id:
            ensure_hysteria2_client(
                hysteria2_id,
                desired,
                api,
                env,
                mode,
                stats,
                shared_auth=secrets.auth,
            )

        repair_shared_client_after_inbound_sync(
            desired,
            vision_id,
            xhttp_id,
            grpc_id,
            secrets,
            env=env,
            mode=mode,
        )

        restart_xray_if_needed(api, env, mode, stats)
        if mode == "apply":
            if not wait_managed_xray_ports(api, env):
                log.log(
                    "WARN",
                    "One or more managed Xray inbounds are not listening after inbound sync.",
                )

        ensure_auto_sub_balancer(api, env, mode, stats, vision_id, xhttp_id, grpc_id, hysteria2_id)
        update_builtin_geofiles_if_enabled(api, env, mode)
        restart_panel_if_needed(api, env, mode, stats.restart_panel_required)

        log.log(
            "INFO",
            "3x-ui managed runtime complete: "
            f"changes={stats.change_count} "
            f"panel_restart={int(stats.restart_panel_required)} "
            f"xray_restart={int(stats.restart_xray_required)}",
        )
        log_shared_autogen_subscription_urls(desired, env)
        return 0
    finally:
        if owns_api and session is not None:
            pass
        shutil.rmtree(tmp_root, ignore_errors=True)


def cli(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="xui_runtime")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("check", "plan", "apply"),
        help="Runtime mode (check, plan, or apply)",
    )
    args = parser.parse_args(argv)

    script_dir = resolve_afterstart_dir()
    env = load_runtime_env(str(script_dir))
    env["MODE"] = args.mode
    env["XUI_RUNTIME_ENGINE"] = env.get("XUI_RUNTIME_ENGINE") or "python"

    for key, value in env.items():
        os.environ[key] = value

    if not PYTHON_RUNTIME_READY:
        print(
            "XUI_RUNTIME_ENGINE=python is not implemented until main orchestrator is ready",
            file=sys.stderr,
        )
        raise SystemExit(2)

    code = run_managed_runtime(env, script_dir)
    raise SystemExit(code)


if __name__ == "__main__":
    cli()