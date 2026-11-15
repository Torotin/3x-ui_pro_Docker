#!/usr/bin/env bash
# SSH command domain.

install_ssh_command() {
	install_load_state_env
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	: "${USER_SSH:=}"
	: "${PORT_REMOTE_SSH:=}"
	# Sparse install.env (wizard required-only) lacks auto PORT_REMOTE_SSH until bootstrap/env.
	if [[ -z "$PORT_REMOTE_SSH" ]] && declare -F install_bootstrap_install_env >/dev/null 2>&1; then
		install_bootstrap_install_env
		: "${PORT_REMOTE_SSH:=}"
	fi
	[[ -n "$USER_SSH" && -n "$PORT_REMOTE_SSH" ]] || die "USER_SSH and PORT_REMOTE_SSH are required"
	[[ "$PORT_REMOTE_SSH" =~ ^[0-9]+$ ]] || die "PORT_REMOTE_SSH must be numeric"
	((PORT_REMOTE_SSH >= 1 && PORT_REMOTE_SSH <= 65535)) || die "PORT_REMOTE_SSH out of range"
	local template="$SCRIPT_DIR/template/sshd_config.template"
	local target="${INSTALL_SSHD_CONFIG:-/etc/ssh/sshd_config}"
	local service_unit backup=""
	[[ -f "$template" ]] || die "template not found: $template"
	export USER_SSH PORT_REMOTE_SSH
	install_ssh_set_auth_mode
	install_ssh_assert_auth_enabled
	install_ssh_log_context "$target"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		service_unit=$(install_ssh_detect_service)
		install_render_sshd_config "$template" "$target"
		run_cmd ssh.validate sshd -t -f "$target"
		install_ssh_apply_service "$service_unit" "$target" ""
		return 0
	fi
	id "$USER_SSH" >/dev/null 2>&1 || die "user does not exist: $USER_SSH"
	install_ssh_prepare_runtime
	service_unit=$(install_ssh_detect_service)
	backup=$(install_ssh_backup_config "$target")
	install_render_sshd_config "$template" "$target"
	run_cmd ssh.validate sshd -t -f "$target" || {
		die "sshd_config validation failed"
	}
	install_ssh_apply_service "$service_unit" "$target" "$backup"
}

install_ssh_set_auth_mode() {
	if [[ -n "${SSH_PBK:-}" ]]; then
		PUBKEY_AUTH=yes
		PASSWORD_AUTH=no
		SSH_AUTH_METHODS=publickey
	else
		PUBKEY_AUTH=no
		PASSWORD_AUTH=yes
		SSH_AUTH_METHODS=password
	fi
	export PUBKEY_AUTH PASSWORD_AUTH SSH_AUTH_METHODS
}

# Refuse a lockout config: at least one interactive auth method must stay enabled.
install_ssh_assert_auth_enabled() {
	local pubkey=${PUBKEY_AUTH:-no} password=${PASSWORD_AUTH:-no}
	if [[ "$pubkey" != "yes" && "$password" != "yes" ]]; then
		die "SSH auth lockout: PubkeyAuthentication and PasswordAuthentication are both disabled"
	fi
	case "${SSH_AUTH_METHODS:-}" in
	publickey | password | "publickey password" | "password publickey") ;;
	*)
		die "SSH_AUTH_METHODS is invalid or empty: ${SSH_AUTH_METHODS:-<unset>}"
		;;
	esac
}

install_ssh_log_context() {
	local target=$1 auth_mode
	if [[ "${PUBKEY_AUTH:-no}" == "yes" ]]; then
		auth_mode=public-key
	else
		auth_mode=password
	fi
	printf 'SSH target config: %s\n' "$target"
	printf 'SSH user: %s\n' "$USER_SSH"
	printf 'SSH port: %s\n' "$PORT_REMOTE_SSH"
	printf 'SSH auth mode: %s\n' "$auth_mode"
	printf 'SSH AuthenticationMethods: %s\n' "${SSH_AUTH_METHODS:-}"
}

install_render_sshd_config() {
	local template=$1 target=$2
	# Restrict envsubst to known template vars (avoid accidental $FOO in comments).
	local shell_format='${USER_SSH} ${PORT_REMOTE_SSH} ${PUBKEY_AUTH} ${PASSWORD_AUTH} ${SSH_AUTH_METHODS}'
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd ssh.apply bash -c 'envsubst "$3" < "$1" > "$2"' _ "$template" "$target" "$shell_format"
		return 0
	fi
	envsubst "$shell_format" <"$template" >"$target"
	printf 'SSH config rendered: %s\n' "$target"
}

install_ssh_reload_service() {
	local unit
	unit=$(install_ssh_detect_service)
	install_ssh_apply_service "$unit" "${INSTALL_SSHD_CONFIG:-/etc/ssh/sshd_config}" ""
}

