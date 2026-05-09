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
adguard_healthcheck=$(compose_value '.services.adguard.healthcheck.test | join(" ")' "$COMPOSE_DIR/10-adguard.yml")
case "$adguard_healthcheck" in
	*127.0.0.1*80*) ;;
	*) fail "adguard healthcheck must verify local HTTP readiness instead of external DNS; got '$adguard_healthcheck'" ;;
esac

torproxy_start_period=$(compose_value '.services.torproxy.healthcheck.start_period // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$torproxy_start_period" == "5m" ]] ||
	fail "torproxy healthcheck start_period must allow slow first Tor bootstrap; got '${torproxy_start_period:-<missing>}'"

torproxy_retries=$(compose_value '.services.torproxy.healthcheck.retries // ""' "$COMPOSE_DIR/11-tor-proxy.yml")
[[ "$torproxy_retries" == "10" ]] ||
	fail "torproxy healthcheck retries must tolerate slow first Tor bootstrap; got '${torproxy_retries:-<missing>}'"

for dependency in crowdsec crowdsec-firewall-bouncer caddy dozzle adguard 3x-ui homepage lampac warp usque torproxy tor-proxy; do
	assert_depends_on_healthy "$COMPOSE_DIR/06-traefik.yml" traefik "$dependency"
done

assert_depends_on_healthy "$COMPOSE_DIR/06-traefik-pem-export.yml" traefik-acme-exporter traefik
exporter_interval=$(compose_value '.services."traefik-acme-exporter".healthcheck.interval // ""' "$COMPOSE_DIR/06-traefik-pem-export.yml")
[[ "$exporter_interval" == "30s" ]] ||
	fail "traefik-acme-exporter healthcheck interval must be 30s for quick final startup confirmation; got '${exporter_interval:-<missing>}'"

printf 'test_compose_startup_chain.bash: OK\n'
