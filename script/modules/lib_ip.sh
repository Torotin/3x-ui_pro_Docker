#!/usr/bin/env bash
# Shared host IPv4/IPv6 connectivity probe for installer modules.

ip_probe_fetch_public_ip() {
	local family=$1
	local url ip
	local -a urls curl_opts

	if [[ "$family" == "4" ]]; then
		curl_opts=(-4)
		urls=(
			"https://api.ipify.org"
			"https://ipv4.icanhazip.com"
			"https://ifconfig.me/ip"
		)
	else
		curl_opts=(-6)
		urls=(
			"https://api64.ipify.org"
			"https://ipv6.icanhazip.com"
			"https://ifconfig.me/ip"
		)
	fi

	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		if [[ "$family" == "4" ]]; then
			[[ "${INSTALL_MOCK_IP_PROBE_IPV4:-1}" == "1" ]] || return 1
			run_cmd ip.detect.ipv4 curl -fsSL --max-time 5 "${urls[0]}"
			printf '%s\n' "${INSTALL_MOCK_PUBLIC_IPV4:-198.51.100.10}"
			return 0
		fi
		[[ "${INSTALL_MOCK_IP_PROBE_IPV6:-1}" == "1" ]] || return 1
		run_cmd ip.detect.ipv6 curl -fsSL --max-time 5 "${urls[0]}"
		printf '%s\n' "${INSTALL_MOCK_PUBLIC_IPV6:-2001:db8::10}"
		return 0
	fi

	for url in "${urls[@]}"; do
		ip="$(curl -fsS "${curl_opts[@]}" --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
		if [[ "$family" == "4" ]] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			printf '%s\n' "$ip"
			return 0
		fi
		if [[ "$family" == "6" ]] && [[ "$ip" == *:* ]] && [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			printf '%s\n' "$ip"
			return 0
		fi
	done
	return 1
}

ip_probe_has_ipv4() {
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		[[ "${INSTALL_MOCK_IP_PROBE_IPV4:-1}" == "1" ]] || return 1
		IP_PROBE_PUBLIC_IPV4="$(ip_probe_fetch_public_ip 4)" || return 1
		export IP_PROBE_PUBLIC_IPV4
		return 0
	fi
	if ! ip -4 route show default 2>/dev/null | grep -q .; then
		return 1
	fi
	IP_PROBE_PUBLIC_IPV4="$(ip_probe_fetch_public_ip 4)" || return 1
	export IP_PROBE_PUBLIC_IPV4
	return 0
}

ip_probe_has_ipv6() {
	if [[ "${INSTALL_MOCK:-0}" == "1" ]]; then
		[[ "${INSTALL_MOCK_IP_PROBE_IPV6:-1}" == "1" ]] || return 1
		IP_PROBE_PUBLIC_IPV6="$(ip_probe_fetch_public_ip 6)" || return 1
		export IP_PROBE_PUBLIC_IPV6
		return 0
	fi
	if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == "1" ]]; then
		return 1
	fi
	if ! ip -6 -o addr show scope global 2>/dev/null | grep -q .; then
		return 1
	fi
	if ! ip -6 route show default 2>/dev/null | grep -q .; then
		return 1
	fi
	IP_PROBE_PUBLIC_IPV6="$(ip_probe_fetch_public_ip 6)" || return 1
	export IP_PROBE_PUBLIC_IPV6
	return 0
}

ip_probe_resolve_host_mode() {
	local has_v4=0 has_v6=0

	if [[ -n "${PUBLIC_IPV4:-}" ]]; then
		has_v4=1
	elif ip_probe_has_ipv4; then
		PUBLIC_IPV4="$IP_PROBE_PUBLIC_IPV4"
		has_v4=1
	else
		PUBLIC_IPV4=""
	fi

	if [[ -n "${PUBLIC_IPV6:-}" ]]; then
		# Reject poisoned legacy fallback where v6 was copied from v4
		if [[ "$PUBLIC_IPV6" == "$PUBLIC_IPV4" ]] && [[ "$PUBLIC_IPV6" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			PUBLIC_IPV6=""
		fi
	fi
	if ip_probe_has_ipv6; then
		PUBLIC_IPV6="$IP_PROBE_PUBLIC_IPV6"
		has_v6=1
	else
		PUBLIC_IPV6=""
	fi

	if ((has_v4 == 1 && has_v6 == 1)); then
		HOST_IP_MODE=dual
	elif ((has_v4 == 1)); then
		HOST_IP_MODE=ipv4
	elif ((has_v6 == 1)); then
		die "IPv6-only host detected; this installer requires public IPv4 (HOST_IP_MODE dual|ipv4 only)"
	else
		die "Neither IPv4 nor IPv6 external connectivity detected; aborting"
	fi

	export HOST_IP_MODE PUBLIC_IPV4 PUBLIC_IPV6
}