install_ssh_detect_service() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd ssh.detect printf '%s\n' ssh
		printf 'ssh\n'
		return 0
	fi

	local unit=""

	unit=$(systemctl list-unit-files --no-legend 2>/dev/null \
		| awk '/^(ssh|sshd)\.service[[:space:]]/{print $1; exit}')

	[[ -n "$unit" ]] || unit=$(systemctl list-units --type=service --no-legend 2>/dev/null \
		| awk '/^(ssh|sshd)\.service[[:space:]]/{print $1; exit}')

	[[ -n "$unit" ]] || die "SSH service unit not found; socket activation alone is not supported for changing sshd_config Port"

	unit=${unit%.service}

	run_cmd ssh.detect printf '%s\n' "$unit" >/dev/null
	printf 'SSH service detected: %s\n' "$unit" >&2
	printf '%s\n' "$unit"
}

install_ssh_prepare_runtime() {
	run_cmd ssh.runtime.dir install -d -m 0755 -o root -g root /run/sshd
}

install_ssh_backup_config() {
	local target=$1 backup_dir="$INSTALL_STATE_DIR/backups" backup
	[[ -e "$target" ]] || return 0
	mkdir -p "$backup_dir"
	backup=$(backup_path "$target" "$backup_dir")
	run_cmd ssh.backup cp -a -- "$target" "$backup"
	printf 'SSH config backup: %s\n' "$backup" >&2
	printf '%s\n' "$backup"
}

install_ssh_restore_backup() {
	local backup=$1 target=$2 unit=$3
	local socket_unit="${unit}.socket"
	local override_dir="/etc/systemd/system/${socket_unit}.d"

	[[ -n "$backup" && -f "$backup" ]] || return 0

	run_cmd ssh.rollback cp -a -- "$backup" "$target" || true
	run_cmd ssh.rollback.validate sshd -t -f "$target" || true

	# Drop our ListenStream override so rollback rebinds the original port, not PORT_REMOTE_SSH.
	run_cmd ssh.rollback.socket.override.rm rm -f -- "${override_dir}/zz-3xui-port.conf" || true
	run_cmd ssh.rollback.socket.override.rmdir rmdir --ignore-fail-on-non-empty -- "$override_dir" || true
	run_cmd ssh.rollback.daemon.reload systemctl daemon-reload || true

	if install_ssh_socket_unit_exists "$unit"; then
		run_cmd ssh.rollback.socket.unmask systemctl unmask "$socket_unit" || true
		run_cmd ssh.rollback.socket.enable systemctl enable "$socket_unit" || true
		run_cmd ssh.rollback.socket.start systemctl start "$socket_unit" || true
	fi

	run_cmd ssh.rollback.restart systemctl restart "$unit" || true
}

install_ssh_apply_service() {
	local unit=$1 target=$2 backup=$3

	run_cmd ssh.effective.port sh -c '
		sshd -T -f "$1" | grep -E "^port[[:space:]]+"
	' _ "$target"

	# Prefer socket activation when present: Port= in sshd_config is ignored while
	# ssh.socket owns the listener (common Ubuntu default). Always rewrite the
	# socket ListenStream to PORT_REMOTE_SSH before claiming success.
	if install_ssh_socket_unit_exists "$unit"; then
		if install_ssh_configure_socket_activation "$unit" && install_ssh_service_ready "$unit"; then
			printf 'SSH socket ready on port: %s\n' "$PORT_REMOTE_SSH"
			return 0
		fi
		# One retry after a hard socket stop — generator drop-ins / stale fds can keep the old port.
		# Do not stop ssh.service: that can kill the active installer SSH session.
		printf 'SSH socket port %s not listening yet; retrying socket rebind\n' "$PORT_REMOTE_SSH" >&2
		run_cmd ssh.socket.stop systemctl stop "${unit}.socket" || true
		if install_ssh_configure_socket_activation "$unit" && install_ssh_service_ready "$unit"; then
			printf 'SSH socket ready on port: %s\n' "$PORT_REMOTE_SSH"
			return 0
		fi
	else
		run_cmd ssh.daemon.reload systemctl daemon-reload || true

		if run_cmd ssh.reload systemctl reload "$unit" && install_ssh_service_ready "$unit"; then
			printf 'SSH service reloaded and ready on port: %s\n' "$PORT_REMOTE_SSH"
			return 0
		fi

		if run_cmd ssh.restart systemctl restart "$unit" && install_ssh_service_ready "$unit"; then
			printf 'SSH service restarted and ready on port: %s\n' "$PORT_REMOTE_SSH"
			return 0
		fi
	fi

	run_cmd ssh.debug.status systemctl status "$unit" --no-pager || true
	run_cmd ssh.debug.socket systemctl status "${unit}.socket" --no-pager || true
	run_cmd ssh.debug.socket.cat systemctl cat "${unit}.socket" || true
	run_cmd ssh.debug.listen ss -H -ltnp || true
	run_cmd ssh.debug.journal journalctl -u "$unit" -u "${unit}.socket" -n 100 --no-pager || true

	install_ssh_restore_backup "$backup" "$target" "$unit"
	die "failed to expose SSH on port $PORT_REMOTE_SSH"
}

