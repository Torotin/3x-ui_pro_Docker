#!/usr/bin/env bash
# Environment rendering command.

template_dir() {
	printf '%s/template\n' "$SCRIPT_DIR"
}

render_env_template() {
	local template=$1 output=$2
	mkdir -p "$(dirname "$output")"
	if command -v envsubst >/dev/null 2>&1; then
		envsubst <"$template" >"$output"
	else
		cp -- "$template" "$output"
	fi
}

detect_public_ip() {
	local family=$1 label="ip.detect.ipv4" url="https://api.ipify.org"
	if [[ "$family" == "6" ]]; then
		label="ip.detect.ipv6"
		url="https://api6.ipify.org"
	fi
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd "$label" curl -fsSL "$url"
		if [[ "$family" == "6" ]]; then
			printf '2001:db8::10\n'
		else
			printf '198.51.100.10\n'
		fi
		return 0
	fi
	curl -fsSL --max-time 5 "$url" 2>/dev/null || true
}

generate_hex_secret() {
	local bytes=${1:-16}
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$bytes"
	else
		od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
	fi
}

normalize_json_env_value() {
	local value=$1
	if [[ "$value" == \'*\' ]]; then
		value=${value#\'}
		value=${value%\'}
	fi
	while [[ "$value" == *\\\"* ]]; do
		value=${value//\\\"/\"}
	done
	printf '%s' "$value"
}

json_array_item_or_default() {
	local json=$1 index=$2 fallback=$3
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$json" "$index" "$fallback" <<'PY'
import json
import sys

raw, idx, fallback = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    value = json.loads(raw)[idx]
except Exception:
    value = fallback
print(value if isinstance(value, str) and value else fallback)
PY
	else
		printf '%s' "$fallback"
	fi
}

escape_toml_basic_string_value() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/}
	printf '%s' "$value"
}

ensure_env_defaults() {
	: "${WEBDOMAIN:=example.invalid}"
	if [[ -z "${PUBLIC_IPV4:-}" ]]; then
		PUBLIC_IPV4=$(detect_public_ip 4)
		: "${PUBLIC_IPV4:=127.0.0.1}"
	fi
	if [[ -z "${PUBLIC_IPV6:-}" ]]; then
		PUBLIC_IPV6=$(detect_public_ip 6)
	fi
	: "${PUBLIC_IPV6:=$PUBLIC_IPV4}"
	: "${USER_WEB:=}"
	: "${PASS_WEB:=}"
	: "${USER_SSH:=}"
	: "${PASS_SSH:=}"
	: "${SSH_PBK:=}"
	: "${PORT_REMOTE_SSH:=$(generate_random_port 20000 65000)}"
	: "${URI_TRAEFIK_DASHBOARD:=$(generate_random_string 12 16)}"
	: "${ADMIN_ROUTING_MODE:=path}"
	: "${STRICT_DNS_CHECK:=true}"
	: "${STRICT_ACME_CHECK:=true}"
	: "${URI_DOZZLE:=$(generate_random_string 12 16)}"
	: "${URI_PANEL_PATH:=$(generate_random_string 12 16)}"
	: "${URI_SUB_PATH:=$(generate_random_string 12 16)}"
	: "${URI_JSON_PATH:=$(generate_random_string 12 16)}"
	: "${URI_CLASH_PATH:=$(generate_random_string 12 16)}"
	: "${URI_VLESS_XHTTP:=$(generate_random_string 12 16)}"
	: "${URI_SUB2SING:=$(generate_random_string 12 16)}"
	: "${URI_ADGUARD_PANEL:=$(generate_random_string 12 16)}"
	: "${URI_ADGUARD_DOH:=$(generate_random_string 12 16)}"
	: "${URI_HOMEPAGE:=$(generate_random_string 12 16)}"
	: "${URI_TELEMT_PANEL:=$(generate_random_string 12 16)}"
	: "${URI_TEST:=$(generate_random_string 12 16)}"
	: "${PORT_LOCAL_CADDYWEB:=$(generate_random_port)}"
	: "${PORT_LOCAL_SUB2SING:=$(generate_random_port)}"
	: "${PORT_LOCAL_DOZZLE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_SUBSCRIBE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_PANEL:=$(generate_random_port)}"
	: "${PORT_LOCAL_XHTTP:=$(generate_random_port)}"
	: "${PORT_LOCAL_VISION:=$(generate_random_port)}"
	: "${PORT_LOCAL_TELEMT_PROXY:=9443}"
	: "${PORT_LOCAL_TELEMT_API:=9091}"
	: "${PORT_LOCAL_TELEMT_METRICS:=9090}"
	: "${PORT_LOCAL_TELEMT_PANEL:=8080}"
	: "${PORT_LOCAL_CROWDSEC_API:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_CADDY:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_APPSEC:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_PROMETHEUS:=$(generate_random_port)}"
	: "${PORT_TEST:=$(generate_random_port)}"
	: "${CROWDSEC_API_KEY_CADDY:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_TRAEFIK:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_FIREWALL:=$(generate_random_string 32 48)}"
	: "${TELEMT_API_AUTH_HEADER:=$(generate_random_string 48 64)}"
	: "${TELEMT_PANEL_JWT_SECRET:=$(generate_random_string 48 64)}"
	: "${TELEMT_PANEL_PASSWORD_HASH:=}"
	: "${TELEMT_BOOTSTRAP_USER:=bootstrap}"
	: "${TELEMT_BOOTSTRAP_SECRET_HEX:=$(generate_hex_secret 16)}"
	: "${TELEMT_PANEL_VERSION:=latest}"
	: "${TELEMT_TUNING_PROFILE:=balanced}"
	: "${TELEMT_MIDDLE_PROXY_NAT_PROBE:=true}"
	: "${TELEMT_STUN_NAT_PROBE_CONCURRENCY:=16}"
	: "${TELEMT_MIDDLE_PROXY_POOL_SIZE:=12}"
	: "${TELEMT_ME_KEEPALIVE_ENABLED:=true}"
	: "${TELEMT_ME_KEEPALIVE_INTERVAL_SECS:=20}"
	: "${TELEMT_ME_KEEPALIVE_JITTER_SECS:=4}"
	: "${TELEMT_ME_RECONNECT_MAX_CONCURRENT_PER_DC:=12}"
	: "${TELEMT_ME_RECONNECT_BACKOFF_BASE_MS:=300}"
	: "${TELEMT_ME_RECONNECT_BACKOFF_CAP_MS:=10000}"
	: "${TELEMT_ME_RECONNECT_FAST_RETRY_COUNT:=10}"
	: "${TELEMT_HARDSWAP:=true}"
	: "${TELEMT_ME_REINIT_EVERY_SECS:=600}"
	: "${TELEMT_ME_HARDSWAP_WARMUP_DELAY_MIN_MS:=500}"
	: "${TELEMT_ME_HARDSWAP_WARMUP_DELAY_MAX_MS:=1200}"
	: "${TELEMT_ME_HARDSWAP_WARMUP_EXTRA_PASSES:=2}"
	: "${TELEMT_ME_HARDSWAP_WARMUP_PASS_BACKOFF_BASE_MS:=400}"
	: "${TELEMT_ME_CONFIG_STABLE_SNAPSHOTS:=3}"
	: "${TELEMT_ME_CONFIG_APPLY_COOLDOWN_SECS:=120}"
	: "${TELEMT_PROXY_SECRET_STABLE_SNAPSHOTS:=3}"
	: "${TELEMT_PROXY_SECRET_ROTATE_RUNTIME:=true}"
	: "${TELEMT_PROXY_SECRET_LEN_MAX:=512}"
	: "${TELEMT_UPDATE_EVERY:=300}"
	: "${TELEMT_ME_POOL_DRAIN_TTL_SECS:=120}"
	: "${TELEMT_ME_POOL_MIN_FRESH_RATIO:=0.9}"
	: "${TELEMT_ME_REINIT_DRAIN_TIMEOUT_SECS:=180}"
	: "${TELEMT_ME_ONE_RETRY:=8}"
	: "${TELEMT_ME_ONE_TIMEOUT_MS:=1200}"
	: "${TELEMT_STUN_USE:=true}"
	: "${TELEMT_STUN_TCP_FALLBACK:=true}"
	: "${TELEMT_STUN_SERVERS_JSON:=[\"stun1.l.google.com:19302\", \"stun2.l.google.com:19302\"]}"
	: "${TELEMT_HTTP_IP_DETECT_URLS_JSON:=[\"https://api.ipify.org\", \"https://ifconfig.me/ip\"]}"
	TELEMT_STUN_SERVERS_JSON=$(normalize_json_env_value "$TELEMT_STUN_SERVERS_JSON")
	TELEMT_HTTP_IP_DETECT_URLS_JSON=$(normalize_json_env_value "$TELEMT_HTTP_IP_DETECT_URLS_JSON")
	: "${TELEMT_STUN_SERVER_1:=$(json_array_item_or_default "$TELEMT_STUN_SERVERS_JSON" 0 "stun1.l.google.com:19302")}"
	: "${TELEMT_STUN_SERVER_2:=$(json_array_item_or_default "$TELEMT_STUN_SERVERS_JSON" 1 "stun2.l.google.com:19302")}"
	: "${TELEMT_HTTP_IP_DETECT_URL_1:=$(json_array_item_or_default "$TELEMT_HTTP_IP_DETECT_URLS_JSON" 0 "https://api.ipify.org")}"
	: "${TELEMT_HTTP_IP_DETECT_URL_2:=$(json_array_item_or_default "$TELEMT_HTTP_IP_DETECT_URLS_JSON" 1 "https://ifconfig.me/ip")}"
	: "${TELEMT_MAX_CONNECTIONS:=10000}"
	: "${TELEMT_ACCEPT_PERMIT_TIMEOUT_MS:=250}"
	: "${TELEMT_MASK_SHAPE_HARDENING:=true}"
	: "${TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE:=false}"
	: "${TELEMT_MASK_SHAPE_BUCKET_FLOOR_BYTES:=512}"
	: "${TELEMT_MASK_SHAPE_BUCKET_CAP_BYTES:=4096}"
	: "${TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR:=false}"
	: "${TELEMT_MASK_RELAY_MAX_BYTES:=5242880}"
	: "${TELEMT_MASK_RELAY_TIMEOUT_MS:=300000}"
	: "${TELEMT_MASK_RELAY_IDLE_TIMEOUT_MS:=30000}"
	: "${HT_PASS_ENCODED:=}"
	: "${ADGUARD_ADMIN_HASH:=}"
	export WEBDOMAIN PUBLIC_IPV4 PUBLIC_IPV6 USER_WEB PASS_WEB USER_SSH PASS_SSH SSH_PBK PORT_REMOTE_SSH
	export ADMIN_ROUTING_MODE STRICT_DNS_CHECK STRICT_ACME_CHECK
	export URI_TRAEFIK_DASHBOARD URI_DOZZLE URI_PANEL_PATH URI_SUB_PATH URI_JSON_PATH URI_CLASH_PATH
	export URI_VLESS_XHTTP URI_SUB2SING URI_ADGUARD_PANEL URI_ADGUARD_DOH URI_HOMEPAGE URI_TELEMT_PANEL URI_TEST
	export PORT_LOCAL_CADDYWEB PORT_LOCAL_SUB2SING PORT_LOCAL_DOZZLE PORT_LOCAL_VLESS_SUBSCRIBE
	export PORT_LOCAL_VLESS_PANEL PORT_LOCAL_XHTTP PORT_LOCAL_VISION PORT_LOCAL_TELEMT_PROXY
	export PORT_LOCAL_TELEMT_API PORT_LOCAL_TELEMT_METRICS PORT_LOCAL_TELEMT_PANEL PORT_LOCAL_CROWDSEC_API
	export PORT_LOCAL_CROWDSEC_CADDY PORT_LOCAL_CROWDSEC_APPSEC PORT_LOCAL_CROWDSEC_PROMETHEUS PORT_TEST
	export CROWDSEC_API_KEY_CADDY CROWDSEC_API_KEY_TRAEFIK CROWDSEC_API_KEY_FIREWALL HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	export TELEMT_API_AUTH_HEADER TELEMT_PANEL_JWT_SECRET TELEMT_PANEL_PASSWORD_HASH TELEMT_BOOTSTRAP_USER TELEMT_BOOTSTRAP_SECRET_HEX TELEMT_PANEL_VERSION
	export TELEMT_TUNING_PROFILE TELEMT_MIDDLE_PROXY_NAT_PROBE TELEMT_STUN_NAT_PROBE_CONCURRENCY TELEMT_MIDDLE_PROXY_POOL_SIZE
	export TELEMT_ME_KEEPALIVE_ENABLED TELEMT_ME_KEEPALIVE_INTERVAL_SECS TELEMT_ME_KEEPALIVE_JITTER_SECS
	export TELEMT_ME_RECONNECT_MAX_CONCURRENT_PER_DC TELEMT_ME_RECONNECT_BACKOFF_BASE_MS TELEMT_ME_RECONNECT_BACKOFF_CAP_MS TELEMT_ME_RECONNECT_FAST_RETRY_COUNT
	export TELEMT_HARDSWAP TELEMT_ME_REINIT_EVERY_SECS TELEMT_ME_HARDSWAP_WARMUP_DELAY_MIN_MS TELEMT_ME_HARDSWAP_WARMUP_DELAY_MAX_MS
	export TELEMT_ME_HARDSWAP_WARMUP_EXTRA_PASSES TELEMT_ME_HARDSWAP_WARMUP_PASS_BACKOFF_BASE_MS TELEMT_ME_CONFIG_STABLE_SNAPSHOTS TELEMT_ME_CONFIG_APPLY_COOLDOWN_SECS
	export TELEMT_PROXY_SECRET_STABLE_SNAPSHOTS TELEMT_PROXY_SECRET_ROTATE_RUNTIME TELEMT_PROXY_SECRET_LEN_MAX TELEMT_UPDATE_EVERY
	export TELEMT_ME_POOL_DRAIN_TTL_SECS TELEMT_ME_POOL_MIN_FRESH_RATIO TELEMT_ME_REINIT_DRAIN_TIMEOUT_SECS
	export TELEMT_ME_ONE_RETRY TELEMT_ME_ONE_TIMEOUT_MS TELEMT_STUN_USE TELEMT_STUN_TCP_FALLBACK TELEMT_STUN_SERVERS_JSON TELEMT_HTTP_IP_DETECT_URLS_JSON
	export TELEMT_STUN_SERVER_1 TELEMT_STUN_SERVER_2 TELEMT_HTTP_IP_DETECT_URL_1 TELEMT_HTTP_IP_DETECT_URL_2
	export TELEMT_MAX_CONNECTIONS TELEMT_ACCEPT_PERMIT_TIMEOUT_MS TELEMT_MASK_SHAPE_HARDENING TELEMT_MASK_SHAPE_HARDENING_AGGRESSIVE_MODE
	export TELEMT_MASK_SHAPE_BUCKET_FLOOR_BYTES TELEMT_MASK_SHAPE_BUCKET_CAP_BYTES TELEMT_MASK_SHAPE_ABOVE_CAP_BLUR TELEMT_MASK_RELAY_MAX_BYTES
	export TELEMT_MASK_RELAY_TIMEOUT_MS TELEMT_MASK_RELAY_IDLE_TIMEOUT_MS
}

generate_htpasswd_if_needed() {
	[[ -n "${USER_WEB:-}" ]] || return 0
	if [[ -n "${HT_PASS_ENCODED:-}" ]]; then
		if [[ -z "${PASS_WEB:-}" ]]; then
			generate_adguard_hash_from_htpasswd
			return 0
		fi
		local existing_htpasswd=${HT_PASS_ENCODED//\$\$/\$}
		if verify_htpasswd_entry "$existing_htpasswd" soft; then
			generate_adguard_hash_from_htpasswd
			return 0
		fi
		HT_PASS_ENCODED=
		ADGUARD_ADMIN_HASH=
	fi
	[[ -n "${PASS_WEB:-}" ]] || die "PASS_WEB is required to generate HT_PASS_ENCODED"
	local raw_htpasswd
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		raw_htpasswd="${USER_WEB}"':$2y$05$mockhash'
	elif command -v htpasswd >/dev/null 2>&1; then
		if ! raw_htpasswd=$(htpasswd -nBb "$USER_WEB" "$PASS_WEB" 2>/dev/null); then
			die "htpasswd failed to generate hash"
		fi
		raw_htpasswd=$(printf '%s' "$raw_htpasswd" | tr -d '\r\n')
		verify_htpasswd_entry "$raw_htpasswd"
	else
		die "htpasswd is required to generate HT_PASS_ENCODED"
	fi
	HT_PASS_ENCODED=${raw_htpasswd//$/\$\$}
	generate_adguard_hash_from_htpasswd
	export HT_PASS_ENCODED ADGUARD_ADMIN_HASH
}

verify_htpasswd_entry() {
	local raw_htpasswd=$1 mode=${2:-strict} tmpfile verify_output
	tmpfile=$(mktemp) || die "could not create temporary htpasswd verification file"
	printf '%s\n' "$raw_htpasswd" >"$tmpfile"
	if ! verify_output=$(htpasswd -vb "$tmpfile" "$USER_WEB" "$PASS_WEB" 2>&1); then
		rm -f "$tmpfile"
		if grep -qiE 'unknown option|illegal option|usage' <<<"$verify_output"; then
			if [[ "$mode" == "soft" ]]; then
				log WARN "htpasswd verification unsupported; regenerating existing hash"
				return 1
			fi
			log WARN "htpasswd verification unsupported; using generated hash"
			return 0
		fi
		[[ "$mode" == "soft" ]] && return 1
		die "htpasswd verification failed"
	fi
	rm -f "$tmpfile"
}

generate_adguard_hash_from_htpasswd() {
	[[ -z "${ADGUARD_ADMIN_HASH:-}" ]] || return 0
	[[ -n "${HT_PASS_ENCODED:-}" ]] || return 0
	ADGUARD_ADMIN_HASH=${HT_PASS_ENCODED#*:}
	ADGUARD_ADMIN_HASH=${ADGUARD_ADMIN_HASH//\$\$/\$}
	export ADGUARD_ADMIN_HASH
}

generate_telemt_panel_hash_if_needed() {
	[[ -n "${USER_WEB:-}" ]] || return 0
	[[ -z "${TELEMT_PANEL_PASSWORD_HASH:-}" ]] || return 0
	[[ -n "${PASS_WEB:-}" ]] || die "PASS_WEB is required to generate TELEMT_PANEL_PASSWORD_HASH"
	local raw_htpasswd raw_hash
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		raw_htpasswd="${USER_WEB}"':$2y$05$mockpanelhash'
	elif command -v htpasswd >/dev/null 2>&1; then
		if ! raw_htpasswd=$(htpasswd -nBb "$USER_WEB" "$PASS_WEB" 2>/dev/null); then
			die "htpasswd failed to generate Telemt panel password hash"
		fi
		raw_htpasswd=$(printf '%s' "$raw_htpasswd" | tr -d '\r\n')
	else
		die "htpasswd is required to generate TELEMT_PANEL_PASSWORD_HASH"
	fi
	raw_hash=${raw_htpasswd#*:}
	TELEMT_PANEL_PASSWORD_HASH=${raw_hash//$/\$\$}
	export TELEMT_PANEL_PASSWORD_HASH
}

escape_env_double_quoted_value() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/}
	printf '%s' "$value"
}

render_telemt_configs() {
	local templates telemt_config telemt_panel_config
	templates=$(template_dir)
	telemt_config="$INSTALL_ROOT/telemt/config/config.toml"
	telemt_panel_config="$INSTALL_ROOT/telemt-panel/config/config.toml"
	backup_file "$telemt_config"
	backup_file "$telemt_panel_config"
	TELEMT_PANEL_PASSWORD_HASH_RAW=${TELEMT_PANEL_PASSWORD_HASH//\$\$/\$}
	export TELEMT_PANEL_PASSWORD_HASH_RAW
	render_env_template "$templates/telemt.config.toml.template" "$telemt_config"
	render_env_template "$templates/telemt-panel.config.toml.template" "$telemt_panel_config"
	chmod 0600 "$telemt_config" "$telemt_panel_config" 2>/dev/null || true
}

install_env_command() {
	require_writable_target "$INSTALL_STATE_DIR" "installer state directory"
	require_writable_target "$INSTALL_STATE_DIR/backups" "installer backup directory"
	require_writable_target "$INSTALL_ROOT/compose.d" "compose env directory"
	install_load_state_env
	ensure_env_defaults
	generate_htpasswd_if_needed
	generate_telemt_panel_hash_if_needed
	TELEMT_STUN_SERVERS_JSON_ENV=$(escape_env_double_quoted_value "$TELEMT_STUN_SERVERS_JSON")
	TELEMT_HTTP_IP_DETECT_URLS_JSON_ENV=$(escape_env_double_quoted_value "$TELEMT_HTTP_IP_DETECT_URLS_JSON")
	TELEMT_STUN_SERVER_1_TOML=$(escape_toml_basic_string_value "$TELEMT_STUN_SERVER_1")
	TELEMT_STUN_SERVER_2_TOML=$(escape_toml_basic_string_value "$TELEMT_STUN_SERVER_2")
	TELEMT_HTTP_IP_DETECT_URL_1_TOML=$(escape_toml_basic_string_value "$TELEMT_HTTP_IP_DETECT_URL_1")
	TELEMT_HTTP_IP_DETECT_URL_2_TOML=$(escape_toml_basic_string_value "$TELEMT_HTTP_IP_DETECT_URL_2")
	export TELEMT_STUN_SERVERS_JSON_ENV TELEMT_HTTP_IP_DETECT_URLS_JSON_ENV
	export TELEMT_STUN_SERVER_1_TOML TELEMT_STUN_SERVER_2_TOML TELEMT_HTTP_IP_DETECT_URL_1_TOML TELEMT_HTTP_IP_DETECT_URL_2_TOML
	local templates install_env compose_env
	templates=$(template_dir)
	install_env="$INSTALL_STATE_DIR/install.env"
	compose_env="$INSTALL_ROOT/compose.d/.env"
	backup_file "$install_env"
	backup_file "$compose_env"
	render_env_template "$templates/install.env.template" "$install_env"
	render_env_template "$templates/docker.env.template" "$compose_env"
	render_telemt_configs
	run_cmd env.render printf 'rendered env files\n'
	printf 'rendered:\n- %s\n- %s\n- %s\n- %s\n' "$install_env" "$compose_env" "$INSTALL_ROOT/telemt/config/config.toml" "$INSTALL_ROOT/telemt-panel/config/config.toml"
}
