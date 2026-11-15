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

normalize_uri_segment() {
	local segment=${1:-}
	segment=${segment#/}
	segment=${segment%/}
	printf '%s' "$segment"
}

install_normalize_udp443_port_env() {
	if [[ -z "${PORT_LOCAL_UDP443:-}" && -n "${PORT_LOCAL_HYSTERIA:-}" ]]; then
		PORT_LOCAL_UDP443=$PORT_LOCAL_HYSTERIA
	fi
	: "${PORT_LOCAL_UDP443:=443}"
	PORT_LOCAL_HYSTERIA=$PORT_LOCAL_UDP443
	export PORT_LOCAL_UDP443 PORT_LOCAL_HYSTERIA
}

install_normalize_udp443_backend() {
	local raw=${UDP443_BACKEND:-}
	if [[ -z "$raw" ]]; then
		if [[ "${ENABLE_HYSTERIA2+x}" == x ]]; then
			install_normalize_bool_var ENABLE_HYSTERIA2
			if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
				UDP443_BACKEND=hysteria2
			else
				UDP443_BACKEND=amneziawg
			fi
		else
			UDP443_BACKEND=amneziawg
		fi
	else
		UDP443_BACKEND=${raw,,}
	fi
	case "$UDP443_BACKEND" in
	amneziawg | hysteria2 | off) ;;
	*) die "UDP443_BACKEND must be amneziawg|hysteria2|off (got: $UDP443_BACKEND)" ;;
	esac
	case "$UDP443_BACKEND" in
	amneziawg)
		ENABLE_AMNEZIAWG=true
		ENABLE_HYSTERIA2=false
		;;
	hysteria2)
		ENABLE_AMNEZIAWG=false
		ENABLE_HYSTERIA2=true
		;;
	off)
		ENABLE_AMNEZIAWG=false
		ENABLE_HYSTERIA2=false
		;;
	esac
	export UDP443_BACKEND ENABLE_AMNEZIAWG ENABLE_HYSTERIA2
}

assert_uri_telemt_sub_unique() {
	local sub peer normalized
	sub=$(normalize_uri_segment "${URI_TELEMT_SUB:-}")
	if [[ -z "$sub" ]]; then
		die "URI_TELEMT_SUB is required"
	fi
	local peers=(
		"${URI_TELEMT_WEB:-}"
		"${URI_SUB_PATH:-}"
		"${URI_JSON_PATH:-}"
		"${URI_CLASH_PATH:-}"
		"${URI_PANEL_PATH:-}"
		"${URI_MIHOMO:-}"
		"${URI_ADGUARD_DOH:-}"
	)
	for peer in "${peers[@]}"; do
		normalized=$(normalize_uri_segment "$peer")
		if [[ -z "$normalized" ]]; then
			continue
		fi
		if [[ "$sub" == "$normalized" ]]; then
			die "URI_TELEMT_SUB must be unique (conflicts with ${normalized})"
		fi
	done
	return 0
}

