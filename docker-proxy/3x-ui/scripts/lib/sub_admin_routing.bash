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

# Managed inbound remark slugs used to recognize subscription proxy nodes.
_clash_managed_inbound_remark_slug_pattern() {
	printf '%s' 'vless-tcp-reality|vless-xhttp|vless-grpc-tls|hysteria2|managed:'
}

# Normalizes remark/proxy name lines for AUTO/PROXY membership (never emits DIRECT).
discover_clash_proxy_node_names_from_lines() {
	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		line=${line//$'\r'/}
		[[ -n "${line//[[:space:]]/}" ]] || continue
		[[ "$line" == "DIRECT" ]] && continue
		printf '%s\n' "$line"
	done
}

# Extracts proxy names from a Clash/Mihomo subscription YAML body (proxies: section only).
discover_clash_proxy_node_names_from_clash_body() {
	local clash_body_file=$1
	[[ -n "$clash_body_file" && -f "$clash_body_file" ]] || return 0
	discover_clash_proxy_node_names_from_lines < <(
		awk '
			/^proxies:[[:space:]]*$/ { in_proxies = 1; next }
			in_proxies && /^[^[:space:]#-]/ { in_proxies = 0 }
			in_proxies && /^[[:space:]]*-[[:space:]]*name:/ {
				sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
				gsub(/^[[:space:]]+|[[:space:]]+$/, "")
				gsub(/^["'\''"]|["'\''"]$/, "")
				if (length > 0) {
					print
				}
			}
		' "$clash_body_file"
	)
}

# Prints managed inbound remarks from a remarks file or panel inbound list JSON/API body.
# shellcheck disable=SC2120 # Optional positional overrides are used by callers/tests.
discover_clash_proxy_node_remark_lines() {
	local remarks_file=${1:-${CLASH_PROXY_NODE_REMARKS_FILE:-}}
	local inbounds_file=${2:-${CLASH_DISCOVERY_INBOUNDS_JSON_FILE:-}}

	if [[ -n "$remarks_file" && -f "$remarks_file" ]]; then
		cat "$remarks_file"
		return 0
	fi

	if [[ -n "$inbounds_file" && -f "$inbounds_file" ]]; then
		discover_clash_proxy_node_remark_lines_from_inbounds_json "$inbounds_file"
		return 0
	fi

	if [[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] &&
		jq -e '.success == true and (.obj | type) == "array"' "$HTTP_BODY_FILE" >/dev/null 2>&1; then
		discover_clash_proxy_node_remark_lines_from_inbounds_json "$HTTP_BODY_FILE"
		return 0
	fi

	return 0
}

discover_clash_proxy_node_remark_lines_from_inbounds_json() {
	local json_file=$1 slug_pattern
	slug_pattern=$(_clash_managed_inbound_remark_slug_pattern)
	jq -r --arg pattern "$slug_pattern" '
		(.obj // .)
		| if type == "array" then . else [.] end
		| .[]
		| .remark // empty
		| select(length > 0)
		| select(test($pattern))
	' "$json_file" | sort -u
}

# 3x-ui Clash export renames Reality/externalProxy nodes to remark-dest-email.
# Other managed inbounds keep the inbound remark as the proxy name.
clash_subscription_proxy_name_for_kind() {
	local kind=$1 remark=$2 webdomain=${3:-} email=${4:-}
	[[ -n "$remark" ]] || return 0
	case "$kind" in
	vision)
		# Panel Clash export: Reality/externalProxy node name is remark-email
		# (shared email already includes WEBDOMAIN prefix when configured).
		if [[ -n "$email" ]]; then
			printf '%s\n' "${remark}-${email}"
		else
			printf '%s\n' "$remark"
		fi
		;;
	*)
		printf '%s\n' "$remark"
		;;
	esac
}

# Map inbound remarks onto published Clash proxy names (exact, else unique remark- prefix).
map_clash_remarks_to_published_proxy_names() {
	local remarks_file=$1 body_file=$2
	local published remark matches match_count
	[[ -f "$remarks_file" && -f "$body_file" ]] || return 0
	published=$(discover_clash_proxy_node_names_from_clash_body "$body_file")
	[[ -n "$published" ]] || return 0
	while IFS= read -r remark || [[ -n "$remark" ]]; do
		remark=${remark//$'\r'/}
		[[ -n "${remark//[[:space:]]/}" ]] || continue
		[[ "$remark" == "DIRECT" ]] && continue
		if grep -Fxq -- "$remark" <<<"$published"; then
			printf '%s\n' "$remark"
			continue
		fi
		matches=$(grep -F -- "$remark-" <<<"$published" || true)
		match_count=$(grep -c . <<<"$matches" || true)
		if [[ "${match_count:-0}" -eq 1 ]]; then
			printf '%s\n' "$matches"
			continue
		fi
		# Fall back to the remark so callers can still omit groups on total miss later.
		printf '%s\n' "$remark"
	done <"$remarks_file"
}

# Prefer managed inbound remarks; when a Clash body is also available, remap to
# published proxy names (Reality/externalProxy may append -host-email). Else body-only.
discover_clash_proxy_node_names() {
	local clash_body_file=${1:-${CLASH_DISCOVERY_BODY_FILE:-}}
	local remark_lines remarks_file

	remark_lines=$(discover_clash_proxy_node_remark_lines)
	if [[ -n "$remark_lines" && -n "$clash_body_file" && -f "$clash_body_file" ]]; then
		remarks_file=$(mktemp)
		printf '%s\n' "$remark_lines" >"$remarks_file"
		map_clash_remarks_to_published_proxy_names "$remarks_file" "$clash_body_file"
		rm -f "$remarks_file"
		return 0
	fi

	if [[ -n "$remark_lines" ]]; then
		discover_clash_proxy_node_names_from_lines <<<"$remark_lines"
		return 0
	fi

	if [[ -n "$clash_body_file" && -f "$clash_body_file" ]]; then
		discover_clash_proxy_node_names_from_clash_body "$clash_body_file"
	fi
}

# Xray-style JSON subscription rules: keep admin FQDNs on proxy, all residual traffic direct.
build_admin_sub_json_rules() {
	local webdomain=$1
	[[ -n "$webdomain" ]] || {
		printf ''
		return 0
	}
	admin_sub_hostnames | jq -Rsc --arg domain "$webdomain" '
		(split("\n") | map(select(length > 0))) as $hosts
		| [
			{
				type: "field",
				domain: ($hosts | map("full:" + . + "." + $domain)),
				outboundTag: "proxy"
			},
			{
				type: "field",
				network: "tcp,udp",
				outboundTag: "direct"
			}
		]
	'
}

# Deprecated for desired apply: legacy Happ/INCY subJsonRoutingRules did not route JSON clients reliably.
# The managed runtime clears this panel field with CLEAR_SUB_JSON_ROUTING_RULES=true instead.
build_admin_sub_json_routing_rules() {
	printf ''
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
