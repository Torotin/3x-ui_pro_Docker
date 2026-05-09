#!/usr/bin/env bash
# Final summary and self-update command domain.

install_final_command() {
	install_load_state_env
	install_prepare_summary_env
	local template="$SCRIPT_DIR/template/install.summary.template"
	local output="$INSTALL_STATE_DIR/install.summary"
	[[ -f "$template" ]] || die "summary template not found: $template"
	command -v envsubst >/dev/null 2>&1 || die "envsubst is required to render final summary"
	mkdir -p "$(dirname "$output")"
	export SUMMARY_OUTPUT_FILE="$output"
	envsubst <"$template" >"$output"
	run_cmd final.summary printf 'installation summary rendered\n'
	cat "$output"
	printf 'Summary saved: %s\n' "$output"
}

install_prepare_summary_env() {
	SUMMARY_GENERATED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')
	SUMMARY_DOMAIN=${WEBDOMAIN:-example.invalid}
	SUMMARY_PUBLIC_IPV4=${PUBLIC_IPV4:-127.0.0.1}
	SUMMARY_PUBLIC_IPV6=${PUBLIC_IPV6:-$SUMMARY_PUBLIC_IPV4}
	SUMMARY_USER_SSH=${USER_SSH:-unspecified}
	SUMMARY_USER_WEB=${USER_WEB:-unspecified}
	SUMMARY_PORT_REMOTE_SSH=${PORT_REMOTE_SSH:-unspecified}
	SUMMARY_SSH_TARGET="${SUMMARY_USER_SSH}@${SUMMARY_PUBLIC_IPV4}:${SUMMARY_PORT_REMOTE_SSH}"
	SUMMARY_COMPOSE_DIR="$INSTALL_ROOT/compose.d"
	SUMMARY_COMPOSE_ENV="$SUMMARY_COMPOSE_DIR/.env"
	SUMMARY_UPDATE_BRANCH=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	SUMMARY_SSH_AUTH="password"
	if [[ -n "${SSH_PBK:-}" ]]; then
		SUMMARY_SSH_AUTH="public key"
	fi
	SUMMARY_PORT_LOCAL_TRAEFIK=${PORT_LOCAL_TRAEFIK:-4443}
	SUMMARY_PORT_LOCAL_VLESS_PANEL=${PORT_LOCAL_VLESS_PANEL:-unspecified}
	SUMMARY_PORT_LOCAL_VLESS_SUBSCRIBE=${PORT_LOCAL_VLESS_SUBSCRIBE:-unspecified}
	SUMMARY_PORT_LOCAL_XHTTP=${PORT_LOCAL_XHTTP:-unspecified}
	SUMMARY_PORT_LOCAL_VISION=${PORT_LOCAL_VISION:-unspecified}
	SUMMARY_PORT_LOCAL_DOZZLE=${PORT_LOCAL_DOZZLE:-unspecified}
	SUMMARY_PORT_LOCAL_CADDYWEB=${PORT_LOCAL_CADDYWEB:-unspecified}
	SUMMARY_PORT_LOCAL_CROWDSEC_API=${PORT_LOCAL_CROWDSEC_API:-unspecified}
	SUMMARY_URL_HOMEPAGE=$(install_summary_url "${URI_HOMEPAGE:-}")
	SUMMARY_URL_3X_UI=$(install_summary_url "${URI_PANEL_PATH:-}")
	SUMMARY_URL_ADGUARD=$(install_summary_url "${URI_ADGUARD_PANEL:-}")
	SUMMARY_URL_ADGUARD_DOH=$(install_summary_url "${URI_ADGUARD_DOH:-}")
	SUMMARY_URL_DOZZLE=$(install_summary_url "${URI_DOZZLE:-}")
	SUMMARY_URL_TRAEFIK=$(install_summary_url "${URI_TRAEFIK_DASHBOARD:-}" "dashboard/#/")
	export SUMMARY_GENERATED_AT SUMMARY_DOMAIN SUMMARY_PUBLIC_IPV4 SUMMARY_PUBLIC_IPV6
	export SUMMARY_USER_SSH SUMMARY_USER_WEB SUMMARY_PORT_REMOTE_SSH SUMMARY_SSH_TARGET SUMMARY_SSH_AUTH
	export SUMMARY_COMPOSE_DIR SUMMARY_COMPOSE_ENV SUMMARY_UPDATE_BRANCH
	export SUMMARY_PORT_LOCAL_TRAEFIK SUMMARY_PORT_LOCAL_VLESS_PANEL SUMMARY_PORT_LOCAL_VLESS_SUBSCRIBE
	export SUMMARY_PORT_LOCAL_XHTTP SUMMARY_PORT_LOCAL_VISION SUMMARY_PORT_LOCAL_DOZZLE SUMMARY_PORT_LOCAL_CADDYWEB
	export SUMMARY_PORT_LOCAL_CROWDSEC_API
	export SUMMARY_URL_HOMEPAGE SUMMARY_URL_3X_UI SUMMARY_URL_ADGUARD SUMMARY_URL_ADGUARD_DOH
	export SUMMARY_URL_DOZZLE SUMMARY_URL_TRAEFIK
}

install_summary_url() {
	local path=${1:-} suffix=${2:-}
	path=${path#/}
	suffix=${suffix#/}
	if [[ -n "$path" && -n "$suffix" ]]; then
		printf 'https://%s/%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$path" "$suffix"
	elif [[ -n "$suffix" ]]; then
		printf 'https://%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$suffix"
	elif [[ -n "$path" ]]; then
		printf 'https://%s/%s\n' "${SUMMARY_DOMAIN:-example.invalid}" "$path"
	else
		printf 'https://%s/\n' "${SUMMARY_DOMAIN:-example.invalid}"
	fi
}

install_self_update_command() {
	local branch check=0 yes=0 arg
	branch=$(config_get update.branch "$INSTALL_DEFAULT_BRANCH")
	while (($# > 0)); do
		arg=$1
		shift
		case "$arg" in
		--branch)
			(($# > 0)) || die "--branch requires a value"
			branch=$1
			shift
			;;
		--check) check=1 ;;
		--yes) yes=1 ;;
		*) die "unknown self-update option: $arg" ;;
		esac
	done
	config_set update.branch "$branch"
	if ((check)); then
		run_cmd self-update.check git ls-remote --heads "$INSTALL_REPO_URL" "$branch"
		printf 'self-update: checked %s\n' "$branch"
		return 0
	fi
	if ((yes == 0)) && [[ "$INSTALL_NONINTERACTIVE" == "1" ]]; then
		die "self-update apply requires --yes in non-interactive mode"
	fi
	local tmp
	tmp=$(mktemp -d)
	run_cmd self-update.fetch git clone --depth 1 --branch "$branch" "$INSTALL_REPO_URL" "$tmp"
	local diff_rc
	set +e
	run_cmd self-update.diff diff -ruN "$SCRIPT_DIR" "$tmp/script"
	diff_rc=$?
	set -e
	if ((diff_rc > 1)); then
		rm -rf "$tmp"
		die "self-update diff failed"
	fi
	run_cmd self-update.apply rsync -a --delete --exclude install-state "$tmp/script/" "$SCRIPT_DIR/"
	rm -rf "$tmp"
	printf 'self-update: applied %s\n' "$branch"
}
