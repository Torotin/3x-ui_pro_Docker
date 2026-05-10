#!/usr/bin/env bash
# Firewall command domain.

install_firewall_command() {
	install_load_state_env
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"

	run_cmd firewall.plan printf 'allow tcp/80 tcp/443 udp/443, current SSH port, and configured PORT_REMOTE_* values\n'

	run_cmd firewall.apply ufw --force reset
	run_cmd firewall.apply ufw default deny incoming
	run_cmd firewall.apply ufw default allow outgoing
	run_cmd firewall.apply ufw default allow routed

	# install_firewall_allow_current_ssh_port

	local port_var port_value
	for port_var in $(compgen -v PORT_REMOTE_); do
		port_value=${!port_var}
		[[ "$port_value" =~ ^[0-9]+$ ]] || continue
		((port_value >= 1 && port_value <= 65535)) || continue
		run_cmd firewall.apply ufw allow "${port_value}/tcp" comment "$port_var"
	done

	run_cmd firewall.apply ufw allow 80/tcp
	run_cmd firewall.apply ufw allow 443/tcp
	run_cmd firewall.apply ufw allow 443/udp

	run_cmd firewall.apply ufw --force enable
	run_cmd firewall.apply ufw status verbose
}

install_firewall_current_ssh_port() {
	local _client_ip _client_port _server_ip server_port
	[[ -n "${SSH_CONNECTION:-}" ]] || return 0
	read -r _client_ip _client_port _server_ip server_port _ <<<"$SSH_CONNECTION"
	[[ "$server_port" =~ ^[0-9]+$ ]] || return 0
	printf '%s\n' "$server_port"
}

install_firewall_allow_current_ssh_port() {
	local current_port
	current_port=$(install_firewall_current_ssh_port)
	[[ -n "$current_port" ]] || return 0
	run_cmd firewall.apply ufw allow "${current_port}/tcp" comment CURRENT_SSH_PORT
}
