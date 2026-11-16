#!/usr/bin/env bash
# Dual-mode builder parity between bash jq builders and Python xui_runtime.

# Sets PYTHONPATH for container (/mnt/sh/python) or repo scripts tree.
parity_python_root() {
	local py_root=/mnt/sh/python
	if [[ ! -d "$py_root" ]]; then
		py_root="${SCRIPT_DIR:-}/../python"
	fi
	export PYTHONPATH="$py_root${PYTHONPATH:+:$PYTHONPATH}"
}

# Compare one bash builder JSON blob to Python (--args-json optional).
assert_dual_builder_parity() {
	local name=$1 bash_json=$2 args_json=${3:-}
	[[ "${XUI_RUNTIME_ENGINE:-}" == "dual" ]] || return 0
	[[ -n "${TMP_ROOT:-}" ]] || die "assert_dual_builder_parity requires TMP_ROOT"
	parity_python_root
	local bash_file args_file args_path=()
	bash_file=$(mktemp "$TMP_ROOT/builder-bash.XXXXXX")
	printf '%s' "$bash_json" >"$bash_file"
	if [[ -n "$args_json" ]]; then
		args_file=$(mktemp "$TMP_ROOT/builder-args.XXXXXX")
		printf '%s' "$args_json" >"$args_file"
		args_path=(--args-json "$args_file")
	fi
	python3 -m xui_runtime.parity builder --name "$name" --bash-json-file "$bash_file" "${args_path[@]}" \
		|| die "Python builder parity failed: $name"
}

