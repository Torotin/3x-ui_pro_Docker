"""Pure JSON transforms for managed Xray state (bash ``lib/json_state.bash`` parity)."""

from __future__ import annotations

import copy
import json
from typing import Any

_MANAGED_OBSERVATORY_SELECTORS = frozenset(
    {"tor-proxy", "torproxy", "warp", "usque"}
)

_MANAGED_OUTBOUND_TAGS = frozenset(
    {"tor-proxy", "torproxy", "warp", "usque", "warp-retired", "mihomo"}
)

_TRAEFIK_ADMIN_REDIRECT = "172.18.0.6:9443"

_ADMIN_HOSTNAMES = (
    "arcane",
    "homepage",
    "adguard",
    "3x-ui",
    "traefik",
    "lampac-admin",
    "telemt",
)

_WARP_MANAGED_DOMAINS: tuple[str, ...] = (
    "domain:habr.com",
    "domain:easebar.com",
    "domain:habrastorage.org",
    "ext:geosite_RU.dat:category-bank-ru",
    "ext:geosite_RU.dat:category-betting-ru",
    "ext:geosite_RU.dat:category-ecommerce-ru",
    "ext:geosite_RU.dat:category-entertainment-ru",
    "ext:geosite_RU.dat:category-gov-ru",
    "ext:geosite_RU.dat:category-media-ru",
    "ext:geosite_RU.dat:category-medicine-ru",
    "ext:geosite_RU.dat:category-retail-ru",
    "ext:geosite_RU.dat:category-ru",
    "ext:geosite_RU.dat:category-travel-ru",
    "ext:geosite_RU.dat:genotek-ru",
    "ext:geosite_RU.dat:ideco-ru",
    "ext:geosite_RU.dat:myoffice-ru",
    "ext:geosite_RU.dat:tbank-ru",
    "ext:geosite_RU.dat:tld-ru",
    "ext:geosite_RU.dat:private",
    "ext:geosite_RU.dat:yandex",
    "ext:geosite_RU.dat:steam",
    "ext:geosite_RU.dat:vk",
    r"regexp:^([\w\-\.]+\.)ru$",
    r"regexp:^([\w\-\.]+\.)su$",
    r"regexp:^([\w\-\.]+\.)xn--p1ai$",
    r"regexp:^([\w\-\.]+\.)xn--p1acf$",
    r"regexp:^([\w\-\.]+\.)xn--c1avg$",
    r"regexp:^([\w\-\.]+\.)xn--80asehdb$",
    r"regexp:^([\w\-\.]+\.)xn--80aswg$",
    r"regexp:^([\w\-\.]+\.)moscow$",
    r"regexp:^([\w\-\.]+\.)xn--80adxhks$",
    r"regexp:^([\w\-\.]+\.)xn--d1acj3b$",
    r"regexp:^([\w\-\.]+\.)xn--90ais$",
    r"regexp:^([\w\-\.]+\.)xn--j1amh$",
    r"regexp:^([\w\-\.]+\.)xn--90ae$",
    r"regexp:^([\w\-\.]+\.)xn--l1acc$",
    r"regexp:^([\w\-\.]+\.)xn--d1alf$",
)


