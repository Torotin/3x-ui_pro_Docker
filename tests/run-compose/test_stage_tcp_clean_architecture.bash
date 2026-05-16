#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

run_python_check() {
	python3 - "$ROOT_DIR" <<'PY'
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])

def load_yaml(path):
    with (root / path).open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}

def labels_for(service):
    out = {}
    for label in service.get("labels") or []:
        if not isinstance(label, str) or "=" not in label:
            continue
        key, value = label.split("=", 1)
        out[key] = value
    return out

def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)

traefik_compose = load_yaml("docker-proxy/compose.d/06-traefik.yml")
traefik_service = traefik_compose["services"]["traefik"]
traefik_ports = [str(port) for port in (traefik_service.get("ports") or [])]
assert_true(traefik_ports == ["80:80"], f"Traefik must publish only 80:80, got {traefik_ports}")

traefik_static = load_yaml("docker-proxy/traefik/traefik.yml")
entrypoints = traefik_static.get("entryPoints") or {}
assert_true("web" in entrypoints, "Traefik web entrypoint must remain")
assert_true((entrypoints.get("websecure") or {}).get("address") == ":4443", "Traefik websecure must remain internal :4443")
web_redirect = (((entrypoints.get("web") or {}).get("http") or {}).get("redirections") or {}).get("entryPoint") or {}
assert_true(web_redirect.get("to") == ":443", "Traefik HTTP redirect must point to public :443, not internal :4443")
assert_true("l4tcp" not in entrypoints, "Traefik l4tcp entrypoint must be removed")
assert_true("l4udp" not in entrypoints, "Traefik l4udp entrypoint must be removed")
assert_true("http3" not in (entrypoints.get("websecure") or {}), "Traefik HTTP/3 must be disabled")
assert_true((traefik_static.get("api") or {}).get("insecure") is False, "Traefik api.insecure must be false")

traefik_labels = labels_for(traefik_service)
for key in traefik_labels:
    assert_true("traefik.tcp." not in key, f"Traefik TCP label must not exist: {key}")
    assert_true("traefik.udp." not in key, f"Traefik UDP label must not exist: {key}")
for key, value in traefik_labels.items():
    if key.startswith("traefik.http.routers."):
        assert_true("Host(`${WEBDOMAIN}`) && PathPrefix(`/api`)" not in value, "Traefik dashboard must not expose root-domain /api")
        assert_true("Host(`${WEBDOMAIN}`) && PathPrefix(`/dashboard`)" not in value, "Traefik dashboard must not expose root-domain /dashboard")

xui_compose = load_yaml("docker-proxy/compose.d/12-3x-ui.yml")
xui_service = xui_compose["services"]["3x-ui"]
xui_ports = [str(port) for port in (xui_service.get("ports") or [])]
assert_true(xui_ports == ["443:${PORT_LOCAL_VISION:-443}/tcp"], f"3x-ui must publish only Xray 443/tcp, got {xui_ports}")
xui_labels = labels_for(xui_service)
for key, value in xui_labels.items():
    assert_true("traefik.tcp." not in key, f"3x-ui Traefik TCP label must be removed: {key}")
    assert_true("traefik.udp." not in key, f"3x-ui Traefik UDP label must be removed: {key}")
    assert_true(value != "l4tcp", "No 3x-ui HTTP router may use l4tcp")

