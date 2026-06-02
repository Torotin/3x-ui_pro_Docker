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

def homepage_services():
    return load_yaml("docker-proxy/homepage/services.yaml")

def find_homepage_service(group_name, service_name):
    for group in homepage_services():
        if group_name not in group:
            continue
        for item in group[group_name] or []:
            if service_name in item:
                return item[service_name] or {}
    raise AssertionError(f"Homepage service not found: {group_name}/{service_name}")

def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)

traefik_compose = load_yaml("docker-proxy/compose.d/06-traefik.yml")
traefik_service = traefik_compose["services"]["traefik"]
traefik_ports = [str(port) for port in (traefik_service.get("ports") or [])]
assert_true(traefik_ports == ["80:80"], f"Traefik must publish only 80:80, got {traefik_ports}")
file_http = load_yaml("docker-proxy/traefik/dynamic/crowdsec.yml").get("http") or {}
file_middlewares = file_http.get("middlewares") or {}
file_transports = file_http.get("serversTransports") or {}
assert_true("admin-security-headers" in file_middlewares, "admin-security-headers must be defined by the file provider")
assert_true(
    (file_transports.get("grpc3xui-transport") or {}).get("insecureSkipVerify") is True,
    "VLESS gRPC serversTransport must be defined by the file provider",
)
assert_true(
    (file_transports.get("grpc3xui-transport") or {}).get("serverName") == '{{ env "WEBDOMAIN" }}',
    "VLESS gRPC serversTransport must use the managed domain as upstream SNI",
)

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
        assert_true("Host(`${WEBDOMAIN}`) && PathPrefix(`/dashboard`)" not in value, "Traefik dashboard must not expose root-domain /dashboard")

root_api_rule = traefik_labels.get("traefik.http.routers.traefik-dashboard-api-root.rule", "")
root_api_middlewares = traefik_labels.get("traefik.http.routers.traefik-dashboard-api-root.middlewares", "")
root_api_service = traefik_labels.get("traefik.http.routers.traefik-dashboard-api-root.service", "")
assert_true(root_api_rule == "Host(`${WEBDOMAIN}`) && PathPrefix(`/api`)", "Traefik dashboard root /api must route to api@internal")
assert_true(root_api_middlewares == "secured-chain", "Traefik dashboard root /api must keep admin protection")
assert_true(root_api_service == "api@internal", "Traefik dashboard root /api must use api@internal")

homepage_compose = load_yaml("docker-proxy/compose.d/13-homepage.yml")
homepage_labels = labels_for(homepage_compose["services"]["homepage"])
homepage_static_rule = homepage_labels.get("traefik.http.routers.homepage-static.rule", "")
homepage_static_service = homepage_labels.get("traefik.http.routers.homepage-static.service", "")
homepage_static_priority = int(homepage_labels.get("traefik.http.routers.homepage-static.priority", "0"))
root_api_priority = int(traefik_labels.get("traefik.http.routers.traefik-dashboard-api-root.priority", "0"))
assert_true("PathPrefix(`/api/docker`)" in homepage_static_rule, "Homepage Docker stats API must route to Homepage, not Traefik dashboard /api")
assert_true(homepage_static_service == "homepage-svc", "Homepage static/API router must use homepage-svc")
assert_true(homepage_static_priority > root_api_priority, "Homepage root /api routes must outrank Traefik dashboard root /api")
traefik_homepage_card = find_homepage_service("Admin", "Traefik Dashboard")
traefik_homepage_widget = traefik_homepage_card.get("widget") or {}
assert_true(
    traefik_homepage_widget.get("url") == "https://{{HOMEPAGE_VAR_WEBDOMAIN}}:4443/{{HOMEPAGE_VAR_URI_TRAEFIK_DASHBOARD}}",
    "Homepage Traefik widget must use the internal Traefik websecure port with the public hostname",
)
assert_true(
    traefik_homepage_widget.get("username") == "{{HOMEPAGE_VAR_USER_WEB}}" and traefik_homepage_widget.get("password") == "{{HOMEPAGE_VAR_PASS_WEB}}",
    "Homepage Traefik widget must authenticate through the existing web credentials",
)
telemt_homepage_card = find_homepage_service("Admin", "Telemt Panel")
assert_true(
    telemt_homepage_card.get("container") == "telemt",
    "Homepage Telemt card must follow the bundled panel container",
)

