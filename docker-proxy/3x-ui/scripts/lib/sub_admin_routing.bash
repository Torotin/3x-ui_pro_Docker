#!/usr/bin/env bash

if ! declare -F die >/dev/null 2>&1; then
	# shellcheck source=/dev/null
	. "$(dirname "${BASH_SOURCE[0]}")/log.bash"
fi

admin_sub_hostnames() {
	printf '%s\n' arcane homepage adguard 3x-ui traefik lampac-admin telemt
}

admin_sub_clash_default_mode() {
	printf '%s\n' "rules-proxy"
}

# Clash url-test group / JSON Sub Balancer remark: AUTO-<webdomain>.
admin_sub_auto_policy_name() {
	local domain=${1:-${WEBDOMAIN:-}}
	[[ -n "$domain" ]] || return 1
	printf 'AUTO-%s' "$domain"
}

# Clash select group (+ rule target): PROXY-<webdomain> (multi-server safe).
admin_sub_proxy_policy_name() {
	local domain=${1:-${WEBDOMAIN:-}}
	[[ -n "$domain" ]] || return 1
	printf 'PROXY-%s' "$domain"
}

# Managed inbound remark slugs used to recognize subscription proxy nodes.
_clash_managed_inbound_remark_slug_pattern() {
	printf '%s' 'vless-tcp-reality|vless-xhttp|vless-grpc-tls|hysteria2|amneziawg|managed:'
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
# Port 9443→proxy mirrors server admin-traefik: browsers/SOCKS often dial PUBLIC_IPV4:9443
# after DNS (system or client hosts), so domain rules alone miss and the residual DIRECT
# black-holes loopback-only admin entrypoints.
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
				port: "9443",
				network: "tcp",
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
# hosts→PUBLIC_IPV4 is required: admin labels are not always in public DNS (AdGuard/
# Traefik only). Pair with port:9443→proxy in build_admin_sub_json_rules so IP dials
# after this map still go through the tunnel (public :9443 is loopback-only).
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
	local host node auto_name proxy_name rule_proxy=PROXY
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
		auto_name=$(admin_sub_auto_policy_name "$webdomain") || auto_name=
		proxy_name=$(admin_sub_proxy_policy_name "$webdomain") || proxy_name=
		if [[ -z "$auto_name" || -z "$proxy_name" ]]; then
			# Cannot name AUTO/PROXY without WEBDOMAIN; omit custom groups (still emit rules below).
			:
		else
			rule_proxy=$proxy_name
			printf '%s\n' \
				'proxy-groups:' \
				"  - name: ${auto_name}" \
				'    type: url-test' \
				'    hidden: true' \
				'    url: https://www.gstatic.com/generate_204' \
				'    interval: 300' \
				'    proxies:'
			for node in "${nodes[@]}"; do
				printf '      - %s\n' "$node"
			done
			printf '%s\n' \
				"  - name: ${proxy_name}" \
				'    type: select' \
				'    proxies:' \
				"      - ${auto_name}"
			for node in "${nodes[@]}"; do
				printf '      - %s\n' "$node"
			done
		fi
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
		printf '  - DOMAIN,%s.%s,%s\n' "$host" "$webdomain" "$rule_proxy"
	done < <(admin_sub_hostnames)
	printf '  - MATCH,DIRECT\n'
}

# Joins a subscription base URI with subId (tolerates missing/extra trailing slash).
subscription_url_for_sub_id() {
	local base=$1 sub_id=$2
	[[ -n "$base" && -n "$sub_id" ]] || return 1
	base=${base%/}
	[[ -n "$base" ]] || return 1
	printf '%s/%s\n' "$base" "$sub_id"
}