# MODE=check has no panel API for X25519; use stable placeholders and shortIds.
assert_dual_stream_builders_parity() {
	local desired=$1
	[[ "${XUI_RUNTIME_ENGINE:-}" == "dual" ]] || return 0
	local target short_ids sockopt stream args_json cert key host path grpc_path xhttp_path xver

	host="${WEBDOMAIN:-}"
	xhttp_path="${URI_VLESS_XHTTP:-/xhttp}"
	grpc_path="${URI_VLESS_GRPC:-/grpc}"
	target="${REALITY_TARGET_HOST:-telemt}:${REALITY_TARGET_PORT:-${PORT_LOCAL_TELEMT_PROXY:-9443}}"
	xver="${REALITY_TARGET_XVER:-1}"
	short_ids='["a1b2c3d4","e5f6a7b8"]'
	sockopt=$(build_sockopt_json false AsIs off)

	stream=$(build_vision_stream_json "$target" "$host" dual-parity-private dual-parity-public "$short_ids" "$sockopt" "" "" "$xver")
	args_json=$(jq -nc \
		--arg target "$target" \
		--arg sni "$host" \
		--arg private_key dual-parity-private \
		--arg public_key dual-parity-public \
		--argjson short_ids "$short_ids" \
		--argjson sockopt "$sockopt" \
		--argjson target_xver "$xver" \
		'{target:$target,sni:$sni,private_key:$private_key,public_key:$public_key,short_ids:$short_ids,sockopt:$sockopt,target_xver:$target_xver}')
	assert_dual_builder_parity vision_stream "$stream" "$args_json"

	stream=$(build_xhttp_stream_json "$xhttp_path" "$host")
	args_json=$(jq -nc --arg path "$xhttp_path" --arg host "$host" '{path:$path,host:$host}')
	assert_dual_builder_parity xhttp_stream "$stream" "$args_json"

	cert="${XRAY_TLS_CERT_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-cert.pem}"
	key="${XRAY_TLS_KEY_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-key.pem}"
	stream=$(build_grpc_stream_json "$grpc_path" "$host" "$cert" "$key")
	args_json=$(jq -nc \
		--arg path "$grpc_path" \
		--arg host "$host" \
		--arg cert_file "$cert" \
		--arg key_file "$key" \
		'{path:$path,host:$host,cert_file:$cert_file,key_file:$key_file}')
	assert_dual_builder_parity grpc_stream "$stream" "$args_json"

	stream=$(build_hysteria2_stream_json "$host" "$cert" "$key" "")
	args_json=$(jq -nc \
		--arg host "$host" \
		--arg cert_file "$cert" \
		--arg key_file "$key" \
		--arg auth "" \
		'{host:$host,cert_file:$cert_file,key_file:$key_file,auth:$auth}')
	assert_dual_builder_parity hysteria2_stream "$stream" "$args_json"

	settings=$(build_amneziawg_settings_json "$desired")
	args_json=$(jq -nc --argjson desired "$desired" '{desired:$desired}')
	assert_dual_builder_parity amneziawg_settings "$settings" "$args_json"

	if [[ "${UDP443_BACKEND:-}" == "hysteria2" || "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
		settings=$(build_hysteria2_settings_json '' "$desired")
		assert_dual_builder_parity hysteria2_settings "$settings" '{}'
	fi
}

# Compares bash subscription rule builders to Python (XUI_RUNTIME_ENGINE=dual).
assert_dual_sub_builders_parity() {
	local node_names_file=${1:-}
	[[ "${XUI_RUNTIME_ENGINE:-}" == "dual" ]] || return 0
	if ! declare -F build_admin_sub_json_rules >/dev/null 2>&1; then
		# shellcheck source=/dev/null
		. "${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/sub_admin_routing.bash"
	fi
	if ! declare -F build_admin_sub_json_observatory >/dev/null 2>&1; then
		# shellcheck source=/dev/null
		. "${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/sub_balancer.bash"
	fi
	local webdomain=${WEBDOMAIN:-} public_ipv4=${PUBLIC_IPV4:-} mode args_json bash_json clash_yaml clash_json routing_file
	[[ -n "$webdomain" ]] || return 0

	bash_json=$(build_admin_sub_json_rules "$webdomain")
	[[ -n "$bash_json" ]] || return 0
	args_json=$(jq -nc --arg webdomain "$webdomain" '{webdomain:$webdomain}')
	assert_dual_builder_parity admin_sub_json_rules "$bash_json" "$args_json"

	if [[ -n "$public_ipv4" ]]; then
		bash_json=$(build_admin_sub_json_dns "$webdomain" "$public_ipv4")
		[[ -n "$bash_json" ]] || return 0
		args_json=$(jq -nc --arg webdomain "$webdomain" --arg public_ipv4 "$public_ipv4" \
			'{webdomain:$webdomain,public_ipv4:$public_ipv4}')
		assert_dual_builder_parity admin_sub_json_dns "$bash_json" "$args_json"
	fi

	bash_json=$(build_admin_sub_json_observatory)
	assert_dual_builder_parity admin_sub_json_observatory "$bash_json" '{}'

	mode=$(admin_sub_clash_default_mode)
	clash_yaml=$(build_admin_sub_clash_rules "$webdomain" "$public_ipv4" "$mode")
	clash_json=$(jq -Rs -- . <<<"$clash_yaml")
	args_json=$(jq -nc --arg webdomain "$webdomain" --arg public_ipv4 "$public_ipv4" --arg mode "$mode" \
		'{webdomain:$webdomain,public_ipv4:$public_ipv4,mode:$mode,node_names:[]}')
	assert_dual_builder_parity admin_sub_clash_rules "$clash_json" "$args_json"

	if [[ -n "$node_names_file" && -f "$node_names_file" && -s "$node_names_file" ]]; then
		clash_yaml=$(build_admin_sub_clash_rules "$webdomain" "$public_ipv4" "$mode" "$node_names_file")
		clash_json=$(jq -Rs -- . <<<"$clash_yaml")
		args_json=$(jq -nc --arg webdomain "$webdomain" --arg public_ipv4 "$public_ipv4" --arg mode "$mode" \
			--slurpfile nodes "$node_names_file" \
			'{webdomain:$webdomain,public_ipv4:$public_ipv4,mode:$mode,node_names:($nodes[0] | split("\n") | map(select(length > 0)))}')
		assert_dual_builder_parity admin_sub_clash_rules "$clash_json" "$args_json"
	fi

	routing_file=
	routing_file=$(mihomo_client_routing_file) || routing_file=
	if [[ -n "$routing_file" ]]; then
		clash_yaml=$(build_mihomo_client_sub_clash_rules "$routing_file" "$webdomain" "$public_ipv4")
		clash_json=$(jq -Rs -- . <<<"$clash_yaml")
		args_json=$(jq -nc --arg routing_file "$routing_file" --arg webdomain "$webdomain" --arg public_ipv4 "$public_ipv4" \
			'{routing_file:$routing_file,webdomain:$webdomain,public_ipv4:$public_ipv4}')
		assert_dual_builder_parity mihomo_client_sub_clash_rules "$clash_json" "$args_json"
	fi
}