xui_compose = load_yaml("docker-proxy/compose.d/12-3x-ui.yml")
xui_service = xui_compose["services"]["3x-ui"]
xui_ports = [str(port) for port in (xui_service.get("ports") or [])]
assert_true(
    xui_ports == ["443:${PORT_LOCAL_VISION:-443}/tcp", "443:${PORT_LOCAL_HYSTERIA:-443}/udp"],
    f"3x-ui must publish Xray 443/tcp and accepted Hysteria2 443/udp, got {xui_ports}",
)
xui_volumes = [str(volume) for volume in (xui_service.get("volumes") or [])]
assert_true(
    "../traefik/pem:/etc/traefik/pem:ro" in xui_volumes,
    "3x-ui must mount exported Traefik PEM certificates read-only",
)
xui_labels = labels_for(xui_service)
for key, value in xui_labels.items():
    assert_true("traefik.tcp." not in key, f"3x-ui Traefik TCP label must be removed: {key}")
    assert_true("traefik.udp." not in key, f"3x-ui Traefik UDP label must be removed: {key}")
    assert_true(value != "l4tcp", "No 3x-ui HTTP router may use l4tcp")
panel_priority = int(xui_labels.get("traefik.http.routers.3xui-panel.priority", "0"))
api_rule = xui_labels.get("traefik.http.routers.3xui-api.rule", "")
api_middlewares = xui_labels.get("traefik.http.routers.3xui-api.middlewares", "")
api_priority = int(xui_labels.get("traefik.http.routers.3xui-api.priority", "0"))
assert_true(
    api_rule == "Host(`${WEBDOMAIN}`) && PathPrefix(`/${URI_PANEL_PATH}/panel/api`)",
    "3x-ui Bearer API must have a dedicated base-path API router",
)
assert_true(api_middlewares == "bouncer@file,3xui-api-chain", "3x-ui Bearer API router must avoid panel BasicAuth")
assert_true("3xui-basic-auth" not in xui_labels.get("traefik.http.middlewares.3xui-api-chain.chain.middlewares", ""), "3x-ui API chain must not require BasicAuth")
assert_true(xui_labels.get("traefik.http.routers.3xui-api.service", "") == "3xui-panel-svc", "3x-ui API router must use panel service")
assert_true(xui_labels.get("traefik.http.routers.3xui-api.entrypoints", "") == "websecure", "3x-ui API router must use websecure")
assert_true(xui_labels.get("traefik.http.routers.3xui-api.tls.certresolver", "") == "le", "3x-ui API router must use TLS certificate resolver")
assert_true(api_priority > panel_priority, "3x-ui Bearer API router must outrank the BasicAuth panel router")
assert_true(
    xui_labels.get("traefik.http.services.grpc3xui-svc.loadbalancer.server.port") == "${PORT_LOCAL_GRPC}",
    "VLESS gRPC Traefik service must target the managed gRPC backend port",
)
assert_true(
    xui_labels.get("traefik.http.services.grpc3xui-svc.loadbalancer.server.scheme") == "https",
    "VLESS gRPC Traefik service must use HTTPS upstream to Xray",
)
assert_true(
    xui_labels.get("traefik.http.services.grpc3xui-svc.loadbalancer.serverstransport") == "grpc3xui-transport@file",
    "VLESS gRPC service must use the file-provider serversTransport",
)
grpc_rule = xui_labels.get("traefik.http.routers.grpc3xui.rule", "")
assert_true(
    grpc_rule == "Host(`${WEBDOMAIN}`) && PathPrefix(`${URI_VLESS_GRPC}`)",
    "VLESS gRPC router must use the generated gRPC path",
)
assert_true(xui_labels.get("traefik.http.routers.grpc3xui.service") == "grpc3xui-svc", "VLESS gRPC router must use grpc3xui-svc")