def _truthy(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    return text in ("1", "true", "yes", "on")


def json_equal(left: Any, right: Any) -> bool:
    """Compare JSON documents ignoring key order."""
    return json.dumps(left, sort_keys=True) == json.dumps(right, sort_keys=True)


def upsert_outbound_by_tag(current: dict[str, Any], outbound: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    outbounds: list[dict[str, Any]] = list(xs.get("outbounds") or [])
    tag = outbound["tag"]
    for index, item in enumerate(outbounds):
        if item.get("tag") == tag:
            outbounds[index] = copy.deepcopy(outbound)
            xs["outbounds"] = outbounds
            return out
    outbounds.append(copy.deepcopy(outbound))
    xs["outbounds"] = outbounds
    return out


def add_outbound_if_missing(current: dict[str, Any], outbound: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    outbounds: list[dict[str, Any]] = list(xs.get("outbounds") or [])
    tag = outbound["tag"]
    if any(item.get("tag") == tag for item in outbounds):
        return out
    outbounds.append(copy.deepcopy(outbound))
    xs["outbounds"] = outbounds
    return out


def upsert_routing_rule_by_key(
    current: dict[str, Any],
    key: str,
    value: str,
    rule: dict[str, Any],
) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    routing = xs.setdefault("routing", {})
    rules: list[dict[str, Any]] = list(routing.get("rules") or [])
    for index, item in enumerate(rules):
        if item.get(key) == value:
            rules[index] = copy.deepcopy(rule)
            routing["rules"] = rules
            return out
    routing["rules"] = [copy.deepcopy(rule)] + rules
    return out


def append_routing_rule_if_outbound_missing(
    current: dict[str, Any],
    outbound_tag: str,
    rule: dict[str, Any],
) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    routing = xs.setdefault("routing", {})
    rules: list[dict[str, Any]] = list(routing.get("rules") or [])
    if any((item.get("outboundTag") or "") == outbound_tag for item in rules):
        return out
    rules.append(copy.deepcopy(rule))
    routing["rules"] = rules
    return out


def upsert_balancer_by_tag(current: dict[str, Any], balancer: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    routing = xs.setdefault("routing", {})
    balancers: list[dict[str, Any]] = list(routing.get("balancers") or [])
    tag = balancer["tag"]
    for index, item in enumerate(balancers):
        if item.get("tag") == tag:
            balancers[index] = copy.deepcopy(balancer)
            routing["balancers"] = balancers
            return out
    balancers.append(copy.deepcopy(balancer))
    routing["balancers"] = balancers
    return out


def burst_observatory_for_selectors(selectors: list[str]) -> dict[str, Any]:
    return {
        "subjectSelector": list(selectors),
        "pingConfig": {
            "destination": "https://connectivitycheck.gstatic.com/generate_204",
            "connectivity": "",
            "interval": "1m",
            "sampling": 10,
            "timeout": "5s",
            "httpMethod": "HEAD",
        },
    }


def managed_observatory_selectors() -> list[str]:
    return ["tor-proxy", "torproxy", "warp", "usque"]


def remove_managed_subject_selectors(current: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    xs["observatory"] = None
    burst = xs.get("burstObservatory")
    if not isinstance(burst, dict):
        return out
    selectors = burst.get("subjectSelector")
    if isinstance(selectors, list):
        filtered = [
            s
            for s in selectors
            if s not in _MANAGED_OBSERVATORY_SELECTORS and s != "usque"
        ]
        if filtered:
            xs["burstObservatory"] = {**burst, "subjectSelector": filtered}
        else:
            xs["burstObservatory"] = None
    return out


def replace_dns_servers(
    current: dict[str, Any],
    servers: list[dict[str, Any]],
) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    dns = xs.setdefault("dns", {})
    dns.setdefault("disableCache", False)
    dns.setdefault("queryStrategy", "UseIP")
    dns["servers"] = copy.deepcopy(servers)
    return out


def warp_managed_domains(_webdomain: str | None = None) -> list[str]:
    return list(_WARP_MANAGED_DOMAINS)


def replace_warp_routing_rules(
    current: dict[str, Any],
    webdomain: str,
    warp_rule: dict[str, Any],
) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    routing = xs.setdefault("routing", {})
    rules: list[dict[str, Any]] = list(routing.get("rules") or [])

    managed_rules: list[dict[str, Any]] = []
    if webdomain:
        managed_rules.append(
            {
                "type": "field",
                "balancerTag": "warp-balancer",
                "domain": [f"domain:{webdomain}"],
            }
        )
    managed_rules.append(copy.deepcopy(warp_rule))

    def is_api_rule(rule: dict[str, Any]) -> bool:
        if (rule.get("outboundTag") or "") == "api":
            return True
        inbound = rule.get("inboundTag")
        return isinstance(inbound, list) and "api" in inbound

    stripped = [
        r for r in rules if (r.get("balancerTag") or "") != "warp-balancer"
    ]
    api_index: int | None = None
    for index, rule in enumerate(stripped):
        if is_api_rule(rule):
            api_index = index
            break
    if api_index is None:
        routing["rules"] = managed_rules + stripped
    else:
        routing["rules"] = (
            stripped[: api_index + 1]
            + managed_rules
            + stripped[api_index + 1 :]
        )
    return out


def upsert_admin_traefik_route(
    current: dict[str, Any],
    webdomain: str,
) -> dict[str, Any]:
    if not webdomain:
        return copy.deepcopy(current)
    admin_ob = {
        "tag": "admin-traefik",
        "protocol": "freedom",
        "settings": {
            "redirect": _TRAEFIK_ADMIN_REDIRECT,
            "domainStrategy": "AsIs",
            "finalRules": [{"action": "allow"}],
        },
    }
    admin_rule = {
        "type": "field",
        "outboundTag": "admin-traefik",
        "domain": [f"full:{host}.{webdomain}" for host in _ADMIN_HOSTNAMES],
    }
    admin_port_rule = {
        "type": "field",
        "outboundTag": "admin-traefik",
        "port": "9443",
        "network": "tcp",
    }
    updated = upsert_outbound_by_tag(current, admin_ob)
    out = copy.deepcopy(updated)
    xs = out.setdefault("xraySetting", {})
    routing = xs.setdefault("routing", {})
    rules: list[dict[str, Any]] = list(routing.get("rules") or [])
    kept = [r for r in rules if (r.get("outboundTag") or "") != "admin-traefik"]
    routing["rules"] = [admin_rule, admin_port_rule] + kept
    return out


def apply_managed_xray_state(
    current: dict[str, Any],
    dns_servers: list[dict[str, Any]],
    warp_enabled: object,
    tor_enabled: object,
    dns_enabled: object,
    warp_endpoints: list[dict[str, Any]] | None = None,
    webdomain: str = "",
    tor_endpoints: list[dict[str, Any]] | None = None,
    warp_console_ob: dict[str, Any] | str | None = None,
    mihomo_enabled: object = False,
    mihomo_endpoints: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    warp_eps = warp_endpoints or []
    tor_eps = tor_endpoints or []
    mihomo_eps = mihomo_endpoints or []
    updated = copy.deepcopy(current)
    observatory_selectors: list[str] = []

    if _truthy(dns_enabled):
        updated = replace_dns_servers(updated, dns_servers)

    if _truthy(tor_enabled):
        tor_selectors: list[str] = []
        for endpoint in tor_eps:
            tag = endpoint["tag"]
            host = endpoint["host"]
            port = endpoint["port"]
            tor_ob = {
                "tag": tag,
                "protocol": "socks",
                "settings": {
                    "servers": [{"address": host, "port": port}],
                },
            }
            updated = upsert_outbound_by_tag(updated, tor_ob)
            tor_selectors.append(tag)
        if tor_selectors:
            tor_rule = {
                "type": "field",
                "balancerTag": "tor-balancer",
                "domain": [
                    "domain:onion",
                    "domain:torproject.org",
                    "domain:ntc.party",
                ],
            }
            tor_balancer = {
                "tag": "tor-balancer",
                "selector": list(tor_selectors),
                "strategy": {"type": "leastPing"},
            }
            updated = upsert_routing_rule_by_key(
                updated, "balancerTag", "tor-balancer", tor_rule
            )
            updated = upsert_balancer_by_tag(updated, tor_balancer)
            observatory_selectors = sorted(set(observatory_selectors + tor_selectors))

    if _truthy(warp_enabled):
        selectors: list[str] = []
        if isinstance(warp_console_ob, dict) and warp_console_ob:
            updated = upsert_outbound_by_tag(updated, warp_console_ob)
            selectors.append("warp")
        for endpoint in warp_eps:
            tag = endpoint["tag"]
            host = endpoint["host"]
            port = endpoint["port"]
            warp_ob = {
                "tag": tag,
                "protocol": "socks",
                "settings": {
                    "servers": [{"address": host, "port": port}],
                },
            }
            updated = upsert_outbound_by_tag(updated, warp_ob)
            selectors.append(tag)
        if selectors:
            warp_domains = warp_managed_domains(webdomain)
            warp_rule = {
                "type": "field",
                "balancerTag": "warp-balancer",
                "domain": warp_domains,
            }
            warp_balancer = {
                "tag": "warp-balancer",
                "fallbackTag": "blocked",
                "selector": list(selectors),
                "strategy": {"type": "leastPing"},
            }
            updated = replace_warp_routing_rules(updated, webdomain, warp_rule)
            updated = upsert_balancer_by_tag(updated, warp_balancer)
            observatory_selectors = sorted(set(observatory_selectors + selectors))

    if _truthy(mihomo_enabled) and mihomo_eps:
        endpoint = mihomo_eps[0]
        tag = endpoint.get("tag", "mihomo")
        host = endpoint.get("host", "mihomo")
        port = endpoint.get("port", 7890)
        mihomo_ob = {
            "tag": tag,
            "protocol": "socks",
            "settings": {
                "servers": [{"address": host, "port": port, "users": []}],
            },
        }
        mihomo_rule = {
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": tag,
        }
        updated = add_outbound_if_missing(updated, mihomo_ob)
        updated = append_routing_rule_if_outbound_missing(updated, tag, mihomo_rule)

    if observatory_selectors:
        burst = burst_observatory_for_selectors(observatory_selectors)
        out = copy.deepcopy(updated)
        xs = out.setdefault("xraySetting", {})
        xs["observatory"] = None
        existing = xs.get("burstObservatory")
        if isinstance(existing, dict):
            existing_sel = existing.get("subjectSelector") or []
            if isinstance(existing_sel, list) and existing_sel:
                merged = sorted(set(existing_sel + burst["subjectSelector"]))
                xs["burstObservatory"] = {
                    **existing,
                    "subjectSelector": merged,
                    "pingConfig": burst["pingConfig"],
                }
            else:
                xs["burstObservatory"] = burst
        else:
            xs["burstObservatory"] = burst
        updated = out

    updated = upsert_admin_traefik_route(updated, webdomain)
    return updated


def apply_geodata_block(
    current: dict[str, Any],
    outbound: str,
    assets: list[dict[str, Any]],
    cron: str,
) -> dict[str, Any]:
    out = copy.deepcopy(current)
    xs = out.setdefault("xraySetting", {})
    xs["geodata"] = {
        "cron": cron,
        "outbound": outbound,
        "assets": copy.deepcopy(assets),
    }
    return out


def geodata_outbound_tag(
    warp_endpoints: list[dict[str, Any]] | None = None,
    mihomo_endpoints: list[dict[str, Any]] | None = None,
) -> str:
    warp_eps = warp_endpoints or []
    mihomo_eps = mihomo_endpoints or []
    if any(ep.get("tag") == "usque" for ep in warp_eps):
        return "usque"
    if mihomo_eps:
        return str(mihomo_eps[0].get("tag") or "mihomo")
    return "direct"


def remove_managed_xray_artifacts(current: dict[str, Any]) -> dict[str, Any]:
    out = remove_managed_subject_selectors(current)
    xs = out.setdefault("xraySetting", {})

    outbounds = [
        ob
        for ob in (xs.get("outbounds") or [])
        if (ob.get("tag") or "") not in _MANAGED_OUTBOUND_TAGS
    ]
    xs["outbounds"] = outbounds

    routing = xs.setdefault("routing", {})
    rules = [
        r
        for r in (routing.get("rules") or [])
        if (r.get("outboundTag") or "") not in ("tor-proxy", "mihomo")
        and (r.get("balancerTag") or "") not in ("tor-balancer", "warp-balancer")
    ]
    routing["rules"] = rules

    balancers = [
        b
        for b in (routing.get("balancers") or [])
        if (b.get("tag") or "") not in ("tor-balancer", "warp-balancer")
    ]
    routing["balancers"] = balancers
    return out