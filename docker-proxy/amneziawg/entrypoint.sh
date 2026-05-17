#!/bin/sh
set -eu

umask 077

: "${AMNEZIAWG_CONFIG_DIR:=/config}"
: "${AMNEZIAWG_INTERFACE:=awg0}"
: "${AMNEZIAWG_LISTEN_PORT:=443}"
: "${AMNEZIAWG_INTERNAL_PORT:=51820}"
: "${AMNEZIAWG_SERVER_ADDRESS:=10.66.66.1/24}"
: "${AMNEZIAWG_CLIENT_IPV4_PREFIX:=10.66.66}"
: "${AMNEZIAWG_CLIENT_COUNT:=1}"
: "${AMNEZIAWG_CLIENT_DNS:=1.1.1.1,8.8.8.8}"
: "${AMNEZIAWG_ENDPOINT_HOST:=${WEBDOMAIN:-example.invalid}}"
: "${AMNEZIAWG_MTU:=1420}"
: "${AMNEZIAWG_NAT_BACKEND:=auto}"
: "${AMNEZIAWG_IPV6_ENABLE:=false}"
: "${AMNEZIAWG_JC:=4}"
: "${AMNEZIAWG_JMIN:=64}"
: "${AMNEZIAWG_JMAX:=128}"
: "${AMNEZIAWG_S1:=0}"
: "${AMNEZIAWG_S2:=0}"
: "${AMNEZIAWG_H1:=1}"
: "${AMNEZIAWG_H2:=2}"
: "${AMNEZIAWG_H3:=3}"
: "${AMNEZIAWG_H4:=4}"

server_dir="$AMNEZIAWG_CONFIG_DIR/server"
client_dir="$AMNEZIAWG_CONFIG_DIR/clients"
runtime_dir="$AMNEZIAWG_CONFIG_DIR/runtime"
server_conf="$server_dir/${AMNEZIAWG_INTERFACE}.conf"

log() {
	printf '%s\n' "$*" >&2
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		log "missing required command: $1"
		exit 1
	}
}

install_dirs() {
	mkdir -p "$server_dir" "$client_dir" "$runtime_dir"
	chmod 700 "$server_dir" "$client_dir" "$runtime_dir"
}

write_private_key() {
	local path=$1
	[ -s "$path" ] && return 0
	awg genkey >"$path"
	chmod 600 "$path"
}

write_public_key() {
	local private=$1 public=$2
	[ -s "$public" ] && return 0
	awg pubkey <"$private" >"$public"
	chmod 600 "$public"
}

write_psk() {
	local path=$1
	[ -s "$path" ] && return 0
	awg genpsk >"$path"
	chmod 600 "$path"
}

detect_egress_interface() {
	ip route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

detect_nat_backend() {
	case "$AMNEZIAWG_NAT_BACKEND" in
	nft|iptables)
		printf '%s\n' "$AMNEZIAWG_NAT_BACKEND"
		return 0
		;;
	auto)
		if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
			printf 'nft\n'
			return 0
		fi
		if command -v iptables >/dev/null 2>&1; then
			if iptables -V 2>/dev/null | grep -qi nf_tables; then
				printf 'iptables\n'
				return 0
			fi
			log "iptables exists but is not iptables-nft; set AMNEZIAWG_NAT_BACKEND explicitly after validating legacy compatibility"
			exit 1
		fi
		;;
	*)
		log "unsupported AMNEZIAWG_NAT_BACKEND=$AMNEZIAWG_NAT_BACKEND"
		exit 1
		;;
	esac
	log "no supported NAT backend found (need nftables or iptables-nft)"
	exit 1
}

nft_post_up() {
	local iface=$1
	printf 'nft add table ip amneziawg; nft add chain ip amneziawg postrouting { type nat hook postrouting priority srcnat \\; }; nft add rule ip amneziawg postrouting oifname "%s" masquerade\n' "$iface"
}

nft_post_down() {
	printf 'nft delete table ip amneziawg\n'
}

iptables_post_up() {
	local iface=$1
	printf 'iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\n' "$iface"
}

iptables_post_down() {
	local iface=$1
	printf 'iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n' "$iface"
}

validate_preflight() {
	[ -c /dev/net/tun ] || {
		log "/dev/net/tun is not available"
		exit 1
	}
	if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 0)" != "1" ]; then
		log "net.ipv4.ip_forward must be 1"
		exit 1
	fi
	if [ "${STRICT_DNS_CHECK:-true}" = "true" ]; then
		if command -v getent >/dev/null 2>&1; then
			getent hosts "$AMNEZIAWG_ENDPOINT_HOST" >/dev/null 2>&1 || {
				log "AMNEZIAWG_ENDPOINT_HOST does not resolve: $AMNEZIAWG_ENDPOINT_HOST"
				exit 1
			}
		else
			log "getent is unavailable; DNS preflight for $AMNEZIAWG_ENDPOINT_HOST skipped"
		fi
	fi
	[ "$AMNEZIAWG_IPV6_ENABLE" = "false" ] || {
		log "AmneziaWG IPv6 is not implemented in this clean-install stage"
		exit 1
	}
	case "$AMNEZIAWG_CLIENT_COUNT" in
	''|*[!0-9]*)
		log "AMNEZIAWG_CLIENT_COUNT must be numeric"
		exit 1
		;;
	esac
	if [ "$AMNEZIAWG_CLIENT_COUNT" -lt 1 ] || [ "$AMNEZIAWG_CLIENT_COUNT" -gt 253 ]; then
		log "AMNEZIAWG_CLIENT_COUNT must be in range 1..253"
		exit 1
	fi
}

