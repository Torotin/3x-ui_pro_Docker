#!/usr/bin/env bash
# Firewall command domain.

install_firewall_ensure_ipv6() {
	local ufw_default="${INSTALL_UFW_DEFAULT:-/etc/default/ufw}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd firewall.ipv6.printf printf 'IPV6=yes\n'
		return 0
	fi
	[[ -f "$ufw_default" ]] && backup_file "$ufw_default"
	if grep -q '^IPV6=' "$ufw_default" 2>/dev/null; then
		sed -i 's/^IPV6=.*/IPV6=yes/' "$ufw_default"
	else
		printf 'IPV6=yes\n' >>"$ufw_default"
	fi
	run_cmd firewall.ipv6.ensure grep -q '^IPV6=yes' "$ufw_default"
}

install_firewall_command() {
	install_load_state_env
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"

	run_cmd firewall.plan printf 'allow tcp/80 tcp/443 udp/443 and configured PORT_REMOTE_* values\n'

	run_cmd firewall.apply ufw --force reset
	run_cmd firewall.apply ufw default deny incoming
	run_cmd firewall.apply ufw default allow outgoing
	run_cmd firewall.apply ufw default allow routed

	install_firewall_ensure_ipv6

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
