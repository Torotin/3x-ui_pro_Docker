#!/usr/bin/env bash
# User command domain.

install_user_command() {
	install_load_state_env
	: "${USER_SSH:=}"
	USER_SSH=$(install_sanitize_user "$USER_SSH")
	[[ -n "$USER_SSH" ]] || die "USER_SSH is required"
	[[ "$USER_SSH" == "root" ]] && die "refusing to configure root as service SSH user"
	local home_dir
	home_dir=$(install_user_home_dir "$USER_SSH")
	install_user_account "$home_dir"
	if [[ -n "${PASS_SSH:-}" ]]; then
		run_cmd_stdin user.password "${USER_SSH}:${PASS_SSH}"$'\n' chpasswd
	fi
	install_user_ssh "$home_dir"
	install_user_groups
	install_user_sudo "$home_dir"
	install_user_aliases "$home_dir"
	run_cmd user.home.chown chown -R "$USER_SSH:$USER_SSH" "$home_dir"
	printf 'user configured: %s (%s)\n' "$USER_SSH" "$home_dir"
}

install_user_home_dir() {
	local user=$1 home=""
	if [[ "$INSTALL_MOCK" != "1" ]]; then
		home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
	fi
	printf '%s\n' "${home:-/home/$user}"
}

install_user_account() {
	local home_dir=$1
	if [[ "$INSTALL_MOCK" == "1" ]] || ! id -u "$USER_SSH" >/dev/null 2>&1; then
		run_cmd user.ensure useradd -m -d "$home_dir" -s /bin/bash "$USER_SSH"
	else
		log INFO "user already exists: $USER_SSH"
		run_cmd user.home.ensure install -d -m 0700 -o "$USER_SSH" -g "$USER_SSH" "$home_dir"
	fi
}

install_user_ssh() {
	local home_dir=$1
	local ssh_dir="$home_dir/.ssh" key_file="$home_dir/.ssh/id_ed25519" auth_keys="$home_dir/.ssh/authorized_keys"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd user.ssh.dir install -d -m 0700 -o "$USER_SSH" -g "$USER_SSH" "$ssh_dir"
		run_cmd user.ssh.keygen ssh-keygen -t ed25519 -N "" -f "$key_file" -C "$USER_SSH" -q
		run_cmd user.ssh.authorized install -m 0600 -o "$USER_SSH" -g "$USER_SSH" "$auth_keys"
		[[ -n "${SSH_PBK:-}" ]] && run_cmd user.ssh.authorized.add printf '%s\n' "$SSH_PBK"
		run_cmd user.ssh.authorized.add cat "$key_file.pub"
		run_cmd user.ssh.authorized.dedupe sort -u "$auth_keys" -o "$auth_keys"
		return 0
	fi
	run_cmd user.ssh.dir install -d -m 0700 -o "$USER_SSH" -g "$USER_SSH" "$ssh_dir"
	if [[ ! -f "$key_file" ]]; then
		run_cmd user.ssh.keygen sudo -u "$USER_SSH" ssh-keygen -t ed25519 -N "" -f "$key_file" -C "$USER_SSH" -q
	fi
	run_cmd user.ssh.authorized touch "$auth_keys"
	run_cmd user.ssh.authorized.chmod chmod 0600 "$auth_keys"
	run_cmd user.ssh.authorized.chown chown "$USER_SSH:$USER_SSH" "$auth_keys"
	install_user_authorized_key "$auth_keys" "${SSH_PBK:-}"
	if [[ -f "$key_file.pub" ]]; then
		install_user_authorized_key "$auth_keys" "$(cat "$key_file.pub")"
	fi
	run_cmd user.ssh.authorized.dedupe sort -u "$auth_keys" -o "$auth_keys"
	run_cmd user.ssh.authorized.chown chown "$USER_SSH:$USER_SSH" "$auth_keys"
}

install_user_authorized_key() {
	local auth_keys=$1 key=$2
	[[ -n "$key" ]] || return 0
	grep -qxF "$key" "$auth_keys" 2>/dev/null && return 0
	printf '%s\n' "$key" >>"$auth_keys"
}

install_user_groups() {
	local group groups=()
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd user.groups usermod -aG sudo,docker "$USER_SSH"
		return 0
	fi
	for group in sudo docker; do
		if getent group "$group" >/dev/null 2>&1; then
			groups+=("$group")
		else
			log WARN "group not found, skipping: $group"
		fi
	done
	((${#groups[@]} > 0)) || return 0
	local joined
	joined=$(
		IFS=,
		printf '%s' "${groups[*]}"
	)
	run_cmd user.groups usermod -aG "$joined" "$USER_SSH"
}

install_user_sudo() {
	local home_dir=$1
	local sudoers_file="/etc/sudoers.d/$USER_SSH"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd user.sudoers.write install -m 0440 sudoers "$sudoers_file"
		return 0
	fi
	backup_file "$sudoers_file"
	local tmp
	tmp=$(mktemp)
	install_user_sudoers_content >"$tmp"
	run_cmd user.sudoers.write install -m 0440 "$tmp" "$sudoers_file"
	rm -f "$tmp"
}

install_user_sudoers_content() {
	printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_SSH"
}

install_user_aliases() {
	local home_dir=$1
	local src="$SCRIPT_DIR/template/.bash_aliases.template" dst="$home_dir/.bash_aliases" bashrc="$home_dir/.bashrc"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd user.aliases.install install -m 0644 -o "$USER_SSH" -g "$USER_SSH" "$src" "$dst"
		run_cmd user.aliases.bashrc grep -qxF '[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases' "$bashrc"
		return 0
	fi
	if [[ ! -f "$src" ]]; then
		log WARN "alias template not found: $src"
		return 0
	fi
	run_cmd user.aliases.install install -m 0644 -o "$USER_SSH" -g "$USER_SSH" "$src" "$dst"
	if ! grep -qxF '[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases' "$bashrc" 2>/dev/null; then
		printf '%s\n' '[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases' >>"$bashrc"
		run_cmd user.aliases.bashrc.chown chown "$USER_SSH:$USER_SSH" "$bashrc"
	fi
}
