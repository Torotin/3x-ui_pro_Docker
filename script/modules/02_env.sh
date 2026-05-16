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
	: "${URI_TEST:=$(generate_random_string 12 16)}"
	: "${PORT_LOCAL_CADDYWEB:=$(generate_random_port)}"
	: "${PORT_LOCAL_SUB2SING:=$(generate_random_port)}"
	: "${PORT_LOCAL_DOZZLE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_SUBSCRIBE:=$(generate_random_port)}"
	: "${PORT_LOCAL_VLESS_PANEL:=$(generate_random_port)}"
	: "${PORT_LOCAL_XHTTP:=$(generate_random_port)}"
	: "${PORT_LOCAL_VISION:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_API:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_CADDY:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_APPSEC:=$(generate_random_port)}"
	: "${PORT_LOCAL_CROWDSEC_PROMETHEUS:=$(generate_random_port)}"
	: "${PORT_TEST:=$(generate_random_port)}"
	: "${CROWDSEC_API_KEY_CADDY:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_TRAEFIK:=$(generate_random_string 32 48)}"
	: "${CROWDSEC_API_KEY_FIREWALL:=$(generate_random_string 32 48)}"
	: "${HT_PASS_ENCODED:=}"
	: "${ADGUARD_ADMIN_HASH:=}"
	export WEBDOMAIN PUBLIC_IPV4 PUBLIC_IPV6 USER_WEB PASS_WEB USER_SSH PASS_SSH SSH_PBK PORT_REMOTE_SSH
	export URI_TRAEFIK_DASHBOARD URI_DOZZLE URI_PANEL_PATH URI_SUB_PATH URI_JSON_PATH URI_CLASH_PATH
	export URI_VLESS_XHTTP URI_SUB2SING URI_ADGUARD_PANEL URI_ADGUARD_DOH URI_HOMEPAGE URI_TEST
	export PORT_LOCAL_CADDYWEB PORT_LOCAL_SUB2SING PORT_LOCAL_DOZZLE PORT_LOCAL_VLESS_SUBSCRIBE
	export PORT_LOCAL_VLESS_PANEL PORT_LOCAL_XHTTP PORT_LOCAL_VISION PORT_LOCAL_CROWDSEC_API
	export PORT_LOCAL_CROWDSEC_CADDY PORT_LOCAL_CROWDSEC_APPSEC PORT_LOCAL_CROWDSEC_PROMETHEUS PORT_TEST
	export CROWDSEC_API_KEY_CADDY CROWDSEC_API_KEY_TRAEFIK CROWDSEC_API_KEY_FIREWALL HT_PASS_ENCODED ADGUARD_ADMIN_HASH
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

install_env_command() {
	require_writable_target "$INSTALL_STATE_DIR" "installer state directory"
	require_writable_target "$INSTALL_STATE_DIR/backups" "installer backup directory"
	require_writable_target "$INSTALL_ROOT/compose.d" "compose env directory"
	install_load_state_env
	ensure_env_defaults
	generate_htpasswd_if_needed
	local templates install_env compose_env
	templates=$(template_dir)
	install_env="$INSTALL_STATE_DIR/install.env"
	compose_env="$INSTALL_ROOT/compose.d/.env"
	backup_file "$install_env"
	backup_file "$compose_env"
	render_env_template "$templates/install.env.template" "$install_env"
	render_env_template "$templates/docker.env.template" "$compose_env"
	run_cmd env.render printf 'rendered env files\n'
	printf 'rendered:\n- %s\n- %s\n' "$install_env" "$compose_env"
}