telemt_compose = load_yaml("docker-proxy/compose.d/15-telemt.yml")
assert_true("telemt-panel" not in telemt_compose["services"], "Telemt panel must run inside the single telemt container")
telemt_service = telemt_compose["services"]["telemt"]
telemt_ports = [str(port) for port in (telemt_service.get("ports") or [])]
telemt_expose = [str(port) for port in (telemt_service.get("expose") or [])]
assert_true(not telemt_ports, f"Telemt must not publish host ports, got {telemt_ports}")
assert_true(
    telemt_service.get("image") == "${TELEMT_STACK_IMAGE:-torotin/telemt-stack:latest}",
    "Telemt must use the AutoDockerBuilder stack image with an env override",
)
assert_true("build" not in telemt_service, "Telemt stack must not build a local panel image")
assert_true(telemt_service.get("init") is True, "Telemt stack must use an init process for its bundled children")
assert_true("${DOCKER_SOCKET_GID:-0}" in [str(group) for group in (telemt_service.get("group_add") or [])], "Telemt stack must join the Docker socket group for panel Logs UI")
assert_true(
    set(telemt_expose) == {
        "${PORT_LOCAL_TELEMT_PROXY:-9443}",
        "${PORT_LOCAL_TELEMT_API:-9091}",
        "${PORT_LOCAL_TELEMT_METRICS:-9090}",
        "${PORT_LOCAL_TELEMT_PANEL:-8080}",
    },
    f"Telemt must expose only its four internal endpoints, got {telemt_expose}",
)
telemt_volumes = [str(volume) for volume in (telemt_service.get("volumes") or [])]
assert_true("../telemt-panel/config:/etc/telemt-panel:ro" in telemt_volumes, "Bundled panel must receive its rendered config")
assert_true("../telemt-panel/data:/var/lib/telemt-panel:rw" in telemt_volumes, "Bundled panel must retain persistent data")
assert_true("/var/run/docker.sock:/var/run/docker.sock:ro" in telemt_volumes, "Bundled panel Logs UI must receive read-only Docker socket access")
telemt_healthcheck = " ".join(str(part) for part in ((telemt_service.get("healthcheck") or {}).get("test") or []))
assert_true("/usr/local/bin/telemt healthcheck /etc/telemt/config.toml --mode liveness" in telemt_healthcheck, "Telemt stack healthcheck must verify Telemt liveness")
assert_true("curl -fsS http://127.0.0.1:${PORT_LOCAL_TELEMT_PANEL:-8080}/${URI_TELEMT_PANEL}/" in telemt_healthcheck, "Telemt stack healthcheck must verify bundled panel readiness")
telemt_labels = labels_for(telemt_service)
telemt_panel_rule = telemt_labels.get("traefik.http.routers.telemt-panel.rule", "")
telemt_panel_middlewares = telemt_labels.get("traefik.http.routers.telemt-panel.middlewares", "")
assert_true("Host(`${WEBDOMAIN}`)" in telemt_panel_rule and "PathPrefix(`/${URI_TELEMT_PANEL}`)" in telemt_panel_rule, "Telemt panel must be routed by WEBDOMAIN path")
assert_true("telemt-panel-chain" in telemt_panel_middlewares, "Telemt panel must use the protected admin middleware chain")