# Logs STD / JSON / Clash subscription URLs for the shared (autogen) client.
# Always safe to call after build_desired_state; skips quietly if subId/bases missing.
log_shared_autogen_subscription_urls() {
	local desired=$1
	local email sub_id std_base json_base clash_base std json clash

	[[ -n "$desired" ]] || {
		log WARN "shared subscription URLs omitted: empty desired state"
		return 0
	}
	email=$(jq -r '.clients.shared.email // empty' <<<"$desired")
	sub_id=$(jq -r '.clients.shared.subId // empty' <<<"$desired")
	[[ -n "$sub_id" ]] || {
		log WARN "shared subscription URLs omitted: empty subId"
		return 0
	}

	std_base=${subURI:-https://${WEBDOMAIN:-}${URI_SUB_PATH:-}}
	json_base=${subJsonURI:-https://${WEBDOMAIN:-}${URI_JSON_PATH:-}}
	clash_base=${subClashURI:-https://${WEBDOMAIN:-}${URI_CLASH_PATH:-/clash/}}

	std=$(subscription_url_for_sub_id "$std_base" "$sub_id" || true)
	json=$(subscription_url_for_sub_id "$json_base" "$sub_id" || true)
	clash=$(subscription_url_for_sub_id "$clash_base" "$sub_id" || true)

	log INFO "Shared client subscriptions email=${email:-unknown} subId=$sub_id"
	[[ -n "$std" ]] && log INFO "  STD   $std"
	[[ -n "$json" ]] && log INFO "  JSON  $json"
	[[ -n "$clash" ]] && log INFO "  CLASH $clash"
	if [[ -z "$std" && -z "$json" && -z "$clash" ]]; then
		log WARN "shared subscription URLs omitted: subscription base URIs empty"
	fi
}

# Local Mihomo client routing overlay (synced into inline subClashRules; never a public URL).
mihomo_client_routing_file() {
	local f=${MIHOMO_CLIENT_ROUTING_FILE:-} cand
	if [[ -n "$f" ]]; then
		[[ -f "$f" ]] || return 1
		printf '%s\n' "$f"
		return 0
	fi
	# Preferred container mount (compose: ../3x-ui/client-routing → /mnt/sh/client-routing).
	if [[ -f /mnt/sh/client-routing/mihomo-client.yaml ]]; then
		printf '%s\n' /mnt/sh/client-routing/mihomo-client.yaml
		return 0
	fi
	# Fallback when only scripts/lib is mounted (partial recreate / older compose).
	if [[ -f /mnt/sh/lib/mihomo-client.yaml ]]; then
		printf '%s\n' /mnt/sh/lib/mihomo-client.yaml
		return 0
	fi
	cand="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../client-routing" 2>/dev/null && pwd)/mihomo-client.yaml"
	[[ -f "$cand" ]] || return 1
	printf '%s\n' "$cand"
}

# Replaces the block between "# >>> NAME" and "# <<< NAME" (exclusive) with $2.
# Marker lines may be indented (YAML comments inside nested maps/lists).
_mihomo_fill_marker_block() {
	local name=$1 content=$2
	awk -v name="$name" -v content="$content" '
		BEGIN {
			start = "# >>> " name
			stop = "# <<< " name
		}
		function stripped(s,    t) {
			t = s
			sub(/^[[:space:]]+/, "", t)
			return t
		}
		stripped($0) == start {
			print
			if (content != "") {
				# $(…) strips one trailing newline; keep marker on its own line.
				printf "%s", content
				if (substr(content, length(content), 1) != "\n")
					printf "\n"
			}
			skip = 1
			next
		}
		skip && stripped($0) == stop {
			skip = 0
			print
			next
		}
		skip { next }
		{ print }
	'
}

# Builds subClashRules from client-routing/mihomo-client.yaml + admin host/DNS/DOMAIN inject.
# PROXY/AUTO already use include-all in the template (no node-name injection).
build_mihomo_client_sub_clash_rules() {
	local routing_file=$1 webdomain=$2 public_ipv4=${3:-}
	local host fakeip_block="" dns_hosts_block="" rules_block="" yaml

	[[ -n "$routing_file" && -f "$routing_file" ]] || die "build_mihomo_client_sub_clash_rules: missing routing file"
	[[ -n "$webdomain" ]] || die "build_mihomo_client_sub_clash_rules: empty webdomain"

	if [[ -n "$public_ipv4" ]]; then
		fakeip_block=$(
			printf '    - DOMAIN,%s,real-ip\n' "$webdomain"
			printf '    - DOMAIN-SUFFIX,%s,real-ip\n' "$webdomain"
		)
		dns_hosts_block=$(
			printf "    '%s': %s\n" "$webdomain" "$public_ipv4"
			while IFS= read -r host; do
				printf "    '%s.%s': %s\n" "$host" "$webdomain" "$public_ipv4"
			done < <(admin_sub_hostnames)
		)
	fi

	rules_block=$(
		printf '  - DOMAIN,%s,PROXY\n' "$webdomain"
		while IFS= read -r host; do
			printf '  - DOMAIN,%s.%s,PROXY\n' "$host" "$webdomain"
		done < <(admin_sub_hostnames)
	)

	yaml=$(cat -- "$routing_file")
	yaml=$(_mihomo_fill_marker_block ADMIN_FAKEIP "$fakeip_block" <<<"$yaml")
	yaml=$(_mihomo_fill_marker_block ADMIN_DNS_HOSTS "$dns_hosts_block" <<<"$yaml")
	yaml=$(_mihomo_fill_marker_block ADMIN_RULES "$rules_block" <<<"$yaml")
	printf '%s\n' "$yaml"
}
