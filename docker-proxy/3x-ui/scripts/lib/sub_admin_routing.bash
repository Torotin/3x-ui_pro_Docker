#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
	# shellcheck source=/dev/null
	. "$(dirname "${BASH_SOURCE[0]}")/log.bash"
fi

admin_sub_hostnames() {
	printf '%s\n' arcane homepage adguard 3x-ui traefik lampac-admin
}

admin_sub_clash_default_mode() {
	printf '%s\n' "rules-proxy"
}

# Live panel capability: json_routing_effective=no (see docs/superpowers/specs/2026-10-26-client-sub-admin-routing-capability.md).
build_admin_sub_json_routing_rules() {
	# Clash subClashRules is canonical for admin DNS/routing until JSON merge is proven effective.
	printf ''
}

build_admin_sub_clash_rules() {
	local webdomain=$1 public_ipv4=${2:-} mode=${3:-$(admin_sub_clash_default_mode)}
	local host
	local rules=$'rules:\n'
	local target=PROXY

	case "$mode" in
	rules-admin | full) target=ADMIN ;;
	rules-proxy) target=PROXY ;;
	*) die "build_admin_sub_clash_rules: unknown mode $mode" ;;
	esac

	if [[ "$target" == "ADMIN" ]]; then
		printf '%s\n' \
			'proxy-groups:' \
			'  - name: ADMIN' \
			'    type: select' \
			'    hidden: true' \
			'    proxies:' \
			'      - PROXY'
	fi

	if [[ -n "$public_ipv4" ]]; then
		printf '%s\n' 'hosts:'
		printf '  %s: %s\n' "$webdomain" "$public_ipv4"
		while IFS= read -r host; do
			printf '  %s.%s: %s\n' "$host" "$webdomain" "$public_ipv4"
		done < <(admin_sub_hostnames)
		printf '%s\n' 'dns:' '  fake-ip-filter:' "    - ${webdomain}" "    - \"+.${webdomain}\""
	fi

	printf '%s' "$rules"
	while IFS= read -r host; do
		printf '  - DOMAIN,%s.%s,%s\n' "$host" "$webdomain" "$target"
	done < <(admin_sub_hostnames)
	printf '  - MATCH,PROXY\n'
}
