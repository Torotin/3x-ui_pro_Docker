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