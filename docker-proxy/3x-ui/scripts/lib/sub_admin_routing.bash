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

# Happ/INCY-style profile for subJsonRoutingRules (object, not Xray rules array).
# Live reference: DomainStrategy + DnsHosts + ProxySites + RouteOrder.
build_admin_sub_json_routing_rules() {
	local webdomain=$1 public_ipv4=${2:-}
	[[ -n "$webdomain" ]] || {
		printf ''
		return 0
	}
	admin_sub_hostnames | jq -Rsc --arg domain "$webdomain" --arg ip "$public_ipv4" '
		(split("\n") | map(select(length > 0))) as $hosts
		| {
			DomainStrategy: "AsIs",
			ProxySites: ($hosts | map("full:" + . + "." + $domain)),
			RouteOrder: "proxy-direct-block"
		}
		| if ($ip | length) > 0 then
			.DnsHosts = (
				([$domain] + ($hosts | map(. + "." + $domain)))
				| map({key: ., value: $ip})
				| from_entries
			)
		  else .
		  end
	'
}

# Full client dns block for subJsonDns (overrides baked profile dns when set).
build_admin_sub_json_dns() {
	local webdomain=$1 public_ipv4=${2:-}
	[[ -n "$webdomain" && -n "$public_ipv4" ]] || {
		printf ''
		return 0
	}
	admin_sub_hostnames | jq -Rsc --arg domain "$webdomain" --arg ip "$public_ipv4" '
		(split("\n") | map(select(length > 0))) as $hosts
		| {
			hosts: (
				([$domain] + ($hosts | map(. + "." + $domain)))
				| map({key: ., value: $ip})
				| from_entries
			),
			queryStrategy: "UseIP",
			servers: [
				{
					address: "8.8.8.8",
					skipFallback: false
				}
			],
			tag: "dns_out"
		}
	'
}

build_admin_sub_clash_rules() {
	local webdomain=$1 public_ipv4=${2:-} mode=${3:-$(admin_sub_clash_default_mode)} node_names_file=${4:-}
	local host node
	local -a nodes=()
	local rules=$'rules:\n'

	case "$mode" in
	rules-admin | full | rules-proxy) ;;
	*) die "build_admin_sub_clash_rules: unknown mode $mode" ;;
	esac

	if [[ -n "$node_names_file" && -f "$node_names_file" ]]; then
		while IFS= read -r node || [[ -n "$node" ]]; do
			node=${node//$'\r'/}
			[[ -n "${node//[[:space:]]/}" ]] || continue
			nodes+=("$node")
		done <"$node_names_file"
	fi

	if ((${#nodes[@]} > 0)); then
		printf '%s\n' \
			'proxy-groups:' \
			'  - name: AUTO' \
			'    type: url-test' \
			'    url: https://www.gstatic.com/generate_204' \
			'    interval: 300' \
			'    proxies:'
		for node in "${nodes[@]}"; do
			printf '      - %s\n' "$node"
		done
		printf '%s\n' \
			'  - name: PROXY' \
			'    type: select' \
			'    proxies:' \
			'      - AUTO'
		for node in "${nodes[@]}"; do
			printf '      - %s\n' "$node"
		done
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
		printf '  - DOMAIN,%s.%s,PROXY\n' "$host" "$webdomain"
	done < <(admin_sub_hostnames)
	printf '  - MATCH,DIRECT\n'
}
