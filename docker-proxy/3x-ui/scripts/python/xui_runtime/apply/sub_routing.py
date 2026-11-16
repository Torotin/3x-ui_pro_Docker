"""Subscription Clash/JSON/DNS builders (bash ``sub_admin_routing.bash`` parity)."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

ADMIN_SUB_HOSTNAMES: tuple[str, ...] = (
    "arcane",
    "homepage",
    "adguard",
    "3x-ui",
    "traefik",
    "lampac-admin",
    "telemt",
)

_CLASH_MANAGED_REMARK_SLUG = re.compile(
    r"vless-tcp-reality|vless-xhttp|vless-grpc-tls|hysteria2|amneziawg|managed:"
)

_VALID_CLASH_MODES = frozenset({"rules-admin", "full", "rules-proxy"})


def admin_sub_hostnames() -> tuple[str, ...]:
    return ADMIN_SUB_HOSTNAMES


def admin_sub_clash_default_mode() -> str:
    return "rules-proxy"


def admin_sub_auto_policy_name(domain: str | None = None, env: Mapping[str, str] | None = None) -> str | None:
    if domain is None:
        env = env or os.environ
        domain = (env.get("WEBDOMAIN") or "").strip()
    if not domain:
        return None
    return f"AUTO-{domain}"


def admin_sub_proxy_policy_name(domain: str | None = None, env: Mapping[str, str] | None = None) -> str | None:
    if domain is None:
        env = env or os.environ
        domain = (env.get("WEBDOMAIN") or "").strip()
    if not domain:
        return None
    return f"PROXY-{domain}"


def discover_clash_proxy_node_names_from_lines(lines: Iterable[str]) -> list[str]:
    out: list[str] = []
    for raw in lines:
        line = raw.replace("\r", "").strip()
        if not line or line == "DIRECT":
            continue
        out.append(raw.rstrip("\r\n"))
    return out


def discover_clash_proxy_node_names_from_clash_body(clash_body_file: str | Path) -> list[str]:
    path = Path(clash_body_file)
    if not path.is_file():
        return []
    in_proxies = False
    names: list[str] = []
    name_re = re.compile(r"^\s*-\s*name:\s*(.*)$")
    for raw in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^proxies:\s*$", raw):
            in_proxies = True
            continue
        if in_proxies and raw and not raw[0].isspace() and not raw.startswith("#") and not raw.startswith("-"):
            in_proxies = False
        if not in_proxies:
            continue
        match = name_re.match(raw)
        if not match:
            continue
        name = match.group(1).strip().strip("'\"")
        if name:
            names.append(name)
    return discover_clash_proxy_node_names_from_lines(names)


def discover_clash_proxy_node_remark_lines_from_inbounds_json(json_file: str | Path) -> list[str]:
    path = Path(json_file)
    payload = json.loads(path.read_text(encoding="utf-8"))
    items = payload.get("obj", payload)
    if not isinstance(items, list):
        items = [items]
    remarks: set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        remark = str(item.get("remark") or "").strip()
        if remark and _CLASH_MANAGED_REMARK_SLUG.search(remark):
            remarks.add(remark)
    return sorted(remarks)


def discover_clash_proxy_node_remark_lines(
    env: Mapping[str, str] | None = None,
    *,
    remarks_file: str | Path | None = None,
    inbounds_file: str | Path | None = None,
    http_body_file: str | Path | None = None,
) -> list[str]:
    env = env or os.environ
    remarks_path = remarks_file or (env.get("CLASH_PROXY_NODE_REMARKS_FILE") or "").strip()
    if remarks_path:
        path = Path(remarks_path)
        if path.is_file():
            return [
                line.replace("\r", "").rstrip()
                for line in path.read_text(encoding="utf-8").splitlines()
                if line.replace("\r", "").strip()
            ]

    inbounds_path = inbounds_file or (env.get("CLASH_DISCOVERY_INBOUNDS_JSON_FILE") or "").strip()
    if inbounds_path and Path(inbounds_path).is_file():
        return discover_clash_proxy_node_remark_lines_from_inbounds_json(inbounds_path)

    body_path = http_body_file or (env.get("HTTP_BODY_FILE") or "").strip()
    if body_path and Path(body_path).is_file():
        try:
            payload = json.loads(Path(body_path).read_text(encoding="utf-8"))
            if payload.get("success") is True and isinstance(payload.get("obj"), list):
                return discover_clash_proxy_node_remark_lines_from_inbounds_json(body_path)
        except json.JSONDecodeError:
            pass
    return []


def clash_subscription_proxy_name_for_kind(
    kind: str,
    remark: str,
    webdomain: str = "",
    email: str = "",
) -> str:
    if not remark:
        return ""
    if kind == "vision":
        if email:
            return f"{remark}-{email}"
        return remark
    return remark


def map_clash_remarks_to_published_proxy_names(
    remarks_file: str | Path,
    body_file: str | Path,
) -> list[str]:
    remarks_path = Path(remarks_file)
    body_path = Path(body_file)
    if not remarks_path.is_file() or not body_path.is_file():
        return []
    published = discover_clash_proxy_node_names_from_clash_body(body_path)
    if not published:
        return []
    pub_set = set(published)
    out: list[str] = []
    for raw in remarks_path.read_text(encoding="utf-8").splitlines():
        remark = raw.replace("\r", "").strip()
        if not remark or remark == "DIRECT":
            continue
        if remark in pub_set:
            out.append(remark)
            continue
        prefix_matches = [name for name in published if name.startswith(f"{remark}-")]
        if len(prefix_matches) == 1:
            out.append(prefix_matches[0])
            continue
        out.append(remark)
    return out


def discover_clash_proxy_node_names(
    env: Mapping[str, str] | None = None,
    *,
    clash_body_file: str | Path | None = None,
) -> list[str]:
    env = env or os.environ
    body = clash_body_file or (env.get("CLASH_DISCOVERY_BODY_FILE") or "").strip()
    remark_lines = discover_clash_proxy_node_remark_lines(env)
    if remark_lines and body and Path(body).is_file():
        return map_clash_remarks_to_published_proxy_names_from_lines(remark_lines, Path(body))
    if remark_lines:
        return discover_clash_proxy_node_names_from_lines(remark_lines)
    if body and Path(body).is_file():
        return discover_clash_proxy_node_names_from_clash_body(body)
    return []


def map_clash_remarks_to_published_proxy_names_from_lines(
    remark_lines: Sequence[str],
    body_path: Path,
) -> list[str]:
    import tempfile

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write("\n".join(remark_lines))
        handle.write("\n")
        remarks_file = handle.name
    try:
        return map_clash_remarks_to_published_proxy_names(remarks_file, body_path)
    finally:
        Path(remarks_file).unlink(missing_ok=True)


def build_admin_sub_json_rules(webdomain: str) -> list[dict[str, Any]] | str:
    if not webdomain:
        return ""
    hosts = list(admin_sub_hostnames())
    return [
        {
            "type": "field",
            "domain": [f"full:{host}.{webdomain}" for host in hosts],
            "outboundTag": "proxy",
        },
        {
            "type": "field",
            "port": "9443",
            "network": "tcp",
            "outboundTag": "proxy",
        },
        {
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "direct",
        },
    ]


def build_admin_sub_json_routing_rules() -> str:
    return ""


def build_admin_sub_json_dns(webdomain: str, public_ipv4: str = "") -> dict[str, Any] | str:
    if not webdomain or not public_ipv4:
        return ""
    hosts = list(admin_sub_hostnames())
    host_map: dict[str, str] = {webdomain: public_ipv4}
    for host in hosts:
        host_map[f"{host}.{webdomain}"] = public_ipv4
    return {
        "hosts": host_map,
        "queryStrategy": "UseIP",
        "servers": [{"address": "8.8.8.8", "skipFallback": False}],
        "tag": "dns_out",
    }


def build_admin_sub_clash_rules(
    webdomain: str,
    public_ipv4: str = "",
    mode: str | None = None,
    node_names: Sequence[str] | None = None,
) -> str:
    selected_mode = mode or admin_sub_clash_default_mode()
    if selected_mode not in _VALID_CLASH_MODES:
        raise ValueError(f"build_admin_sub_clash_rules: unknown mode {selected_mode}")

    nodes = [n.replace("\r", "").strip() for n in (node_names or []) if n.replace("\r", "").strip()]
    parts: list[str] = []
    rule_proxy = "PROXY"

    if nodes:
        auto_name = admin_sub_auto_policy_name(webdomain)
        proxy_name = admin_sub_proxy_policy_name(webdomain)
        if auto_name and proxy_name:
            rule_proxy = proxy_name
            parts.extend(
                [
                    "proxy-groups:",
                    f"  - name: {auto_name}",
                    "    type: url-test",
                    "    hidden: true",
                    "    url: https://www.gstatic.com/generate_204",
                    "    interval: 300",
                    "    proxies:",
                ]
            )
            parts.extend(f"      - {node}" for node in nodes)
            parts.extend(
                [
                    f"  - name: {proxy_name}",
                    "    type: select",
                    "    proxies:",
                    f"      - {auto_name}",
                ]
            )
            parts.extend(f"      - {node}" for node in nodes)

    if public_ipv4:
        parts.append("hosts:")
        parts.append(f"  {webdomain}: {public_ipv4}")
        for host in admin_sub_hostnames():
            parts.append(f"  {host}.{webdomain}: {public_ipv4}")
        parts.extend(
            [
                "dns:",
                "  fake-ip-filter:",
                f"    - {webdomain}",
                f'    - "+.{webdomain}"',
            ]
        )

    parts.append("rules:")
    for host in admin_sub_hostnames():
        parts.append(f"  - DOMAIN,{host}.{webdomain},{rule_proxy}")
    parts.append("  - MATCH,DIRECT")
    return "\n".join(parts) + "\n"


def subscription_url_for_sub_id(base: str, sub_id: str) -> str | None:
    if not base or not sub_id:
        return None
    trimmed = base.rstrip("/")
    if not trimmed:
        return None
    return f"{trimmed}/{sub_id}"


def mihomo_client_routing_file(env: Mapping[str, str] | None = None) -> Path | None:
    env = env or os.environ
    override = (env.get("MIHOMO_CLIENT_ROUTING_FILE") or "").strip()
    if override:
        path = Path(override)
        return path if path.is_file() else None
    container = Path("/mnt/sh/client-routing/mihomo-client.yaml")
    if container.is_file():
        return container
    legacy = Path("/mnt/sh/lib/mihomo-client.yaml")
    if legacy.is_file():
        return legacy
    repo = Path(__file__).resolve().parents[4] / "client-routing" / "mihomo-client.yaml"
    return repo if repo.is_file() else None


def _mihomo_fill_marker_block(name: str, content: str, yaml_text: str) -> str:
    start = f"# >>> {name}"
    stop = f"# <<< {name}"
    out: list[str] = []
    skip = False
    for line in yaml_text.splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.rstrip("\r\n") == start:
            out.append(line)
            if content:
                if content.endswith("\n"):
                    out.append(content)
                else:
                    out.append(content + "\n")
            skip = True
            continue
        if skip and stripped.rstrip("\r\n") == stop:
            skip = False
            out.append(line)
            continue
        if skip:
            continue
        out.append(line)
    return "".join(out)


def build_mihomo_client_sub_clash_rules(
    routing_file: str | Path,
    webdomain: str,
    public_ipv4: str = "",
) -> str:
    path = Path(routing_file)
    if not path.is_file():
        raise ValueError("build_mihomo_client_sub_clash_rules: missing routing file")
    if not webdomain:
        raise ValueError("build_mihomo_client_sub_clash_rules: empty webdomain")

    fakeip_block = ""
    dns_hosts_block = ""
    if public_ipv4:
        fakeip_lines = [
            f"    - DOMAIN,{webdomain},real-ip",
            f"    - DOMAIN-SUFFIX,{webdomain},real-ip",
        ]
        fakeip_block = "\n".join(fakeip_lines)
        dns_lines = [f"    '{webdomain}': {public_ipv4}"]
        for host in admin_sub_hostnames():
            dns_lines.append(f"    '{host}.{webdomain}': {public_ipv4}")
        dns_hosts_block = "\n".join(dns_lines)

    rule_lines = [f"  - DOMAIN,{webdomain},PROXY"]
    for host in admin_sub_hostnames():
        rule_lines.append(f"  - DOMAIN,{host}.{webdomain},PROXY")
    rules_block = "\n".join(rule_lines)

    yaml_text = path.read_text(encoding="utf-8")
    yaml_text = _mihomo_fill_marker_block("ADMIN_FAKEIP", fakeip_block, yaml_text)
    yaml_text = _mihomo_fill_marker_block("ADMIN_DNS_HOSTS", dns_hosts_block, yaml_text)
    yaml_text = _mihomo_fill_marker_block("ADMIN_RULES", rules_block, yaml_text)
    if not yaml_text.endswith("\n"):
        yaml_text += "\n"
    return yaml_text


def subscription_panel_env_overrides(
    env: Mapping[str, str],
    *,
    node_names: Sequence[str] | None = None,
    routing_file: Path | None = None,
) -> dict[str, str]:
    """Build panel subscription fields exported by AfterStart before panel apply."""
    webdomain = (env.get("WEBDOMAIN") or "").strip()
    public_ipv4 = (env.get("PUBLIC_IPV4") or "").strip()
    out: dict[str, str] = {"subClashEnableRouting": "true"}

    routing = routing_file
    if routing is None:
        routing = mihomo_client_routing_file(env)

    if routing is not None and webdomain:
        out["subClashRules"] = build_mihomo_client_sub_clash_rules(routing, webdomain, public_ipv4)
    else:
        out["subClashRules"] = build_admin_sub_clash_rules(
            webdomain,
            public_ipv4,
            admin_sub_clash_default_mode(),
            node_names,
        )

    rules = build_admin_sub_json_rules(webdomain)
    if rules:
        out["subJsonRules"] = json.dumps(rules, separators=(",", ":"), ensure_ascii=False)

    dns = build_admin_sub_json_dns(webdomain, public_ipv4)
    if dns:
        out["subJsonDns"] = json.dumps(dns, separators=(",", ":"), ensure_ascii=False)

    from xui_runtime.apply.sub_balancer import build_admin_sub_json_observatory

    observatory = build_admin_sub_json_observatory()
    out["subJsonObservatory"] = json.dumps(observatory, separators=(",", ":"), ensure_ascii=False)
    return out