lampac_compose = load_yaml("docker-proxy/compose.d/14-lampac.yml")
lampac_service = lampac_compose["services"]["lampac"]
assert_true(not lampac_service.get("ports"), "Lampac must not publish direct ports")
lampac_labels = labels_for(lampac_service)
public_middleware = lampac_labels.get("traefik.http.routers.lampac-https.middlewares", "")
assert_true("basic-auth" not in public_middleware.lower(), "Lampac public front must not use BasicAuth")
assert_true("bouncer" not in public_middleware.lower(), "Lampac public front must not use CrowdSec bouncer")
sensitive = lampac_labels.get("traefik.http.routers.lampac-sensitive.middlewares", "")
assert_true("lampac-admin-chain" in sensitive, "Lampac sensitive paths must use protected middleware chain")
lampac_api_rule = lampac_labels.get("traefik.http.routers.lampac-api.rule", "")
lampac_sensitive_rule = lampac_labels.get("traefik.http.routers.lampac-sensitive.rule", "")
assert_true("reqinfo" in lampac_api_rule, "Lampac /reqinfo must remain public for the browser frontend")
assert_true("reqinfo" not in lampac_sensitive_rule, "Lampac /reqinfo must not trigger BasicAuth")
assert_true("testaccsdb" in lampac_api_rule, "Lampac /testaccsdb must remain public for shared_passwd registration")
assert_true("testaccsdb" not in lampac_sensitive_rule, "Lampac /testaccsdb must not trigger BasicAuth")
assert_true("online" in lampac_api_rule, "Lampac /online routes must remain public for online JS plugins")
assert_true("extensions" not in lampac_api_rule, "Lampac API router must not include obsolete /extensions path")
assert_true("weblog" in lampac_sensitive_rule, "Lampac /weblog must require BasicAuth")
auth_pages_rule = lampac_labels.get("traefik.http.routers.lampac-auth-pages.rule", "")
auth_pages_middlewares = lampac_labels.get("traefik.http.routers.lampac-auth-pages.middlewares", "")
auth_pages_priority = int(lampac_labels.get("traefik.http.routers.lampac-auth-pages.priority", "0"))
assert_true("adminpanel" in auth_pages_rule and "weblog" in auth_pages_rule and "/auth" in auth_pages_rule, "Lampac auth pages must bypass protected admin prefixes")
assert_true(auth_pages_middlewares == "lampac-headers", "Lampac auth pages must not use BasicAuth")
assert_true(auth_pages_priority > int(lampac_labels.get("traefik.http.routers.lampac-sensitive.priority", "0")), "Lampac auth pages must have higher priority than sensitive router")
assert_true("traefik.http.routers.lampac-admin.rule" not in lampac_labels, "Duplicated lampac-admin router must be removed")
for router in [
    "lampac-https",
    "lampac-proxy",
    "lampac-api",
    "lampac-sensitive",
    "lampac-auth-pages",
    "lampac-plugins",
    "lampac-ws",
    "lampac-static-js",
]:
    assert_true(
        lampac_labels.get(f"traefik.http.routers.{router}.tls.certresolver") == "le",
        f"{router} must explicitly use tls.certresolver=le",
    )
assert_true(
    "traefik.http.routers.lampac-unknown-host.tls.certresolver" not in lampac_labels,
    "Unknown-host fallback must not request ACME certificates for arbitrary hosts",
)
unknown_rule = lampac_labels.get("traefik.http.routers.lampac-unknown-host.rule", "")
unknown_middlewares = lampac_labels.get("traefik.http.routers.lampac-unknown-host.middlewares", "")
unknown_rewrite = lampac_labels.get("traefik.http.middlewares.lampac-unknown-root.replacepath.path", "")
assert_true("!Host(`${WEBDOMAIN}`)" in unknown_rule, "Unknown host fallback must not match the root domain")
assert_true("lampac-unknown-root" in unknown_middlewares, "Unknown host fallback must rewrite requests to Lampac root")
assert_true(unknown_rewrite == "/", "Unknown host fallback must rewrite every path to /")

caddy_compose = load_yaml("docker-proxy/compose.d/05-caddy.yml")
caddy_labels = labels_for(caddy_compose["services"]["caddy"])
caddy_rule = caddy_labels.get("traefik.http.routers.caddy-fallback.rule", "")
caddy_middlewares = caddy_labels.get("traefik.http.routers.caddy-fallback.middlewares", "")
caddy_priority = int(caddy_labels.get("traefik.http.routers.caddy-fallback.priority", "0"))
lampac_priority = int(lampac_labels.get("traefik.http.routers.lampac-https.priority", "0"))
assert_true(caddy_rule == "Host(`${WEBDOMAIN}`)", "Caddy must provide root-domain fallback when optional Lampac is absent")
assert_true(caddy_priority < lampac_priority, "Caddy fallback priority must be lower than Lampac public front")
assert_true("basic-auth" not in caddy_middlewares.lower(), "Caddy fallback must not use BasicAuth")
assert_true("bouncer" not in caddy_middlewares.lower(), "Caddy fallback must not use CrowdSec bouncer")