telemt_template = (root / "script/template/telemt.config.toml.template").read_text(encoding="utf-8")
assert_true('proxy_protocol = true' in telemt_template, "Telemt must accept PROXY protocol from Xray")
assert_true('"172.18.0.0/24"' in telemt_template, "Telemt must trust the internal Traefik/Xray network for PROXY protocol")
assert_true('"172.19.0.0/24"' in telemt_template, "Telemt must trust the internal DNS/Xray network for PROXY protocol")
assert_true('unknown_sni_action = "mask"' in telemt_template, "Telemt unknown SNI action must mask to Traefik")
assert_true('mask_host = "traefik"' in telemt_template and 'mask_port = 4443' in telemt_template, "Telemt mask fallback must point to traefik:4443")
assert_true('mask_proxy_protocol = 1' in telemt_template, "Telemt must forward PROXY protocol to Traefik")
assert_true('middle_proxy_pool_size = ${TELEMT_MIDDLE_PROXY_POOL_SIZE}' in telemt_template, "Telemt balanced tuning must expose ME pool size")
assert_true('me_reconnect_backoff_cap_ms = ${TELEMT_ME_RECONNECT_BACKOFF_CAP_MS}' in telemt_template, "Telemt balanced tuning must expose ME reconnect backoff cap")
assert_true('[timeouts]' in telemt_template and 'me_one_retry = ${TELEMT_ME_ONE_RETRY}' in telemt_template, "Telemt balanced tuning must define timeout overrides")
assert_true('[network]' in telemt_template and 'stun_use = ${TELEMT_STUN_USE}' in telemt_template, "Telemt balanced tuning must define network/STUN overrides")
assert_true('stun_servers = ["${TELEMT_STUN_SERVER_1_TOML}", "${TELEMT_STUN_SERVER_2_TOML}"]' in telemt_template, "Telemt STUN servers must render as TOML array, not env JSON")
assert_true('http_ip_detect_urls = ["${TELEMT_HTTP_IP_DETECT_URL_1_TOML}", "${TELEMT_HTTP_IP_DETECT_URL_2_TOML}"]' in telemt_template, "Telemt HTTP IP detect URLs must render as TOML array, not env JSON")
assert_true('max_connections = ${TELEMT_MAX_CONNECTIONS}' in telemt_template, "Telemt balanced tuning must expose max_connections")
assert_true('[server.conntrack_control]' in telemt_template, "Telemt must explicitly configure conntrack-control policy")
assert_true('inline_conntrack_control = false' in telemt_template and 'mode = "tracked"' in telemt_template, "Telemt must remain locked down without NET_ADMIN/notrack")
assert_true('mask_shape_hardening = ${TELEMT_MASK_SHAPE_HARDENING}' in telemt_template, "Telemt balanced tuning must expose mask hardening")
assert_true('[[upstreams]]' in telemt_template and 'type = "direct"' in telemt_template, "Telemt must explicitly define direct upstream")

telemt_panel_template = (root / "script/template/telemt-panel.config.toml.template").read_text(encoding="utf-8")
assert_true('container_name = "telemt"' in telemt_panel_template, "Bundled panel Logs UI must target the telemt Docker container")
assert_true('binary_path = "/usr/local/bin/telemt"' in telemt_panel_template, "Bundled panel must use the image-provided Telemt binary")
assert_true('binary_path = "/usr/local/bin/telemt-panel"' in telemt_panel_template, "Bundled panel must record the image-provided panel binary")