install_ssh_socket_unit_exists() {
	local unit=$1
	local socket_unit="${unit}.socket"

	if [[ "$INSTALL_MOCK" == "1" ]]; then
		[[ "${INSTALL_MOCK_SSH_SOCKET:-1}" == "1" ]]
		return
	fi

	if systemctl cat "$socket_unit" >/dev/null 2>&1; then
		return 0
	fi
	if [[ -f "/lib/systemd/system/${socket_unit}" || -f "/usr/lib/systemd/system/${socket_unit}" || -f "/etc/systemd/system/${socket_unit}" ]]; then
		return 0
	fi
	if systemctl list-unit-files --no-legend "$socket_unit" 2>/dev/null | awk '{print $1}' | grep -qx "$socket_unit"; then
		return 0
	fi
	return 1
}

install_ssh_service_ready() {
	local unit=$1
	local socket_unit="${unit}.socket"
	local timeout="${INSTALL_SSH_READY_TIMEOUT:-20}"
	local i

	if [[ "$INSTALL_MOCK" == "1" && "${INSTALL_MOCK_SSH_LISTENER_READY:-1}" == "0" ]]; then
		install_ssh_port_listening "$PORT_REMOTE_SSH" || true
		INSTALL_MOCK_SSH_LISTENER_READY=1
		export INSTALL_MOCK_SSH_LISTENER_READY
		return 1
	fi

	for ((i = 0; i < timeout; i++)); do
		if install_ssh_port_listening "$PORT_REMOTE_SSH"; then
			return 0
		fi
		sleep 1
	done

	return 1
}

install_ssh_port_listening() {
	local port=$1

	if command -v ss >/dev/null 2>&1; then
		# Match local port as the field after the last ':' (IPv4, IPv6, or *).
		run_cmd ssh.listener.check sh -c '
			ss -H -ltn 2>/dev/null | awk -v p="$1" "
				{
					n = split(\$4, a, \":\")
					if (a[n] == p) found = 1
				}
				END { exit found ? 0 : 1 }
			"
		' _ "$port"
		return
	fi

	run_cmd ssh.listener.check sh -c '
		lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
	' _ "$port"
}

# True when the kernel has usable IPv6 (needed before ListenStream=[::]:PORT).
install_ssh_host_has_ipv6() {
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		[[ "${INSTALL_MOCK_SSH_IPV6:-1}" == "1" ]]
		return
	fi
	[[ -f /proc/net/if_inet6 ]] || return 1
	[[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" != "1" ]]
}

install_ssh_configure_socket_activation() {
	local unit=$1
	local socket_unit="${unit}.socket"
	local override_dir="/etc/systemd/system/${socket_unit}.d"
	# zz- sorts after generator addresses.conf so ListenStream= reset wins.
	local override_file="${override_dir}/zz-3xui-port.conf"
	local has_ipv6=0

	install_ssh_socket_unit_exists "$unit" || return 1

	printf 'SSH socket activation found: %s\n' "$socket_unit" >&2

	if install_ssh_host_has_ipv6; then
		has_ipv6=1
	fi

	run_cmd ssh.socket.override.dir install -d -m 0755 -o root -g root "$override_dir"
	# Drop legacy installer override name if present.
	run_cmd ssh.socket.override.cleanup rm -f "${override_dir}/override.conf" || true

	# Emit IPv6 ListenStream only when the kernel supports it (separate scripts so
	# mock command logs reflect the chosen bind set, not a dead if-branch).
	if [[ "$has_ipv6" == "1" ]]; then
		run_cmd ssh.socket.override.write sh -c '
			{
				printf "%s\n" "[Socket]"
				printf "%s\n" "ListenStream="
				printf "ListenStream=0.0.0.0:%s\n" "$2"
				printf "ListenStream=[::]:%s\n" "$2"
				printf "%s\n" "BindIPv6Only=ipv6-only"
				printf "%s\n" "FreeBind=yes"
			} > "$1"
			chmod 0644 -- "$1"
		' _ "$override_file" "$PORT_REMOTE_SSH"
	else
		run_cmd ssh.socket.override.write sh -c '
			{
				printf "%s\n" "[Socket]"
				printf "%s\n" "ListenStream="
				printf "ListenStream=0.0.0.0:%s\n" "$2"
				printf "%s\n" "FreeBind=yes"
			} > "$1"
			chmod 0644 -- "$1"
		' _ "$override_file" "$PORT_REMOTE_SSH"
	fi

	# Stop only the socket unit. Stopping ssh.service can kill the active installer session.
	run_cmd ssh.socket.stop systemctl stop "$socket_unit" || true
	run_cmd ssh.daemon.reload systemctl daemon-reload
	run_cmd ssh.socket.start systemctl start "$socket_unit"
	# Apply new sshd_config to future connections without tearing down the current session.
	run_cmd ssh.reload systemctl reload "$unit" || true

	printf 'SSH socket activation restarted on port: %s\n' "$PORT_REMOTE_SSH" >&2
	if [[ "$INSTALL_MOCK" != "1" ]]; then
		systemctl show "$socket_unit" -p Listen --value 2>/dev/null | head -n 5 >&2 || true
	fi
	return 0
}
