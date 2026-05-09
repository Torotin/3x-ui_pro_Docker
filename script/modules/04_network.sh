#!/usr/bin/env bash
# Network/sysctl command domain.

install_network_command() {
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	local template="$SCRIPT_DIR/template/99-xray-network.conf.template"
	local target="${INSTALL_SYSCTL_CONF:-/etc/sysctl.d/99-xray.conf}"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd network.apply install -m 0644 "$template" "$target"
		run_cmd network.sysctl sysctl -p "$target"
		cat <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.core.rmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_default = 262144
net.core.wmem_max = 134217728
net.core.somaxconn = 30000
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
SYSCTL
		return 0
	fi
	local previous
	previous=$(mktemp)
	local had_previous=0
	if [[ -f "$target" ]]; then
		had_previous=1
		cp -- "$target" "$previous"
	fi
	backup_file "$target"
	install -m 0644 "$template" "$target"
	run_cmd network.modprobe modprobe tcp_bbr
	run_cmd network.modprobe modprobe nf_conntrack
	if ! run_cmd network.sysctl sysctl -p "$target"; then
		if ((had_previous)); then
			cp -- "$previous" "$target"
		else
			rm -f -- "$target"
		fi
		rm -f -- "$previous"
		die "network sysctl apply failed; previous config restored"
	fi
	rm -f -- "$previous"
}