install_webdomain_is_ipv4() {
	[[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

install_webdomain_is_ipv6() {
	local domain=${1:-}
	[[ "$domain" == *:* ]] && ! install_webdomain_is_ipv4 "$domain"
}

# WEBDOMAIN must be a hostname, never a bare IP: Let's Encrypt rejects IP
# identifiers, Telemt rejects IP web.vhosts hosts, and Traefik Host() rules
# need a name that can obtain certs (use sslip.io or a real DNS name).
assert_webdomain_is_hostname() {
	local domain=${1:-${WEBDOMAIN:-}}
	[[ -n "$domain" ]] || die "WEBDOMAIN is required"
	if install_webdomain_is_ipv4 "$domain"; then
		die "WEBDOMAIN must be a DNS hostname, not an IPv4 address (got: $domain). Use a real domain or <ipv4>.sslip.io"
	fi
	if install_webdomain_is_ipv6 "$domain"; then
		die "WEBDOMAIN must be a DNS hostname, not an IPv6 address (got: $domain)"
	fi
	return 0
}

# When WEBDOMAIN is unset/placeholder/IP, derive <PUBLIC_IPV4>.sslip.io so LE + Telemt
# still get a resolvable FQDN after an IP-only bootstrap (admin Hosts also resolve).
ensure_webdomain_or_sslip() {
	local ipv4=${PUBLIC_IPV4:-}
	[[ -n "$ipv4" ]] || die "PUBLIC_IPV4 is required before WEBDOMAIN defaulting"
	if [[ -z "${WEBDOMAIN:-}" || "$WEBDOMAIN" == "example.invalid" ]] \
		|| install_webdomain_is_ipv4 "$WEBDOMAIN" || install_webdomain_is_ipv6 "$WEBDOMAIN"; then
		WEBDOMAIN="${ipv4}.sslip.io"
		export WEBDOMAIN
		printf 'WEBDOMAIN defaulted to %s (sslip.io)\n' "$WEBDOMAIN"
	fi
	assert_webdomain_is_hostname "$WEBDOMAIN"
}

# Traefik PEM paths must track WEBDOMAIN; stale IP-based paths abort AfterStart
# before Vision/XHTTP are created (public :443 stays dark).
sync_xray_traefik_pem_paths() {
	local domain=${WEBDOMAIN:-localhost}
	if [[ -z "${XRAY_TLS_CERT_FILE:-}" || "$XRAY_TLS_CERT_FILE" == /etc/traefik/pem/* ]]; then
		XRAY_TLS_CERT_FILE="/etc/traefik/pem/${domain}-cert.pem"
	fi
	if [[ -z "${XRAY_TLS_KEY_FILE:-}" || "$XRAY_TLS_KEY_FILE" == /etc/traefik/pem/* ]]; then
		XRAY_TLS_KEY_FILE="/etc/traefik/pem/${domain}-key.pem"
	fi
	# Stack contract: Hysteria2 masquerade hits Traefik websecure via WEBDOMAIN.
	HYSTERIA2_MASQ_URL="https://${domain}:4443/"
	export XRAY_TLS_CERT_FILE XRAY_TLS_KEY_FILE HYSTERIA2_MASQ_URL
}

detect_docker_socket_gid() {
	if getent group docker >/dev/null 2>&1; then
		getent group docker | awk -F: '{print $3}'
	elif [[ -S /var/run/docker.sock ]]; then
		stat -c '%g' /var/run/docker.sock
	else
		printf '0\n'
	fi
}

ensure_env_defaults() {
	ip_probe_resolve_host_mode
	# PUBLIC_IPV4 is required for this product; probe already died if missing.
	: "${PUBLIC_IPV4:?PUBLIC_IPV4 required}"
	ensure_webdomain_or_sslip
	# PUBLIC_IPV6 may be empty when HOST_IP_MODE=ipv4 — do not default to PUBLIC_IPV4
	if [[ "${HOST_IP_MODE}" == "dual" ]]; then
		TOR_IPV6_AVAILABLE=true
	else
		TOR_IPV6_AVAILABLE=false
	fi
	export TOR_IPV6_AVAILABLE
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
	# Prefer URI_ARCANE; keep URI_DOZZLE as legacy alias for upgrades from older installs.
	: "${URI_ARCANE:=${URI_DOZZLE:-$(generate_random_string 12 16)}}"
	: "${URI_DOZZLE:=$URI_ARCANE}"
	: "${ARCANE_ENCRYPTION_KEY:=$(generate_random_string 32 48)}"
	: "${URI_PANEL_PATH:=$(generate_random_string 12 16)}"
	: "${URI_SUB_PATH:=$(generate_random_string 12 16)}"
	: "${URI_JSON_PATH:=$(generate_random_string 12 16)}"
	: "${URI_CLASH_PATH:=$(generate_random_string 12 16)}"
	: "${URI_VLESS_XHTTP:=$(generate_random_string 12 16)}"
	: "${URI_VLESS_GRPC:=$(generate_random_string 12 16)}"
	: "${URI_SUB2SING:=$(generate_random_string 12 16)}"
	: "${URI_ADGUARD_PANEL:=$(generate_random_string 12 16)}"
	: "${URI_ADGUARD_DOH:=$(generate_random_string 12 16)}"
	: "${URI_HOMEPAGE:=$(generate_random_string 12 16)}"
	: "${URI_TELEMT_PANEL:=$(generate_random_string 12 16)}"
	: "${URI_TELEMT_WEB:=$(generate_random_string 12 16)}"
	: "${URI_TELEMT_SUB:=$(generate_random_string 12 16)}"
	: "${URI_MIHOMO:=$(generate_random_string 12 16)}"
	: "${PORT_LOCAL_CADDYWEB:=$(generate_random_port)}"
	: "${PORT_LOCAL_SUB2SING:=$(generate_random_port)}"
	: "${PORT_LOCAL_DOZZLE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_SUBSCRIBE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_PANEL:=$(generate_random_port)}"
	: "${PORT_LOCAL_XHTTP:=$(generate_random_port)}"
	: "${PORT_LOCAL_VISION:=$(generate_random_port)}"
	: "${PORT_LOCAL_GRPC:=$(generate_random_port)}"
	install_normalize_udp443_port_env
	: "${PORT_LOCAL_ADMIN:=9443}"
	: "${PORT_LOCAL_TELEMT_PROXY:=9443}"
	: "${PORT_LOCAL_TELEMT_API:=9091}"
	: "${PORT_LOCAL_TELEMT_METRICS:=9090}"
	: "${PORT_LOCAL_TELEMT_PANEL:=8080}"
	: "${PORT_LOCAL_TELEMT_SUB:=8081}"
	: "${PORT_LOCAL_TELEMT_WEB:=18080}"
	: "${PORT_LOCAL_XRAY_MIXED:=10808}"
	: "${TELEMT_WEB_USER:=web}"
	: "${TELEMT_WEB_SECRET_HEX:=$(generate_hex_secret 16)}"
	: "${TELEMT_WEB_CARRIER:=https}"
	: "${TELEMT_WEB_DECOY_UPSTREAM:=}"
	: "${PORT_LOCAL_CROWDSEC_API:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_CADDY:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_APPSEC:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_PROMETHEUS:=$(generate_random_port)}"
	: "${CROWDSEC_API_KEY_CADDY:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_TRAEFIK:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_FIREWALL:=$(generate_random_string 32 48)}"
	: "${ENABLE_LAMPAC:=false}"
	: "${ENABLE_TELEMT:=false}"
	: "${ENABLE_MIHOMO:=false}"
	: "${MIHOMO_SECRET:=$(generate_hex_secret 32)}"
	: "${LAMPAC_JACRED_APIKEY:=$(generate_hex_secret 16)}"
	: "${TELEMT_API_AUTH_HEADER:=$(generate_random_string 48 64)}"
	: "${TELEMT_SUBPAGE_SECRET:=$(generate_hex_secret 32)}"
	: "${TELEMT_PANEL_PASSWORD_HASH:=}"
	: "${TELEMT_BOOTSTRAP_USER:=bootstrap}"
	: "${TELEMT_BOOTSTRAP_SECRET_HEX:=$(generate_hex_secret 16)}"
	: "${TELEMT_STACK_IMAGE:=torotin/telemt-stack:latest}"
	# Panel GeoIP (stored via API into panel-state; not TOML). Default: P3TERX GeoLite.mmdb direct HTTPS .mmdb.
	: "${TELEMT_GEOIP_ENABLED:=true}"
	: "${TELEMT_GEOIP_SCHEDULE:=weekly}"
	: "${TELEMT_GEOIP_CITY_URL:=https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-City.mmdb}"
	: "${TELEMT_GEOIP_ASN_URL:=https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-ASN.mmdb}"
	: "${TELEMT_GEOIP_COUNTRY_URL:=https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb}"
	# 0 means "unset/misdetected" for compose group_add; re-probe the real socket GID.
	if [[ -z "${DOCKER_SOCKET_GID:-}" || "${DOCKER_SOCKET_GID}" == "0" ]]; then
		DOCKER_SOCKET_GID=$(detect_docker_socket_gid)
	fi
	# Optional: empty DOCKER_MTU = read host iface MTU; mirrors/proxy only if set.
	: "${DOCKER_MTU:=}"
	: "${DOCKER_GHCR_MIRROR:=}"
	: "${DOCKER_HTTP_PROXY:=}"
	: "${DOCKER_NO_PROXY:=localhost,127.0.0.1,::1}"
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
	: "${ENABLE_VLESS_GRPC:=false}"
	install_normalize_global_bool_env
	install_normalize_udp443_backend
	# Prefer Traefik inside docker-net. https://${WEBDOMAIN}/ self-loops when
	# the 3x-ui container hostname is WEBDOMAIN (no TCP :443 inside).
	sync_xray_traefik_pem_paths
	# Force-sync derived Xray targets from ENABLE_TELEMT. Bootstrap/env may have
	# already written traefik defaults into install.env; := would sticky-lock them.
	if install_telemt_enabled; then
		VISION_FALLBACK_HOST=telemt
		VISION_FALLBACK_PORT=$PORT_LOCAL_TELEMT_PROXY
		VISION_FALLBACK_XVER=1
		REALITY_TARGET_HOST=telemt
		REALITY_TARGET_PORT=$PORT_LOCAL_TELEMT_PROXY
		REALITY_TARGET_XVER=1
	else
		VISION_FALLBACK_HOST=traefik
		VISION_FALLBACK_PORT=${PORT_LOCAL_TRAEFIK:-4443}
		VISION_FALLBACK_XVER=1
		REALITY_TARGET_HOST=traefik
		REALITY_TARGET_PORT=${PORT_LOCAL_TRAEFIK:-4443}
		REALITY_TARGET_XVER=1
	fi
	export WEBDOMAIN HOST_IP_MODE PUBLIC_IPV4 PUBLIC_IPV6 TOR_IPV6_AVAILABLE USER_WEB PASS_WEB USER_SSH PASS_SSH SSH_PBK PORT_REMOTE_SSH
	export ADMIN_ROUTING_MODE STRICT_DNS_CHECK STRICT_ACME_CHECK
	export URI_TRAEFIK_DASHBOARD URI_ARCANE URI_DOZZLE URI_PANEL_PATH URI_SUB_PATH URI_JSON_PATH URI_CLASH_PATH
	export URI_VLESS_XHTTP URI_VLESS_GRPC URI_SUB2SING URI_ADGUARD_PANEL URI_ADGUARD_DOH URI_HOMEPAGE URI_TELEMT_PANEL URI_TELEMT_WEB URI_TELEMT_SUB URI_MIHOMO
	export ARCANE_ENCRYPTION_KEY
	export PORT_LOCAL_CADDYWEB PORT_LOCAL_SUB2SING PORT_LOCAL_DOZZLE PORT_LOCAL_VLESS_SUBSCRIBE
	export PORT_LOCAL_VLESS_PANEL PORT_LOCAL_XHTTP PORT_LOCAL_VISION PORT_LOCAL_GRPC PORT_LOCAL_UDP443 PORT_LOCAL_HYSTERIA PORT_LOCAL_ADMIN PORT_LOCAL_TELEMT_PROXY
	export PORT_LOCAL_TELEMT_API PORT_LOCAL_TELEMT_METRICS PORT_LOCAL_TELEMT_PANEL PORT_LOCAL_TELEMT_SUB PORT_LOCAL_TELEMT_WEB PORT_LOCAL_XRAY_MIXED PORT_LOCAL_CROWDSEC_API
	export PORT_LOCAL_CROWDSEC_CADDY PORT_LOCAL_CROWDSEC_APPSEC PORT_LOCAL_CROWDSEC_PROMETHEUS
	export CROWDSEC_API_KEY_CADDY CROWDSEC_API_KEY_TRAEFIK CROWDSEC_API_KEY_FIREWALL HT_PASS_ENCODED ADGUARD_ADMIN_HASH
	export ENABLE_LAMPAC ENABLE_TELEMT ENABLE_MIHOMO MIHOMO_SECRET LAMPAC_JACRED_APIKEY TELEMT_API_AUTH_HEADER TELEMT_SUBPAGE_SECRET TELEMT_PANEL_PASSWORD_HASH TELEMT_BOOTSTRAP_USER TELEMT_BOOTSTRAP_SECRET_HEX TELEMT_STACK_IMAGE DOCKER_SOCKET_GID
	export DOCKER_MTU DOCKER_GHCR_MIRROR DOCKER_HTTP_PROXY DOCKER_NO_PROXY
	export TELEMT_GEOIP_ENABLED TELEMT_GEOIP_SCHEDULE TELEMT_GEOIP_CITY_URL TELEMT_GEOIP_ASN_URL TELEMT_GEOIP_COUNTRY_URL
	export TELEMT_WEB_USER TELEMT_WEB_SECRET_HEX TELEMT_WEB_CARRIER TELEMT_WEB_DECOY_UPSTREAM
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
	export ENABLE_VLESS_GRPC ENABLE_HYSTERIA2 ENABLE_AMNEZIAWG UDP443_BACKEND XRAY_TLS_CERT_FILE XRAY_TLS_KEY_FILE HYSTERIA2_MASQ_URL
	export VISION_FALLBACK_HOST VISION_FALLBACK_PORT VISION_FALLBACK_XVER REALITY_TARGET_HOST REALITY_TARGET_PORT REALITY_TARGET_XVER
	assert_uri_telemt_sub_unique
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
	install_telemt_enabled || return 0
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
	install_telemt_enabled || return 0
	templates=$(template_dir)
	telemt_config="$INSTALL_ROOT/telemt/config/config.toml"
	telemt_panel_config="$INSTALL_ROOT/telemt-panel/config/config.toml"
	backup_file "$telemt_config"
	backup_file "$telemt_panel_config"
	TELEMT_PANEL_PASSWORD_HASH_RAW=${TELEMT_PANEL_PASSWORD_HASH//\$\$/\$}
	export TELEMT_PANEL_PASSWORD_HASH_RAW
	if [[ -z "${TELEMT_WEB_DECOY_UPSTREAM:-}" ]]; then
		if install_lampac_enabled; then
			TELEMT_WEB_DECOY_UPSTREAM="http://172.18.0.14:9118"
		else
			TELEMT_WEB_DECOY_UPSTREAM="http://172.18.0.5:${PORT_LOCAL_CADDYWEB}"
		fi
	fi
	export TELEMT_WEB_DECOY_UPSTREAM
	: "${TELEMT_WEB_USER:=web}"
	: "${TELEMT_WEB_SECRET_HEX:=$(generate_hex_secret 16)}"
	: "${TELEMT_WEB_CARRIER:=https}"
	: "${URI_TELEMT_WEB:=$(generate_random_string 12 16)}"
	: "${PORT_LOCAL_TELEMT_WEB:=18080}"
	: "${URI_TELEMT_SUB:=$(generate_random_string 12 16)}"
	: "${PORT_LOCAL_TELEMT_SUB:=8081}"
	: "${TELEMT_SUBPAGE_SECRET:=$(generate_hex_secret 32)}"
	export TELEMT_WEB_USER TELEMT_WEB_SECRET_HEX TELEMT_WEB_CARRIER URI_TELEMT_WEB PORT_LOCAL_TELEMT_WEB
	export URI_TELEMT_SUB PORT_LOCAL_TELEMT_SUB TELEMT_SUBPAGE_SECRET
	assert_uri_telemt_sub_unique
	render_env_template "$templates/telemt.config.toml.template" "$telemt_config"
	render_env_template "$templates/telemt-panel.config.toml.template" "$telemt_panel_config"
	chmod 0600 "$telemt_config" "$telemt_panel_config" 2>/dev/null || true
}

render_mihomo_config() {
	local templates mihomo_config
	install_mihomo_enabled || return 0
	templates=$(template_dir)
	mihomo_config="$INSTALL_ROOT/mihomo/config.yaml"
	backup_file "$mihomo_config"
	render_env_template "$templates/mihomo.config.yaml.template" "$mihomo_config"
	if grep -Fq '${MIHOMO_SECRET}' "$mihomo_config"; then
		die "Mihomo config still contains an unsubstituted MIHOMO_SECRET placeholder"
	fi
	chmod 0600 "$mihomo_config" 2>/dev/null || true
}

# Render install.env from template after ensure_env_defaults (PORT_REMOTE_SSH, URIs, …).
# Does not touch compose.d — safe before docker/compose exist. Idempotent.
install_bootstrap_install_env() {
	require_writable_target "$INSTALL_STATE_DIR" "installer state directory"
	mkdir -p "$INSTALL_STATE_DIR/backups" 2>/dev/null || true
	install_load_state_env
	ensure_env_defaults
	local templates install_env
	templates=$(template_dir)
	install_env="$INSTALL_STATE_DIR/install.env"
	backup_file "$install_env"
	render_env_template "$templates/install.env.template" "$install_env"
	run_cmd env.bootstrap printf 'bootstrapped install.env defaults\n'
	printf 'bootstrapped install.env: %s\n' "$install_env"
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
	render_mihomo_config
	if install_lampac_enabled; then
		if [[ -f "$INSTALL_ROOT/lampac/config/init.conf" ]]; then
			apply_lampac_jacred_secrets
			run_cmd env.lampac_jacred printf 'applied lampac JacRed secrets\n'
		fi
	fi
	run_cmd env.render printf 'rendered env files\n'
	printf 'rendered:\n- %s\n- %s\n' "$install_env" "$compose_env"
	if install_telemt_enabled; then
		printf -- '- %s\n- %s\n' "$INSTALL_ROOT/telemt/config/config.toml" "$INSTALL_ROOT/telemt-panel/config/config.toml"
	fi
	if install_mihomo_enabled; then
		printf -- '- %s\n' "$INSTALL_ROOT/mihomo/config.yaml"
	fi
}