install_env_template = (root / "script/template/install.env.template").read_text(encoding="utf-8")
docker_env_template = (root / "script/template/docker.env.template").read_text(encoding="utf-8")
for env_template_name, env_template in [("install.env.template", install_env_template), ("docker.env.template", docker_env_template)]:
    assert_true("TELEMT_STACK_IMAGE=${TELEMT_STACK_IMAGE}" in env_template, f"{env_template_name} must persist the telemt-stack image override")
    assert_true("DOCKER_SOCKET_GID=${DOCKER_SOCKET_GID}" in env_template, f"{env_template_name} must persist the Docker socket group id")
    assert_true("TELEMT_PANEL_VERSION=" not in env_template, f"{env_template_name} must not persist the retired panel build version")
    assert_true("TELEMT_TUNING_PROFILE=${TELEMT_TUNING_PROFILE}" in env_template, f"{env_template_name} must persist TELEMT_TUNING_PROFILE")
    assert_true("TELEMT_MIDDLE_PROXY_POOL_SIZE=${TELEMT_MIDDLE_PROXY_POOL_SIZE}" in env_template, f"{env_template_name} must persist ME pool size")
    assert_true('TELEMT_STUN_SERVERS_JSON="${TELEMT_STUN_SERVERS_JSON_ENV}"' in env_template, f"{env_template_name} must persist STUN server list as dotenv-safe quoted JSON")
    assert_true("TELEMT_MASK_RELAY_TIMEOUT_MS=${TELEMT_MASK_RELAY_TIMEOUT_MS}" in env_template, f"{env_template_name} must persist mask relay timeout")
    assert_true("TELEMT_MAX_CONNECTIONS=${TELEMT_MAX_CONNECTIONS}" in env_template, f"{env_template_name} must persist max_connections")
    assert_true("URI_VLESS_GRPC=" in env_template, f"{env_template_name} must persist VLESS gRPC path")
    assert_true("PORT_LOCAL_GRPC=${PORT_LOCAL_GRPC}" in env_template, f"{env_template_name} must persist VLESS gRPC backend port")
    assert_true("PORT_LOCAL_HYSTERIA=${PORT_LOCAL_HYSTERIA}" in env_template, f"{env_template_name} must persist Hysteria2 UDP port")
    assert_true("ENABLE_VLESS_GRPC=${ENABLE_VLESS_GRPC}" in env_template, f"{env_template_name} must persist VLESS gRPC enable flag")
    assert_true("ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2}" in env_template, f"{env_template_name} must persist Hysteria2 enable flag")
    assert_true("XRAY_TLS_CERT_FILE=${XRAY_TLS_CERT_FILE}" in env_template, f"{env_template_name} must persist Xray TLS cert path")
    assert_true("XRAY_TLS_KEY_FILE=${XRAY_TLS_KEY_FILE}" in env_template, f"{env_template_name} must persist Xray TLS key path")

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
    ("15-telemt.yml", "telemt", "traefik.http.routers.telemt-panel.middlewares"),
]
admin_domains = [
    "TRAEFIK_ADMIN_DOMAIN",
    "DOZZLE_ADMIN_DOMAIN",
    "ADGUARD_ADMIN_DOMAIN",
    "XUI_ADMIN_DOMAIN",
    "HOMEPAGE_ADMIN_DOMAIN",
    "LAMPAC_ADMIN_DOMAIN",
]
shared_header_cases = {
    "traefik.http.routers.traefik-dashboard-prefixed.middlewares",
    "traefik.http.routers.dozzle-router.middlewares",
    "traefik.http.routers.dozzle-api.middlewares",
    "traefik.http.routers.adguard-panel.middlewares",
    "traefik.http.routers.homepage-router.middlewares",
}
for file_name, service_name, key in admin_cases:
    service_labels = labels_for(load_yaml(f"docker-proxy/compose.d/{file_name}")["services"][service_name])
    middleware = service_labels.get(key, "")
    assert_true(middleware, f"{key} must define admin middleware")
    chain_parts = [middleware]
    for name in [part.strip() for part in middleware.split(",") if part.strip()]:
        chain_key = f"traefik.http.middlewares.{name}.chain.middlewares"
        chain_parts.append(service_labels.get(chain_key) or traefik_labels.get(chain_key) or "")
    chain = ",".join(chain_parts)
    if key in shared_header_cases:
        assert_true(
            "admin-security-headers@file" in chain,
            f"{key} must reference admin-security-headers through the file provider",
        )
    assert_true(
        "admin-security-headers," not in f"{chain}," and "admin-security-headers@docker" not in chain,
        f"{key} must not reference bare/docker admin-security-headers",
    )
    assert_true("basic-auth" in chain or "auth" in chain, f"{key} must require BasicAuth")
    assert_true("bouncer@file" in chain, f"{key} must include CrowdSec bouncer")
    assert_true("rate" in chain or "ratelimit" in chain, f"{key} must include rate limiting")
    assert_true("security" in chain or "noindex" in chain or "headers" in chain, f"{key} must include security/noindex headers")

