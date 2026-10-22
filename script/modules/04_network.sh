#!/usr/bin/env bash
# Network/sysctl command domain.

install_network_load_ip_mode() {
	install_load_state_env 2>/dev/null || true
	: "${HOST_IP_MODE:=ipv4}"
	case "$HOST_IP_MODE" in
	dual)
		IPV6_FORWARDING=1
		IPV6_AUTOCONF=1
		IPV6_ACCEPT_RA=2
		;;
	ipv4)
		IPV6_FORWARDING=0
		IPV6_AUTOCONF=0
		IPV6_ACCEPT_RA=0
		;;
	*) die "unsupported HOST_IP_MODE=$HOST_IP_MODE for network apply" ;;
	esac
	export IPV6_FORWARDING IPV6_AUTOCONF IPV6_ACCEPT_RA
}

install_network_render_sysctl_file() {
	local template=$1 dest=$2
	install_network_load_ip_mode
	sed -e "s|__IPV6_FORWARDING__|${IPV6_FORWARDING}|g" \
		-e "s|__IPV6_AUTOCONF__|${IPV6_AUTOCONF}|g" \
		-e "s|__IPV6_ACCEPT_RA__|${IPV6_ACCEPT_RA}|g" \
		"$template" >"$dest"
}

install_network_command() {
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	local template="$SCRIPT_DIR/template/99-xray-network.conf.template"
	local target="${INSTALL_SYSCTL_CONF:-/etc/sysctl.d/99-xray.conf}"
	local rendered
	rendered=$(mktemp)
	install_network_render_sysctl_file "$template" "$rendered"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd network.apply printf '%s\n' "$(cat "$rendered")"
		cat "$rendered"
		run_cmd network.sysctl sysctl -p "$target"
		rm -f -- "$rendered"
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
	install -m 0644 "$rendered" "$target"
	rm -f -- "$rendered"
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
