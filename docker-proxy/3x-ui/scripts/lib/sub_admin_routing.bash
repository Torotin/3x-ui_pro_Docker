#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
	# shellcheck source=/dev/null
	. "$(dirname "${BASH_SOURCE[0]}")/log.bash"
fi

admin_sub_hostnames() {
	printf '%s\n' arcane homepage adguard 3x-ui traefik lampac-admin
}

build_admin_sub_clash_rules() {
	local webdomain=$1 public_ipv4=${2:-} mode=${3:-rules-proxy}
	local host fqdn
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

	if [[ "$mode" == "full" && -n "$public_ipv4" ]]; then
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
