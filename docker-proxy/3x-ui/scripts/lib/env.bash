#!/usr/bin/env bash

# Загружает существующий env-файл с экспортом значений и сохраняет режим nounset.
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

normalize_bool_value() {
	local name=$1 value=${2:-}
	value=${value,,}
	case "$value" in
	1 | true | yes | y | on | enabled)
		printf 'true\n'
		;;
	0 | false | no | n | off | disabled)
		printf 'false\n'
		;;
	*)
		die "$name must be boolean: true/false, yes/no, on/off, enabled/disabled, or 1/0"
		;;
	esac
}

normalize_bool_var() {
	local name=$1 value
	value=$(normalize_bool_value "$name" "${!name-}")
	printf -v "$name" '%s' "$value"
	export "${name?}"
}

normalize_runtime_bool_env() {
	local name
	for name in ENABLE_VLESS_GRPC ENABLE_HYSTERIA2 ENABLE_MIHOMO; do
		normalize_bool_var "$name"
	done
}

# Задает значения runtime-параметров, если они не были переданы окружением.
init_defaults() {
	: "${MODE:=apply}"
	: "${USERNAME:=admin}"
	: "${PASSWORD:=admin}"
	: "${NEW_ADMIN_USERNAME:=}"
	: "${NEW_ADMIN_PASSWORD:=}"
	: "${XUI_API_TOKEN:=}"
	: "${TWO_FACTOR_CODE:=}"
	: "${panelOutbound:=}"
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
	: "${PORT_LOCAL_TELEMT_PROXY:=9443}"
	: "${VISION_FALLBACK_HOST:=telemt}"
	: "${VISION_FALLBACK_PORT:=$PORT_LOCAL_TELEMT_PROXY}"
	: "${VISION_FALLBACK_XVER:=1}"
	: "${REALITY_TARGET_HOST:=telemt}"
	: "${REALITY_TARGET_PORT:=$PORT_LOCAL_TELEMT_PROXY}"
	: "${REALITY_TARGET_XVER:=1}"
	: "${URI_VLESS_XHTTP:=}"
	: "${URI_CLASH_PATH:=}"
	: "${CLIENT_EMAIL_PREFIX:=${WEBDOMAIN:+${WEBDOMAIN}-}autogen}"
	: "${CLIENT_EMAIL_SHARED:=$CLIENT_EMAIL_PREFIX}"
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
	: "${ENABLE_MIHOMO:=true}"
	: "${WARP_REUSE_PANEL_CONFIG:=false}"
	: "${WARP_ENDPOINT_HOST:=engage.cloudflareclient.com:2408}"
	: "${USQUE_HOST:=usque}"
	: "${USQUE_PORT:=1080}"
	: "${EXTERNAL_PROXY_PROBE_TIMEOUT:=10}"
	: "${WARP_PROXY_PROBE_URL:=https://www.cloudflare.com/cdn-cgi/trace}"
	if [[ "${XRAY_TLS_CERT_FILE:-}" == "/etc/x-ui/xray-managed.crt" || -z "${XRAY_TLS_CERT_FILE:-}" ]]; then
		XRAY_TLS_CERT_FILE="/etc/traefik/pem/${WEBDOMAIN:-localhost}-cert.pem"
	fi
	if [[ "${XRAY_TLS_KEY_FILE:-}" == "/etc/x-ui/xray-managed.key" || -z "${XRAY_TLS_KEY_FILE:-}" ]]; then
		XRAY_TLS_KEY_FILE="/etc/traefik/pem/${WEBDOMAIN:-localhost}-key.pem"
	fi
	: "${TOR_PROXY_PROBE_URL:=https://check.torproject.org/api/ip}"
	: "${TOR_PROXY_HOST:=tor-proxy}"
	: "${TOR_PROXY_PORT:=1080}"
	: "${CUSTOM_GEO_RESOURCES:=}"
	: "${GEODATA_CRON:=0 4 * * *}"
	: "${GEOFILES_UPDATE_ON_START:=true}"
	: "${DOWNLOAD_GEO_DIRECT:=false}"
	: "${DOWNLOAD_TRANSPORTS:=}"
	: "${DOWNLOAD_URL_FALLBACKS:=}"
	: "${DOWNLOAD_CONNECT_TIMEOUT:=5}"
	: "${DOWNLOAD_MAX_TIME:=120}"
	: "${XRAY_RESTART_SETTLE_SECONDS:=5}"
	: "${XRAY_RESTART_PORT_TIMEOUT:=30}"
}

# Объединяет локальное и смонтированное окружение, затем дополняет его значениями по умолчанию.
load_runtime_env() {
	local script_dir=$1
	local name
	local -A preserved_env=()
	for name in MODE ENABLE_VLESS_GRPC ENABLE_HYSTERIA2 ENABLE_MIHOMO; do
		if [[ ${!name+x} ]]; then
			preserved_env[$name]=${!name}
		fi
	done
	load_env_file "$PWD/.env"
	load_env_file "$script_dir/../../3x-ui.env"
	for name in "${!preserved_env[@]}"; do
		printf -v "$name" '%s' "${preserved_env[$name]}"
		export "${name?}"
	done
	init_defaults
	normalize_runtime_bool_env
}

# Проверяет наличие утилит, требуемых сценарию после запуска контейнера.
check_dependencies() {
	local missing=() cmd
	for cmd in bash curl jq grep mktemp sed tr sort head awk base64 od; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done
	if ((${#missing[@]} > 0)); then
		die "Missing required utilities: ${missing[*]}. Install them in the image/setup stage."
	fi
}

# Нормализует base path панели до пустой строки или пути с одним начальным слешем.
normalize_base_path() {
	local raw=${1:-}
	raw=${raw#"/"}
	raw=${raw%"/"}
	[[ -n "$raw" ]] && printf '/%s' "$raw"
	return 0
}

# Ограничивает режим выполнения вариантами проверки, плана и применения.
require_apply_mode() {
	case "$MODE" in
	apply | plan | check) ;;
	*) die "Unsupported MODE=$MODE. Use MODE=apply, MODE=plan, or MODE=check." ;;
	esac
}