firewall_bouncer = load_yaml("docker-proxy/compose.d/04-crowdsec-firewall-bouncer.yml")["services"]["crowdsec-firewall-bouncer"]
for volume in [str(item) for item in (firewall_bouncer.get("volumes") or [])]:
    assert_true(
        "firewall-bouncer.log:/var/log/crowdsec-firewall-bouncer.log" not in volume,
        "CrowdSec firewall bouncer must mount a log directory, not a single rotating log file",
    )

admin_cases = [
    ("06-traefik.yml", "traefik", "traefik.http.routers.traefik-dashboard-prefixed.middlewares"),
    ("07-dozzle.yml", "dozzle", "traefik.http.routers.dozzle-router.middlewares"),
    ("07-dozzle.yml", "dozzle", "traefik.http.routers.dozzle-api.middlewares"),
    ("10-adguard.yml", "adguard", "traefik.http.routers.adguard-panel.middlewares"),
    ("12-3x-ui.yml", "3x-ui", "traefik.http.routers.3xui-panel.middlewares"),
    ("13-homepage.yml", "homepage", "traefik.http.routers.homepage-router.middlewares"),
    ("14-lampac.yml", "lampac", "traefik.http.routers.lampac-sensitive.middlewares"),
]
admin_domains = [
    "TRAEFIK_ADMIN_DOMAIN",
    "DOZZLE_ADMIN_DOMAIN",
    "ADGUARD_ADMIN_DOMAIN",
    "XUI_ADMIN_DOMAIN",
    "HOMEPAGE_ADMIN_DOMAIN",
    "LAMPAC_ADMIN_DOMAIN",
]
for file_name, service_name, key in admin_cases:
    service_labels = labels_for(load_yaml(f"docker-proxy/compose.d/{file_name}")["services"][service_name])
    middleware = service_labels.get(key, "")
    assert_true(middleware, f"{key} must define admin middleware")
    chain_parts = [middleware]
    for name in [part.strip() for part in middleware.split(",") if part.strip()]:
        chain_key = f"traefik.http.middlewares.{name}.chain.middlewares"
        chain_parts.append(service_labels.get(chain_key) or traefik_labels.get(chain_key) or "")
    chain = ",".join(chain_parts)
    assert_true("basic-auth" in chain or "auth" in chain, f"{key} must require BasicAuth")
    assert_true("bouncer@file" in chain, f"{key} must include CrowdSec bouncer")
    assert_true("rate" in chain or "ratelimit" in chain, f"{key} must include rate limiting")
    assert_true("security" in chain or "noindex" in chain or "headers" in chain, f"{key} must include security/noindex headers")

for file_name, service_name, key in [
    ("06-traefik.yml", "traefik", "traefik.http.routers.traefik-dashboard-prefixed.rule"),
    ("07-dozzle.yml", "dozzle", "traefik.http.routers.dozzle-router.rule"),
    ("10-adguard.yml", "adguard", "traefik.http.routers.adguard-panel.rule"),
    ("12-3x-ui.yml", "3x-ui", "traefik.http.routers.3xui-panel.rule"),
    ("13-homepage.yml", "homepage", "traefik.http.routers.homepage-router.rule"),
    ("14-lampac.yml", "lampac", "traefik.http.routers.lampac-sensitive.rule"),
]:
    service_labels = labels_for(load_yaml(f"docker-proxy/compose.d/{file_name}")["services"][service_name])
    rule = service_labels.get(key, "")
    assert_true("Host(`${WEBDOMAIN}`)" in rule and "Path" in rule, f"{key} must use WEBDOMAIN path routing")
    for admin_domain in admin_domains:
        assert_true(admin_domain not in rule, f"{key} must not use separate admin subdomains")

for compose_path in sorted((root / "docker-proxy/compose.d").glob("*.yml")):
    data = load_yaml(compose_path.relative_to(root))
    for service_name, service in (data.get("services") or {}).items():
        ports = [str(port) for port in (service.get("ports") or [])]
        for port in ports:
            assert_true("/udp" not in port or not port.startswith("443:"), f"443/udp must be unused before AmneziaWG stage: {compose_path}:{service_name}:{port}")

print("stage tcp clean architecture assertions OK")
PY
}

run_python_check || fail "stage TCP clean architecture assertions failed"
