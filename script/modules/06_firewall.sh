#!/usr/bin/env bash
# Firewall command domain.

install_firewall_command() {
	install_load_state_env
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	run_cmd firewall.plan printf 'allow tcp/80 tcp/443 udp/443 and configured PORT_REMOTE_* values\n'
	run_cmd firewall.apply ufw --force reset
	run_cmd firewall.apply ufw default deny incoming
	run_cmd firewall.apply ufw default allow outgoing
	run_cmd firewall.apply ufw default allow routed
	local port_var port_value
	for port_var in $(compgen -v PORT_REMOTE_); do
		port_value=${!port_var}
		[[ "$port_value" =~ ^[0-9]+$ ]] || continue
		run_cmd firewall.apply ufw allow "${port_value}/tcp" comment "$port_var"
	done
	run_cmd firewall.apply ufw allow 80/tcp
	run_cmd firewall.apply ufw allow 443/tcp
	run_cmd firewall.apply ufw allow 443/udp
	run_cmd firewall.apply ufw --force enable
}