manifest_middleware = traefik_labels.get("traefik.http.routers.traefik-dashboard-manifest.middlewares", "")
assert_true(manifest_middleware, "Traefik dashboard manifest router must define middleware")
manifest_chain_parts = [manifest_middleware]
for name in [part.strip() for part in manifest_middleware.split(",") if part.strip()]:
    chain_key = f"traefik.http.middlewares.{name}.chain.middlewares"
    manifest_chain_parts.append(traefik_labels.get(chain_key) or "")
manifest_chain = ",".join(manifest_chain_parts)
assert_true("basic-auth" not in manifest_chain, "Traefik dashboard manifest must not require BasicAuth")
assert_true("bouncer@file" in manifest_chain, "Traefik dashboard manifest must include CrowdSec bouncer")
assert_true("rate" in manifest_chain or "ratelimit" in manifest_chain, "Traefik dashboard manifest must include rate limiting")
assert_true("admin-security-headers@file" in manifest_chain, "Traefik dashboard manifest must include admin security headers")
assert_true("dash-strip-prefix" in manifest_chain, "Traefik dashboard manifest must strip the dashboard prefix")

for file_name, service_name, key in [
    ("06-traefik.yml", "traefik", "traefik.http.routers.traefik-dashboard-prefixed.rule"),
    ("07-dozzle.yml", "dozzle", "traefik.http.routers.dozzle-router.rule"),
    ("10-adguard.yml", "adguard", "traefik.http.routers.adguard-panel.rule"),
    ("12-3x-ui.yml", "3x-ui", "traefik.http.routers.3xui-panel.rule"),
    ("13-homepage.yml", "homepage", "traefik.http.routers.homepage-router.rule"),
    ("14-lampac.yml", "lampac", "traefik.http.routers.lampac-sensitive.rule"),
    ("15-telemt.yml", "telemt", "traefik.http.routers.telemt-panel.rule"),
    ("16-mihomo.yml", "mihomo", "traefik.http.routers.mihomo-ui.rule"),
]:
    service_labels = labels_for(load_yaml(f"docker-proxy/compose.d/{file_name}")["services"][service_name])
    rule = service_labels.get(key, "")
    assert_true("Host(`${WEBDOMAIN}`)" in rule and "Path" in rule, f"{key} must use WEBDOMAIN path routing")
    for admin_domain in admin_domains:
        assert_true(admin_domain not in rule, f"{key} must not use separate admin subdomains")

