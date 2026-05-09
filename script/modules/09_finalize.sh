#!/usr/bin/env bash
# Final summary and self-update command domain.

install_final_command() {
	install_load_state_env
	run_cmd final.summary printf 'installation summary rendered\n'
	cat <<SUMMARY
===== INSTALLATION SUMMARY =====
Domain: ${WEBDOMAIN:-unspecified}
Public IPv4: ${PUBLIC_IPV4:-unspecified}
Public IPv6: ${PUBLIC_IPV6:-unspecified}
SSH: ${USER_SSH:-unspecified}@${PUBLIC_IPV4:-127.0.0.1}:${PORT_REMOTE_SSH:-unspecified}

Service URLs:
- Homepage: https://${WEBDOMAIN:-example.invalid}/${URI_HOMEPAGE:-}
- 3X-UI Panel: https://${WEBDOMAIN:-example.invalid}/${URI_PANEL_PATH:-}
- AdGuard Home: https://${WEBDOMAIN:-example.invalid}/${URI_ADGUARD_PANEL:-}
- Dozzle: https://${WEBDOMAIN:-example.invalid}/${URI_DOZZLE:-}
- Traefik Dashboard: https://${WEBDOMAIN:-example.invalid}/${URI_TRAEFIK_DASHBOARD:-}/dashboard/#/
SUMMARY
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
