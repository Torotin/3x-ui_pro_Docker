#!/usr/bin/env bash
# SSH command domain.

install_ssh_command() {
	install_load_state_env
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	: "${USER_SSH:=}"
	: "${PORT_REMOTE_SSH:=}"
	[[ -n "$USER_SSH" && -n "$PORT_REMOTE_SSH" ]] || die "USER_SSH and PORT_REMOTE_SSH are required"
	[[ "$PORT_REMOTE_SSH" =~ ^[0-9]+$ ]] || die "PORT_REMOTE_SSH must be numeric"
	((PORT_REMOTE_SSH >= 1 && PORT_REMOTE_SSH <= 65535)) || die "PORT_REMOTE_SSH out of range"
	local template="$SCRIPT_DIR/template/sshd_config.template"
	local target="${INSTALL_SSHD_CONFIG:-/etc/ssh/sshd_config}"
	[[ -f "$template" ]] || die "template not found: $template"
	export USER_SSH PORT_REMOTE_SSH
	install_ssh_set_auth_mode
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		install_render_sshd_config "$template" "$target"
		run_cmd ssh.validate sshd -t -f "$target"
		install_ssh_reload_service
		return 0
	fi
	id "$USER_SSH" >/dev/null 2>&1 || die "user does not exist: $USER_SSH"
	backup_file "$target"
	install_render_sshd_config "$template" "$target"
	run_cmd ssh.validate sshd -t -f "$target" || {
		die "sshd_config validation failed"
	}
	install_ssh_reload_service
}

install_ssh_set_auth_mode() {
	if [[ -n "${SSH_PBK:-}" ]]; then
		PUBKEY_AUTH=yes
		PASSWORD_AUTH=no
	else
		PUBKEY_AUTH=no
		PASSWORD_AUTH=yes
	fi
	export PUBKEY_AUTH PASSWORD_AUTH
}

install_render_sshd_config() {
	local template=$1 target=$2
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd ssh.apply bash -c 'envsubst < "$1" > "$2"' _ "$template" "$target"
		return 0
	fi
	envsubst <"$template" >"$target"
}

install_ssh_reload_service() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd ssh.reload systemctl reload ssh
		return 0
	fi
	if run_cmd ssh.reload systemctl reload ssh; then
		printf 'SSH service reloaded: ssh\n'
		return 0
	fi
	if run_cmd ssh.reload systemctl reload sshd; then
		printf 'SSH service reloaded: sshd\n'
		return 0
	fi
	if run_cmd ssh.restart systemctl restart ssh; then
		printf 'SSH service restarted: ssh\n'
		return 0
	fi
	if run_cmd ssh.restart systemctl restart sshd; then
		printf 'SSH service restarted: sshd\n'
		return 0
	fi
	die "failed to reload or restart SSH service"
}