mihomo_labels = labels_for(load_yaml("docker-proxy/compose.d/16-mihomo.yml")["services"]["mihomo"])
assert_true(mihomo_labels.get("traefik.enable") == "true", "Mihomo must enable Traefik explicitly")
assert_true(mihomo_labels.get("traefik.docker.network") == "traefik-proxy", "Mihomo must pin Traefik to traefik-proxy")
assert_true(mihomo_labels.get("traefik.tags") == "traefik", "Mihomo must match the Docker provider constraint")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui.entrypoints") == "websecure", "Mihomo UI must use websecure")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui.tls.certresolver") == "le", "Mihomo UI must use the LE resolver")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui.service") == "mihomo-ui-svc", "Mihomo UI router must target the named service")
assert_true(mihomo_labels.get("traefik.http.services.mihomo-ui-svc.loadbalancer.server.port") == "9090", "Mihomo UI service must point to controller port 9090")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.rule") == "Host(`${WEBDOMAIN}`) && PathRegexp(`/${URI_MIHOMO}/ui/.*manifest(\\.webmanifest|\\.json)$$`)", "Mihomo manifest router must match UI manifests")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.entrypoints") == "websecure", "Mihomo manifest router must use websecure")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.middlewares") == "mihomo-manifest-chain", "Mihomo manifest router must use manifest chain")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.tls.certresolver") == "le", "Mihomo manifest router must use the LE resolver")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.service") == "mihomo-ui-svc", "Mihomo manifest router must target the named service")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-manifest.priority") == "974", "Mihomo manifest router must outrank UI slash/static routers")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.rule") == "Host(`${WEBDOMAIN}`) && PathPrefix(`/${URI_MIHOMO}/ui`)", "Mihomo static UI router must match /ui assets")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.entrypoints") == "websecure", "Mihomo static UI router must use websecure")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.middlewares") == "mihomo-static-chain", "Mihomo static UI router must use the static chain")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.tls.certresolver") == "le", "Mihomo static UI router must use the LE resolver")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.service") == "mihomo-ui-svc", "Mihomo static UI router must target the named service")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-static.priority") == "972", "Mihomo static UI router must outrank root and API routers")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.rule") == "Host(`${WEBDOMAIN}`) && Path(`/${URI_MIHOMO}/ui`)", "Mihomo UI slash router must match only /ui without trailing slash")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.entrypoints") == "websecure", "Mihomo UI slash router must use websecure")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.middlewares") == "mihomo-ui-slash-chain", "Mihomo UI slash router must use the slash redirect chain")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.tls.certresolver") == "le", "Mihomo UI slash router must use the LE resolver")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.service") == "mihomo-ui-svc", "Mihomo UI slash router must target the named service")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-slash.priority") == "973", "Mihomo UI slash router must outrank static UI router")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.rule") == "Host(`${WEBDOMAIN}`) && (Path(`/${URI_MIHOMO}`) || Path(`/${URI_MIHOMO}/`))", "Mihomo root router must match only the prefixed root")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.entrypoints") == "websecure", "Mihomo root redirect must use websecure")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.middlewares") == "mihomo-root-chain", "Mihomo root redirect must use the root redirect chain")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.tls.certresolver") == "le", "Mihomo root redirect must use the LE resolver")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.service") == "mihomo-ui-svc", "Mihomo root redirect must target the named service")
assert_true(mihomo_labels.get("traefik.http.routers.mihomo-ui-root.priority") == "971", "Mihomo root redirect must outrank the API/UI prefix router")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-redirect.redirectRegex.regex") == "^https?://([^/]+)/${URI_MIHOMO}/?$$", "Mihomo root redirect regex must match only the prefixed root")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-redirect.redirectRegex.replacement") == "https://${WEBDOMAIN}/${URI_MIHOMO}/ui/#/setup?hostname=${WEBDOMAIN}&port=443&secondaryPath=/${URI_MIHOMO}", "Mihomo root redirect must point to Zashboard setup with secondaryPath")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-redirect.redirectRegex.permanent") == "true", "Mihomo root redirect must be permanent")
mihomo_root_chain = mihomo_labels.get("traefik.http.middlewares.mihomo-root-chain.chain.middlewares", "")
assert_true("bouncer@file" in mihomo_root_chain, "Mihomo root chain must include CrowdSec bouncer")
assert_true("mihomo-basic-auth" in mihomo_root_chain, "Mihomo root chain must include BasicAuth")
assert_true("mihomo-rate-limit" in mihomo_root_chain, "Mihomo root chain must include rate limiting")
assert_true("admin-security-headers@file" in mihomo_root_chain, "Mihomo root chain must include admin security headers")
assert_true("mihomo-ui-redirect" in mihomo_root_chain, "Mihomo root chain must redirect to /ui/")
assert_true("mihomo-strip" not in mihomo_root_chain, "Mihomo root redirect must run before stripPrefix")
mihomo_ui_slash_chain = mihomo_labels.get("traefik.http.middlewares.mihomo-ui-slash-chain.chain.middlewares", "")
assert_true("bouncer@file" in mihomo_ui_slash_chain, "Mihomo UI slash chain must include CrowdSec bouncer")
assert_true("mihomo-basic-auth" in mihomo_ui_slash_chain, "Mihomo UI slash chain must include BasicAuth")
assert_true("mihomo-rate-limit" in mihomo_ui_slash_chain, "Mihomo UI slash chain must include rate limiting")
assert_true("admin-security-headers@file" in mihomo_ui_slash_chain, "Mihomo UI slash chain must include admin security headers")
assert_true("mihomo-ui-slash-redirect" in mihomo_ui_slash_chain, "Mihomo UI slash chain must redirect to external /ui/")
assert_true("mihomo-strip" not in mihomo_ui_slash_chain, "Mihomo UI slash redirect must run before stripPrefix")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-slash-redirect.redirectRegex.regex") == "^https?://([^/]+)/${URI_MIHOMO}/ui$$", "Mihomo UI slash redirect regex must match only external /ui")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-slash-redirect.redirectRegex.replacement") == "https://${WEBDOMAIN}/${URI_MIHOMO}/ui/", "Mihomo UI slash redirect must preserve the route prefix")
assert_true(mihomo_labels.get("traefik.http.middlewares.mihomo-ui-slash-redirect.redirectRegex.permanent") == "true", "Mihomo UI slash redirect must be permanent")
mihomo_manifest_chain = mihomo_labels.get("traefik.http.middlewares.mihomo-manifest-chain.chain.middlewares", "")
assert_true("bouncer@file" in mihomo_manifest_chain, "Mihomo manifest chain must include CrowdSec bouncer")
assert_true("mihomo-basic-auth" not in mihomo_manifest_chain, "Mihomo manifests must not require BasicAuth")
assert_true("mihomo-rate-limit" in mihomo_manifest_chain, "Mihomo manifest chain must include rate limiting")
assert_true("admin-security-headers@file" in mihomo_manifest_chain, "Mihomo manifest chain must include admin security headers")
assert_true("mihomo-strip" in mihomo_manifest_chain, "Mihomo manifest chain must strip the route prefix")
assert_true("mihomo-compress" in mihomo_manifest_chain, "Mihomo manifest chain must include compression")
mihomo_static_chain = mihomo_labels.get("traefik.http.middlewares.mihomo-static-chain.chain.middlewares", "")
assert_true("bouncer@file" in mihomo_static_chain, "Mihomo static chain must include CrowdSec bouncer")
assert_true("mihomo-basic-auth" in mihomo_static_chain, "Mihomo static UI assets must require BasicAuth")
assert_true("mihomo-rate-limit" in mihomo_static_chain, "Mihomo static chain must include rate limiting")
assert_true("admin-security-headers@file" in mihomo_static_chain, "Mihomo static chain must include admin security headers")
assert_true("mihomo-strip" in mihomo_static_chain, "Mihomo static chain must strip the route prefix")
assert_true("mihomo-compress" in mihomo_static_chain, "Mihomo static chain must include compression")
mihomo_chain = mihomo_labels.get("traefik.http.middlewares.mihomo-chain.chain.middlewares", "")
assert_true("bouncer@file" in mihomo_chain, "Mihomo UI chain must include CrowdSec bouncer")
assert_true("mihomo-basic-auth" not in mihomo_chain, "Mihomo API chain must not block Bearer auth with BasicAuth")
assert_true("mihomo-rate-limit" in mihomo_chain, "Mihomo UI chain must include rate limiting")
assert_true("admin-security-headers@file" in mihomo_chain, "Mihomo UI chain must include admin security headers")
assert_true("mihomo-compress" in mihomo_chain, "Mihomo UI chain must include compression")

for compose_path in sorted((root / "docker-proxy/compose.d").glob("*.yml")):
    data = load_yaml(compose_path.relative_to(root))
    for service_name, service in (data.get("services") or {}).items():
        ports = [str(port) for port in (service.get("ports") or [])]
        for port in ports:
            if port.startswith("443:") and "/udp" in port:
                assert_true(
                    compose_path.name == "12-3x-ui.yml" and service_name == "3x-ui" and port == "443:${PORT_LOCAL_HYSTERIA:-443}/udp",
                    f"443/udp must belong only to accepted Hysteria2 stage: {compose_path}:{service_name}:{port}",
                )

print("stage tcp clean architecture assertions OK")
PY
}

run_python_check || fail "stage TCP clean architecture assertions failed"
