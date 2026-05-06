#!/usr/bin/env bash

load_env_file() {
	local file=$1
	[[ -f "$file" ]] || return 0
	local nounset_was_on=0
	case $- in
	*u*)
		nounset_was_on=1
		set +u
		;;
	esac
	set -a
	# shellcheck source=/dev/null
	. "$file"
	set +a
	((nounset_was_on == 1)) && set -u
}

init_defaults() {
	: "${MODE:=apply}"
	: "${USERNAME:=admin}"
	: "${PASSWORD:=admin}"
	: "${NEW_ADMIN_USERNAME:=}"
	: "${NEW_ADMIN_PASSWORD:=}"
	: "${WEBDOMAIN:=}"
	: "${webListen:=0.0.0.0}"
	: "${webDomain:=}"
	: "${webPort:=${PORT_LOCAL_VLESS_PANEL:-2053}}"
	: "${webCertFile:=}"
	: "${webKeyFile:=}"
	: "${webBasePath:=}"
	: "${PORT_LOCAL_VISION:=443}"
	: "${PORT_LOCAL_XHTTP:=8443}"
	: "${PORT_LOCAL_TRAEFIK:=4443}"
	: "${VISION_FALLBACK_HOST:=traefik}"
	: "${VISION_FALLBACK_PORT:=$PORT_LOCAL_TRAEFIK}"
	: "${VISION_FALLBACK_XVER:=1}"
	: "${URI_VLESS_XHTTP:=}"
	: "${URI_CLASH_PATH:=}"
	: "${CLIENT_EMAIL_PREFIX:=autogen}"
	: "${CLIENT_EMAIL_VISION:=${CLIENT_EMAIL_PREFIX}-vision}"
	: "${CLIENT_EMAIL_XHTTP:=${CLIENT_EMAIL_PREFIX}-xhttp}"
	: "${CLIENT_SUB_ID:=}"
	: "${USE_VLESS_PQ:=true}"
	: "${USE_MLDSA65:=false}"
	: "${XRAY_LOCAL_RESTART:=true}"
	: "${XRAY_MANAGED_DNS:=true}"
	: "${XRAY_MANAGED_WARP:=true}"
	: "${XRAY_MANAGED_WARP_CONSOLE:=false}"
	: "${XRAY_MANAGED_TOR:=true}"
	: "${WARP_REUSE_PANEL_CONFIG:=false}"
	: "${WARP_ENDPOINT_HOST:=engage.cloudflareclient.com:2408}"
	: "${WARP_DOCKER_HOST:=warp}"
	: "${WARP_DOCKER_PORT:=1080}"
	: "${USQUE_HOST:=usque}"
	: "${USQUE_PORT:=1080}"
	: "${TOR_PROXY_HOST:=tor-proxy}"
	: "${TOR_PROXY_PORT:=1080}"
	: "${TOR_PROXY_ALT_HOST:=torproxy}"
	: "${TOR_PROXY_ALT_PORT:=9050}"
	: "${CUSTOM_GEO_API_ENABLED:=true}"
	: "${CUSTOM_GEO_UPDATE_ALL_ON_START:=true}"
	: "${GEOFILES_UPDATE_ON_START:=true}"
	: "${CUSTOM_GEO_RESOURCES:=}"
	: "${DOWNLOAD_GEO_DIRECT:=false}"
	: "${XRAY_RESTART_SETTLE_SECONDS:=5}"
	: "${XRAY_RESTART_PORT_TIMEOUT:=30}"
}

load_runtime_env() {
	local script_dir=$1
	load_env_file "$PWD/.env"
	load_env_file "$script_dir/../../3x-ui.env"
	init_defaults
}

check_dependencies() {
	local missing=() cmd
	for cmd in bash curl jq mktemp sed tr sort head awk base64 od; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	if ((${#missing[@]} > 0)); then
		die "Missing required utilities: ${missing[*]}. Install them in the image/setup stage."
	fi
}

normalize_base_path() {
	local raw=${1:-}
	raw=${raw#"/"}
	raw=${raw%"/"}
	[[ -n "$raw" ]] && printf '/%s' "$raw"
}

require_apply_mode() {
	case "$MODE" in
	apply | plan | check) ;;
	*) die "Unsupported MODE=$MODE. Use MODE=apply, MODE=plan, or MODE=check." ;;
	esac
}
