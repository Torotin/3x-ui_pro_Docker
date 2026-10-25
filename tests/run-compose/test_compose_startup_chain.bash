#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE_DIR="$ROOT_DIR/docker-proxy/compose.d"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

compose_value() {
	local filter=$1 file=$2
	yq -r "$filter" "$file"
}

assert_depends_on_healthy() {
	local file=$1 service=$2 dependency=$3 condition
	condition=$(compose_value ".services.\"$service\".depends_on.\"$dependency\".condition // \"\"" "$file")
	[[ "$condition" == "service_healthy" ]] ||
		fail "$service must wait for healthy $dependency in $file; got '${condition:-<missing>}'"
}

assert_has_healthcheck() {
	local file=$1 service=$2 has_healthcheck
	has_healthcheck=$(compose_value ".services.\"$service\" | has(\"healthcheck\")" "$file")
	[[ "$has_healthcheck" == "true" ]] || fail "$service must define a healthcheck in $file"
}

require_tool yq

assert_has_healthcheck "$COMPOSE_DIR/13-homepage.yml" homepage
assert_has_healthcheck "$COMPOSE_DIR/14-lampac.yml" lampac
assert_has_healthcheck "$COMPOSE_DIR/09-usque.yml" usque

lampac_fix_perms_restart=$(compose_value '.services."lampac-fix-perms".restart // ""' "$COMPOSE_DIR/14-lampac.yml")
[[ "$lampac_fix_perms_restart" == "no" ]] ||
	fail "lampac-fix-perms must use restart: no so the oneshot exits; got '${lampac_fix_perms_restart:-<missing>}'"
lampac_waits_fix_perms=$(compose_value '.services.lampac.depends_on."lampac-fix-perms".condition // ""' "$COMPOSE_DIR/14-lampac.yml")
[[ "$lampac_waits_fix_perms" == "service_completed_successfully" ]] ||
	fail "lampac must wait for lampac-fix-perms to complete successfully; got '${lampac_waits_fix_perms:-<missing>}'"

assert_has_healthcheck "$COMPOSE_DIR/11-tor-proxy.yml" tor-proxy
[[ ! -e "$COMPOSE_DIR/08-warp.yml" ]] ||
	fail "retired warp compose fragment must be absent"
adguard_healthcheck=$(compose_value '.services.adguard.healthcheck.test | join(" ")' "$COMPOSE_DIR/10-adguard.yml")
case "$adguard_healthcheck" in
	*127.0.0.1*80*) ;;
	*) fail "adguard healthcheck must verify local HTTP readiness instead of external DNS; got '$adguard_healthcheck'" ;;
esac

legacy_torproxy=$(compose_value '.services | has("torproxy")' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$legacy_torproxy" == "false" ]] ||
	fail "retired torproxy service must be absent"

tor_image=$(compose_value '.services."tor-proxy".image // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$tor_image" == "torotin/tor-proxy:latest" ]] ||
	fail "tor-proxy must use torotin/tor-proxy:latest; got '${tor_image:-<missing>}'"

tor_start_period=$(compose_value '.services."tor-proxy".healthcheck.start_period // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$tor_start_period" == "3m" ]] ||
	fail "tor-proxy healthcheck start_period must allow bridge bootstrap; got '${tor_start_period:-<missing>}'"

tor_ipv6_env=$(compose_value '.services."tor-proxy".environment.TOR_IPV6_AVAILABLE // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$tor_ipv6_env" == '${TOR_IPV6_AVAILABLE:-false}' ]] ||
	fail "tor-proxy TOR_IPV6_AVAILABLE must come from compose env; got '${tor_ipv6_env:-<missing>}'"

tor_public_ip=$(compose_value '.services."tor-proxy".networks."traefik-proxy".ipv4_address // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
tor_dns_ip=$(compose_value '.services."tor-proxy".networks."dns-net".ipv4_address // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
tor_public_ipv6=$(compose_value '.services."tor-proxy".networks."traefik-proxy".ipv6_address // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
tor_dns_ipv6=$(compose_value '.services."tor-proxy".networks."dns-net".ipv6_address // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$tor_public_ip" == "172.18.0.11" && "$tor_dns_ip" == "172.19.0.11" &&
	"$tor_public_ipv6" == "fd00:dead:beef:12::11" && "$tor_dns_ipv6" == "fd00:dead:beef:13::11" ]] ||
	fail "tor-proxy must join both existing networks with reserved v4/v6 addresses"

for dependency in crowdsec crowdsec-firewall-bouncer caddy dozzle adguard 3x-ui homepage usque tor-proxy; do
	assert_depends_on_healthy "$COMPOSE_DIR/06-traefik.yml" traefik "$dependency"
done
traefik_requires_legacy_torproxy=$(compose_value '.services.traefik.depends_on | has("torproxy")' "$COMPOSE_DIR/06-traefik.yml")
[[ "$traefik_requires_legacy_torproxy" == "false" ]] ||
	fail "traefik must not require retired torproxy service"
traefik_requires_warp=$(compose_value '.services.traefik.depends_on | has("warp")' "$COMPOSE_DIR/06-traefik.yml")
[[ "$traefik_requires_warp" == "false" ]] ||
	fail "traefik must not require retired warp service"
assert_depends_on_healthy "$COMPOSE_DIR/12-3x-ui.yml" 3x-ui usque
xui_requires_warp=$(compose_value '.services."3x-ui".depends_on | has("warp")' "$COMPOSE_DIR/12-3x-ui.yml")
[[ "$xui_requires_warp" == "false" ]] ||
	fail "3x-ui must not require retired warp service"

traefik_requires_lampac=$(compose_value '.services.traefik.depends_on | has("lampac")' "$COMPOSE_DIR/06-traefik.yml")
[[ "$traefik_requires_lampac" == "false" ]] ||
	fail "traefik must not require optional lampac because 14-lampac.yml may be absent"

usque_start_period=$(compose_value '.services.usque.healthcheck.start_period // ""' "$COMPOSE_DIR/09-usque.yml")
[[ "$usque_start_period" == "60s" ]] ||
	fail "usque healthcheck start_period must tolerate slow proxy bootstrap; got '${usque_start_period:-<missing>}'"

assert_depends_on_healthy "$COMPOSE_DIR/06-traefik-pem-export.yml" traefik-acme-exporter traefik
exporter_interval=$(compose_value '.services."traefik-acme-exporter".healthcheck.interval // ""' "$COMPOSE_DIR/06-traefik-pem-export.yml")
[[ "$exporter_interval" == "30s" ]] ||
	fail "traefik-acme-exporter healthcheck interval must be 30s for quick final startup confirmation; got '${exporter_interval:-<missing>}'"

printf 'test_compose_startup_chain.bash: OK\n'