generate_configs() {
	local server_private="$server_dir/server.key"
	local server_public="$server_dir/server.pub"
	local endpoint="$AMNEZIAWG_ENDPOINT_HOST:$AMNEZIAWG_LISTEN_PORT"
	local egress nat_backend postup postdown idx client_name client_private client_public client_psk client_conf client_ip

	write_private_key "$server_private"
	write_public_key "$server_private" "$server_public"
	egress=$(detect_egress_interface)
	[ -n "$egress" ] || {
		log "could not detect default egress interface"
		exit 1
	}
	nat_backend=$(detect_nat_backend)
	case "$nat_backend" in
	nft)
		postup=$(nft_post_up "$egress")
		postdown=$(nft_post_down)
		;;
	iptables)
		postup=$(iptables_post_up "$egress")
		postdown=$(iptables_post_down "$egress")
		;;
	esac

	{
		printf '[Interface]\n'
		printf 'PrivateKey = %s\n' "$(cat "$server_private")"
		printf 'Address = %s\n' "$AMNEZIAWG_SERVER_ADDRESS"
		printf 'ListenPort = %s\n' "$AMNEZIAWG_INTERNAL_PORT"
		printf 'MTU = %s\n' "$AMNEZIAWG_MTU"
		printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$AMNEZIAWG_JC" "$AMNEZIAWG_JMIN" "$AMNEZIAWG_JMAX"
		printf 'S1 = %s\nS2 = %s\n' "$AMNEZIAWG_S1" "$AMNEZIAWG_S2"
		printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AMNEZIAWG_H1" "$AMNEZIAWG_H2" "$AMNEZIAWG_H3" "$AMNEZIAWG_H4"
		printf 'PostUp = %s\n' "$postup"
		printf 'PostDown = %s\n' "$postdown"
	} >"$server_conf"
	chmod 600 "$server_conf"

	idx=1
	while [ "$idx" -le "$AMNEZIAWG_CLIENT_COUNT" ]; do
		client_name="client${idx}"
		client_private="$client_dir/${client_name}.key"
		client_public="$client_dir/${client_name}.pub"
		client_psk="$client_dir/${client_name}.psk"
		client_conf="$client_dir/${client_name}.conf"
		client_ip="${AMNEZIAWG_CLIENT_IPV4_PREFIX}.$((idx + 1))/32"
		write_private_key "$client_private"
		write_public_key "$client_private" "$client_public"
		write_psk "$client_psk"
		{
			printf '\n[Peer]\n'
			printf 'PublicKey = %s\n' "$(cat "$client_public")"
			printf 'PresharedKey = %s\n' "$(cat "$client_psk")"
			printf 'AllowedIPs = %s\n' "$client_ip"
		} >>"$server_conf"
		if [ ! -s "$client_conf" ]; then
			{
				printf '[Interface]\n'
				printf 'PrivateKey = %s\n' "$(cat "$client_private")"
				printf 'Address = %s\n' "$client_ip"
				printf 'DNS = %s\n' "$AMNEZIAWG_CLIENT_DNS"
				printf 'MTU = %s\n' "$AMNEZIAWG_MTU"
				printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$AMNEZIAWG_JC" "$AMNEZIAWG_JMIN" "$AMNEZIAWG_JMAX"
				printf 'S1 = %s\nS2 = %s\n' "$AMNEZIAWG_S1" "$AMNEZIAWG_S2"
				printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$AMNEZIAWG_H1" "$AMNEZIAWG_H2" "$AMNEZIAWG_H3" "$AMNEZIAWG_H4"
				printf '\n[Peer]\n'
				printf 'PublicKey = %s\n' "$(cat "$server_public")"
				printf 'PresharedKey = %s\n' "$(cat "$client_psk")"
				printf 'AllowedIPs = 0.0.0.0/0\n'
				printf 'Endpoint = %s\n' "$endpoint"
				printf 'PersistentKeepalive = 25\n'
			} >"$client_conf"
			chmod 600 "$client_conf"
		fi
		idx=$((idx + 1))
	done
}

shutdown() {
	awg-quick down "$server_conf" >/dev/null 2>&1 || true
}

main() {
	need_cmd awg
	need_cmd awg-quick
	need_cmd amneziawg-go
	need_cmd ip
	validate_preflight
	install_dirs
	generate_configs
	trap shutdown INT TERM EXIT
	awg-quick down "$server_conf" >/dev/null 2>&1 || true
	awg-quick up "$server_conf"
	log "AmneziaWG started on UDP $AMNEZIAWG_LISTEN_PORT; client configs are in $client_dir"
	while :; do
		sleep 3600 &
		wait $!
	done
}

main "$@"
