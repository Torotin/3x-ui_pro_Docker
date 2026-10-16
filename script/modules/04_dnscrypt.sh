#!/usr/bin/env bash
# Host DNSCrypt/DoH installer step. Runs before apt so package mirrors resolve over encrypted DNS.
# Install logic is inlined in this module.

# Empty = resolve latest from GitHub Releases. Override with --version or DNSCRYPT_VERSION.
DNSCRYPT_VERSION="${DNSCRYPT_VERSION:-}"
DNSCRYPT_INSTALL_DIR="${DNSCRYPT_INSTALL_DIR:-/opt/dnscrypt-proxy}"
DNSCRYPT_CONFIG_FILE="${DNSCRYPT_CONFIG_FILE:-$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy.toml}"
DNSCRYPT_SERVICE_FILE="${DNSCRYPT_SERVICE_FILE:-/etc/systemd/system/dnscrypt-proxy.service}"
DNSCRYPT_RESOLVED_DROPIN_DIR="${DNSCRYPT_RESOLVED_DROPIN_DIR:-/etc/systemd/resolved.conf.d}"
DNSCRYPT_RESOLVED_DROPIN="${DNSCRYPT_RESOLVED_DROPIN:-$DNSCRYPT_RESOLVED_DROPIN_DIR/dnscrypt-proxy.conf}"
DNSCRYPT_RESOLV_CONF="${DNSCRYPT_RESOLV_CONF:-${INSTALL_TEST_RESOLV_CONF:-/etc/resolv.conf}}"
DNSCRYPT_GITHUB_REPO="${DNSCRYPT_GITHUB_REPO:-DNSCrypt/dnscrypt-proxy}"
DNSCRYPT_GITHUB_API_LATEST="${DNSCRYPT_GITHUB_API_LATEST:-https://api.github.com/repos/${DNSCRYPT_GITHUB_REPO}/releases/latest}"

dnscrypt_detect_arch() {
	case "$(uname -m)" in
	x86_64 | amd64)
		DNSCRYPT_ARCHIVE_ARCH="linux_x86_64"
		DNSCRYPT_EXTRACT_DIR="linux-x86_64"
		;;
	aarch64 | arm64)
		DNSCRYPT_ARCHIVE_ARCH="linux_arm64"
		DNSCRYPT_EXTRACT_DIR="linux-arm64"
		;;
	armv7l | armhf)
		DNSCRYPT_ARCHIVE_ARCH="linux_arm"
		DNSCRYPT_EXTRACT_DIR="linux-arm"
		;;
	i386 | i686)
		DNSCRYPT_ARCHIVE_ARCH="linux_i386"
		DNSCRYPT_EXTRACT_DIR="linux-i386"
		;;
	*)
		die "Unsupported architecture: $(uname -m)"
		;;
	esac
}

# Resolve DNSCRYPT_VERSION to a concrete release (no leading v), then set archive URL.
dnscrypt_resolve_version() {
	local tag json
	if [[ -n "$DNSCRYPT_VERSION" ]]; then
		DNSCRYPT_VERSION="${DNSCRYPT_VERSION#v}"
		printf '[+] Using pinned version: %s\n' "$DNSCRYPT_VERSION"
	else
		printf '[+] Resolving latest dnscrypt-proxy release from GitHub\n'
		json="$(curl -fsSL --connect-timeout 5 --max-time 20 \
			-H 'Accept: application/vnd.github+json' \
			-H 'User-Agent: 3x-ui-pro-docker-dnscrypt' \
			"$DNSCRYPT_GITHUB_API_LATEST")" || die "Failed to query $DNSCRYPT_GITHUB_API_LATEST"
		if command -v python3 >/dev/null 2>&1; then
			tag="$(printf '%s' "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
		else
			tag="$(printf '%s' "$json" | tr -d '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
		fi
		[[ -n "$tag" ]] || die "Could not parse tag_name from GitHub API response"
		DNSCRYPT_VERSION="${tag#v}"
		printf '[+] Latest release: %s\n' "$DNSCRYPT_VERSION"
	fi
	[[ -n "$DNSCRYPT_ARCHIVE_ARCH" ]] || die "dnscrypt arch is not detected"
	DNSCRYPT_ARCHIVE="dnscrypt-proxy-${DNSCRYPT_ARCHIVE_ARCH}-${DNSCRYPT_VERSION}.tar.gz"
	DNSCRYPT_DOWNLOAD_URL="https://github.com/${DNSCRYPT_GITHUB_REPO}/releases/download/${DNSCRYPT_VERSION}/${DNSCRYPT_ARCHIVE}"
}

dnscrypt_parse_args() {
	DNSCRYPT_FORCE_REINSTALL=0
	DNSCRYPT_RECONFIGURE_ONLY=0
	while (($# > 0)); do
		case "$1" in
		--force) DNSCRYPT_FORCE_REINSTALL=1 ;;
		--reconfigure) DNSCRYPT_RECONFIGURE_ONLY=1 ;;
		--version)
			shift
			(($# > 0)) || die "dnscrypt: --version requires a value (e.g. 2.1.18)"
			DNSCRYPT_VERSION="$1"
			;;
		--version=*)
			DNSCRYPT_VERSION="${1#--version=}"
			;;
		--apply | --yes) ;;
		-h | --help)
			printf '%s\n' "dnscrypt flags: --force, --reconfigure, --version X.Y.Z (default: latest from GitHub; env DNSCRYPT_VERSION)"
			return 2
			;;
		--*)
			# Ignore other installer flags (--apply already consumed by caller).
			;;
		*)
			die "dnscrypt: unknown argument: $1"
			;;
		esac
		shift
	done
	if ((DNSCRYPT_FORCE_REINSTALL == 1 && DNSCRYPT_RECONFIGURE_ONLY == 1)); then
		die "dnscrypt: use either --force or --reconfigure, not both"
	fi
}

dnscrypt_installed_version() {
	local ver=""
	if [[ -x "$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" ]]; then
		# Avoid pipefail/SIGPIPE emptying the version under set -o pipefail.
		ver="$("$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" -version 2>/dev/null | head -n1 || true)"
		ver="${ver//[[:space:]]/}"
	fi
	printf '%s\n' "$ver"
}

dnscrypt_detect_existing() {
	DNSCRYPT_EXISTING_BINARY=0
	DNSCRYPT_EXISTING_UNIT=0
	DNSCRYPT_EXISTING_ACTIVE=0
	DNSCRYPT_EXISTING_ENABLED=0
	DNSCRYPT_INSTALLED_VERSION=""

	if [[ -x "$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" ]]; then
		DNSCRYPT_EXISTING_BINARY=1
		DNSCRYPT_INSTALLED_VERSION="$(dnscrypt_installed_version)"
	fi
	if [[ -f "$DNSCRYPT_SERVICE_FILE" ]]; then
		DNSCRYPT_EXISTING_UNIT=1
	fi
	if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
		DNSCRYPT_EXISTING_ACTIVE=1
	fi
	if systemctl is-enabled --quiet dnscrypt-proxy 2>/dev/null; then
		DNSCRYPT_EXISTING_ENABLED=1
	fi
}

# True when target version is already serving localhost DNS.
# Skips churn unless --force/--reconfigure is explicit (vendor always reconfigures).
dnscrypt_is_healthy_install() {
	local resolv="$DNSCRYPT_RESOLV_CONF" dig_target="127.0.0.1"
	((DNSCRYPT_EXISTING_BINARY == 1)) || return 1
	[[ -n "$DNSCRYPT_INSTALLED_VERSION" ]] || return 1
	[[ -n "$DNSCRYPT_VERSION" ]] || return 1
	[[ "$DNSCRYPT_INSTALLED_VERSION" == "$DNSCRYPT_VERSION" ]] || return 1
	((DNSCRYPT_EXISTING_ACTIVE == 1)) || return 1
	((DNSCRYPT_EXISTING_ENABLED == 1)) || return 1
	[[ -r "$resolv" ]] || return 1
	grep -Eq 'nameserver[[:space:]]+(127\.0\.0\.1|::1)([[:space:]]|$)' "$resolv" || return 1
	if grep -Eq 'nameserver[[:space:]]+127\.0\.0\.1([[:space:]]|$)' "$resolv"; then
		dig_target="127.0.0.1"
	else
		dig_target="::1"
	fi
	command -v dig >/dev/null 2>&1 || return 1
	dig +time=2 +tries=1 +short example.com "@${dig_target}" >/dev/null 2>&1
}

dnscrypt_decide_mode() {
	DNSCRYPT_MODE="install"
	DNSCRYPT_SKIP_HEALTHY=0
	if ((DNSCRYPT_FORCE_REINSTALL == 1)); then
		DNSCRYPT_MODE="install"
		printf '[+] Mode: full reinstall (--force) -> %s\n' "$DNSCRYPT_VERSION"
	elif ((DNSCRYPT_RECONFIGURE_ONLY == 1)); then
		if ((DNSCRYPT_EXISTING_BINARY == 0)); then
			die "--reconfigure requested, but $DNSCRYPT_INSTALL_DIR/dnscrypt-proxy is missing"
		fi
		DNSCRYPT_MODE="reconfigure"
		printf '[+] Mode: reconfigure only (--reconfigure), target %s\n' "$DNSCRYPT_VERSION"
	elif ((DNSCRYPT_EXISTING_BINARY == 1)); then
		if [[ "$DNSCRYPT_INSTALLED_VERSION" == "$DNSCRYPT_VERSION" ]]; then
			if dnscrypt_is_healthy_install; then
				DNSCRYPT_MODE="skip"
				DNSCRYPT_SKIP_HEALTHY=1
				printf '[+] Mode: already installed and healthy (%s); skipping (use --force or --reconfigure to refresh)\n' "$DNSCRYPT_VERSION"
			else
				DNSCRYPT_MODE="reconfigure"
				printf '[+] Mode: reconfigure (already at latest %s but not healthy; use --force to wipe/reinstall)\n' "$DNSCRYPT_VERSION"
			fi
		else
			DNSCRYPT_MODE="upgrade"
			printf '[+] Mode: upgrade (%s -> %s)\n' "${DNSCRYPT_INSTALLED_VERSION:-unknown}" "$DNSCRYPT_VERSION"
		fi
	else
		printf '[+] Mode: fresh install (%s)\n' "$DNSCRYPT_VERSION"
	fi
}

dnscrypt_fetch_public_ip() {
	local family="$1"
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

dnscrypt_has_ipv4_connectivity() {
	if ! ip -4 route show default 2>/dev/null | grep -q .; then
		return 1
	fi
	DNSCRYPT_PUBLIC_IPV4="$(dnscrypt_fetch_public_ip 4)" || return 1
	export DNSCRYPT_PUBLIC_IPV4
	return 0
}

dnscrypt_has_ipv6_connectivity() {
	if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == "1" ]]; then
		return 1
	fi
	if ! ip -6 -o addr show scope global 2>/dev/null | grep -q .; then
		return 1
	fi
	if ! ip -6 route show default 2>/dev/null | grep -q .; then
		return 1
	fi
	DNSCRYPT_PUBLIC_IPV6="$(dnscrypt_fetch_public_ip 6)" || return 1
	export DNSCRYPT_PUBLIC_IPV6
	return 0
}

dnscrypt_switch_to_public_dns() {
	local resolv="$DNSCRYPT_RESOLV_CONF"
	chattr -i "$resolv" 2>/dev/null || true
	rm -f -- "$resolv"
	printf '%s\n' \
		'nameserver 9.9.9.9' \
		'nameserver 1.1.1.1' \
		'nameserver 2620:fe::fe' \
		'nameserver 2606:4700:4700::1111' \
		'options edns0' >"$resolv"
}

dnscrypt_remove_distro_bits() {
	printf '[+] Removing distro package leftovers (if any)\n'
	systemctl stop dnscrypt-proxy.socket 2>/dev/null || true
	systemctl disable dnscrypt-proxy.socket 2>/dev/null || true
	rm -f -- /etc/systemd/system/dnscrypt-proxy.socket
	rm -rf -- /etc/systemd/system/dnscrypt-proxy.service.d
	apt-get purge -y dnscrypt-proxy || true
}

dnscrypt_install_binary() {
	local workdir
	printf '[+] Downloading dnscrypt-proxy %s (%s)\n' "$DNSCRYPT_VERSION" "$DNSCRYPT_ARCHIVE_ARCH"
	printf '    %s\n' "$DNSCRYPT_DOWNLOAD_URL"
	workdir="$(mktemp -d /tmp/dnscrypt-proxy-install.XXXXXX)"
	# shellcheck disable=SC2064
	trap "rm -rf -- '$workdir'" RETURN

	run_cmd dnscrypt.download curl -fsSL -o "$workdir/$DNSCRYPT_ARCHIVE" "$DNSCRYPT_DOWNLOAD_URL"
	tar -xzf "$workdir/$DNSCRYPT_ARCHIVE" -C "$workdir"

	if [[ ! -x "$workdir/$DNSCRYPT_EXTRACT_DIR/dnscrypt-proxy" ]]; then
		die "Binary not found in archive ($DNSCRYPT_EXTRACT_DIR/dnscrypt-proxy)"
	fi

	printf '[+] Installing binaries\n'
	systemctl stop dnscrypt-proxy 2>/dev/null || true
	mkdir -p -- "$DNSCRYPT_INSTALL_DIR"
	if [[ "$DNSCRYPT_MODE" == "install" ]]; then
		rm -rf -- "$DNSCRYPT_INSTALL_DIR"
		mkdir -p -- "$DNSCRYPT_INSTALL_DIR"
	fi
	cp -a "$workdir/$DNSCRYPT_EXTRACT_DIR/." "$DNSCRYPT_INSTALL_DIR/"
	chmod 755 "$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy"

	printf '[+] Removing unused package files\n'
	rm -f -- \
		"$DNSCRYPT_INSTALL_DIR"/example-* \
		"$DNSCRYPT_INSTALL_DIR/localhost.pem" \
		"$DNSCRYPT_INSTALL_DIR/LICENSE"
	trap - RETURN
	rm -rf -- "$workdir"
}

dnscrypt_detect_connectivity() {
	local server_names_v4 server_names_v6

	server_names_v4="
  'quad9-dnscrypt-ip4-nofilter-pri',
  'cloudflare',
  'dns.sb',
  'controld-unfiltered',
  'adguard-dns-unfiltered-doh',
  'uncensoreddns-ipv4',
  'dnsforge.de-nofilter',
  'scaleway-fr',
  'scaleway-ams',
  'wikimedia'
"
	server_names_v6="
  'quad9-dnscrypt-ip6-nofilter-pri',
  'cloudflare-ipv6',
  'adguard-dns-unfiltered-doh-ipv6',
  'uncensoreddns-ipv6',
  'dnsforge.de-nofilter-ipv6',
  'scaleway-fr-ipv6',
  'scaleway-ams-ipv6',
  'circl-doh-ipv6',
  'bortzmeyer-ipv6',
  'quad9-doh-ip6-port443-nofilter-pri'
"

	DNSCRYPT_HAS_IPV4=0
	DNSCRYPT_HAS_IPV6=0
	DNSCRYPT_PUBLIC_IPV4=""
	DNSCRYPT_PUBLIC_IPV6=""

	printf '[+] Detecting external IPv4/IPv6 connectivity\n'
	if dnscrypt_has_ipv4_connectivity; then
		DNSCRYPT_HAS_IPV4=1
		printf '[+] External IPv4 OK: %s\n' "$DNSCRYPT_PUBLIC_IPV4"
	else
		printf '[!] No external IPv4 connectivity\n'
	fi

	if dnscrypt_has_ipv6_connectivity; then
		DNSCRYPT_HAS_IPV6=1
		printf '[+] External IPv6 OK: %s\n' "$DNSCRYPT_PUBLIC_IPV6"
	else
		printf '[!] No external IPv6 connectivity\n'
	fi

	if ((DNSCRYPT_HAS_IPV4 == 0 && DNSCRYPT_HAS_IPV6 == 0)); then
		die "Neither IPv4 nor IPv6 external connectivity detected; aborting"
	fi

	if ((DNSCRYPT_HAS_IPV4 == 1 && DNSCRYPT_HAS_IPV6 == 1)); then
		DNSCRYPT_LISTEN_ADDRESSES="['127.0.0.1:53', '[::1]:53']"
		DNSCRYPT_IPV4_SERVERS="true"
		DNSCRYPT_IPV6_SERVERS="true"
		DNSCRYPT_BLOCK_IPV6="false"
		DNSCRYPT_BOOTSTRAP_RESOLVERS="['9.9.9.11:53', '1.1.1.1:53', '[2620:fe::11]:53', '[2606:4700:4700::1111]:53']"
		DNSCRYPT_SERVER_NAMES="[${server_names_v4},${server_names_v6}]"
		DNSCRYPT_RESOLV_CONF_CONTENT=$'nameserver 127.0.0.1\nnameserver ::1\noptions edns0'
		DNSCRYPT_TEMP_RESOLV_CONF_CONTENT=$'nameserver 9.9.9.9\nnameserver 1.1.1.1\nnameserver 2606:4700:4700::1111\noptions edns0'
		DNSCRYPT_RESOLVED_DNS_LINE="DNS=127.0.0.1 ::1"
		printf '[+] Dual-stack — IPv4+IPv6 listen, resolvers and bootstrap\n'
	elif ((DNSCRYPT_HAS_IPV4 == 1)); then
		DNSCRYPT_LISTEN_ADDRESSES="['127.0.0.1:53']"
		DNSCRYPT_IPV4_SERVERS="true"
		DNSCRYPT_IPV6_SERVERS="false"
		DNSCRYPT_BLOCK_IPV6="true"
		DNSCRYPT_BOOTSTRAP_RESOLVERS="['9.9.9.11:53', '1.1.1.1:53']"
		DNSCRYPT_SERVER_NAMES="[${server_names_v4}]"
		DNSCRYPT_RESOLV_CONF_CONTENT=$'nameserver 127.0.0.1\noptions edns0'
		DNSCRYPT_TEMP_RESOLV_CONF_CONTENT=$'nameserver 9.9.9.9\nnameserver 1.1.1.1\noptions edns0'
		DNSCRYPT_RESOLVED_DNS_LINE="DNS=127.0.0.1"
		printf '[+] IPv4-only — listen/server_names on IPv4, block_ipv6=true\n'
	else
		DNSCRYPT_LISTEN_ADDRESSES="['[::1]:53']"
		DNSCRYPT_IPV4_SERVERS="false"
		DNSCRYPT_IPV6_SERVERS="true"
		DNSCRYPT_BLOCK_IPV6="false"
		DNSCRYPT_BOOTSTRAP_RESOLVERS="['[2620:fe::11]:53', '[2606:4700:4700::1111]:53']"
		DNSCRYPT_SERVER_NAMES="[${server_names_v6}]"
		DNSCRYPT_RESOLV_CONF_CONTENT=$'nameserver ::1\noptions edns0'
		DNSCRYPT_TEMP_RESOLV_CONF_CONTENT=$'nameserver 2606:4700:4700::1111\nnameserver 2620:fe::fe\noptions edns0'
		DNSCRYPT_RESOLVED_DNS_LINE="DNS=::1"
		printf '[+] IPv6-only — listen/server_names on IPv6\n'
	fi

	DNSCRYPT_SERVER_NAMES="$(printf '%s' "$DNSCRYPT_SERVER_NAMES" | tr -d '\n' | sed -E 's/[[:space:]]+/ /g; s|\[ |[|; s| \]|]|')"
}

dnscrypt_write_config() {
	printf '[+] Creating config\n'
	cat >"$DNSCRYPT_CONFIG_FILE" <<'EOF'
##############################################
#                                            #
#        dnscrypt-proxy configuration        #
#                                            #
##############################################

## This is an example configuration file.
## You should adjust it to your needs, and save it as "dnscrypt-proxy.toml"
##
## Online documentation is available here: https://dnscrypt.info/doc


###############################################################################
#                             Global settings                                  #
###############################################################################

## List of servers to use
##
## Servers from the "public-resolvers" source (see down below) can
## be viewed here: https://dnscrypt.info/public-servers
##
## The proxy will automatically pick working servers from this list.
## Note that the require_* filters do NOT apply when using this setting.
##
## By default, this list is empty and all registered servers matching the
## require_* filters will be used instead.
##
## Remove the leading # first to enable this; lines starting with # are ignored.

server_names = __SERVER_NAMES__


## List of local addresses and ports to listen to. Can be IPv4 and/or IPv6.
## Example with both IPv4 and IPv6:
## listen_addresses = ['127.0.0.1:53', '[::1]:53']
##
## To listen to all IPv4 addresses, use `listen_addresses = ['0.0.0.0:53']`
## To listen to all IPv4+IPv6 addresses, use `listen_addresses = ['[::]:53']`

listen_addresses = __LISTEN_ADDRESSES__


## Maximum number of simultaneous client connections to accept

max_clients = 250


## Switch to a different system user after listening sockets have been created.
## Note (1): this feature is currently unsupported on Windows.
## Note (2): this feature is not compatible with systemd socket activation.
## Note (3): when using -pidfile, the PID file directory must be writable by the new user

# user_name = 'nobody'


###############################################################################
#                            Server Selection                                  #
###############################################################################

## Require servers (from remote sources) to satisfy specific properties

# Use servers reachable over IPv4
ipv4_servers = __IPV4_SERVERS__

# Use servers reachable over IPv6 -- Do not enable if you don't have IPv6 connectivity
ipv6_servers = __IPV6_SERVERS__

# Use servers implementing the DNSCrypt protocol
dnscrypt_servers = true

# Use servers implementing the DNS-over-HTTPS protocol
doh_servers = true

# Use servers implementing the Oblivious DoH protocol
odoh_servers = false


## Require servers defined by remote sources to satisfy specific properties

# Server must support DNS security extensions (DNSSEC)
require_dnssec = true

# Server must not log user queries (declarative)
require_nolog = true

# Server must not enforce its own blocklist (for parental control, ads blocking...)
require_nofilter = true

# Server names to avoid even if they match all criteria
disabled_server_names = []


###############################################################################
#                           Connection Settings                                #
###############################################################################

## Always use TCP to connect to upstream servers.
## This can be useful if you need to route everything through Tor.
## Otherwise, leave this to `false`, as it doesn't improve security
## (dnscrypt-proxy will always encrypt everything even using UDP), and can
## only increase latency.

force_tcp = false


## Enable *experimental* support for HTTP/3 (HTTP over QUIC)
## Note that, like DNSCrypt but unlike other HTTP versions, this uses
## UDP and (usually) port 443 instead of TCP.

http3 = false

## When http3 is true, always try HTTP/3 first for DoH servers.
## If the HTTP/3 connection fails, fallback to HTTP/2 and don't try
## HTTP/3 again for that server. By default, HTTP/3 is only used for
## servers that advertise support via the Alt-Svc header.
##
## WARNING: This setting is disabled by default because it will make
## connections significantly slower for servers that don't support HTTP/3.
## This is primarily a workaround for server operators who haven't
## configured their servers to send proper Alt-Svc headers. The better
## solution is to reach out to these operators and encourage them to
## fix their servers to correctly advertise HTTP/3 support.

http3_probe = false


## SOCKS proxy
## Uncomment the following line to route all TCP connections to a local Tor node
## Tor doesn't support UDP, so set `force_tcp` to `true` as well. When passing
## a random username and password to Tor's socks5 connection, dnscrypt-proxy gets
## an isolated circuit so it will not share an exit node with other applications.
## Note: the random username and password used by dnscrypt-proxy should not
## actually be defined in Tor's configuration.

# proxy = 'socks5://dnscrypt:dnscrypt@127.0.0.1:9050'


## HTTP/HTTPS proxy
## Only for DoH servers

# http_proxy = 'http://127.0.0.1:8888'


## How long a DNS query will wait for a response, in milliseconds.
## If you have a network with *a lot* of latency, you may need to
## increase this. Startup may be slower if you do so.
## Don't increase it too much. 10000 is the highest reasonable value.
## A timeout below 5000 is not recommended.

timeout = 5000


## Keepalive for HTTP (HTTPS, HTTP/2, HTTP/3) queries, in seconds

keepalive = 30


## Add EDNS-client-subnet information to outgoing queries
##
## Multiple networks can be listed; they will be randomly chosen.
## These networks don't have to match your actual networks.

# edns_client_subnet = ['0.0.0.0/0', '2001:db8::/32']


## Response for blocked queries. Options are `refused`, `hinfo` (default) or
## an IP response. To give an IP response, use the format `a:<IPv4>,aaaa:<IPv6>`.
## Using the `hinfo` option means that some responses will be lies.
## Unfortunately, the `hinfo` option appears to be required for Android 8+

# blocked_query_response = 'refused'


###############################################################################
#                        Load Balancing & Performance                          #
###############################################################################

## Load-balancing strategy: 'wp2' (default), 'p2', 'ph', 'p<n>', 'first', or 'random'
## 'wp2' (default): Weighted Power of Two - selects the better performing server
## from two random candidates based on real-time RTT and success rates.
## 'p2': Randomly choose 1 of the fastest 2 servers by latency.
## 'ph': Randomly choose from fastest half of servers.
## 'p<n>': Randomly choose from fastest n servers (e.g., 'p3' for fastest 3).
## 'first': Always use the fastest server.
## 'random': Randomly choose from all servers.
## The response quality still depends on the server itself.

lb_strategy = 'wp2'

## Set to `true` to constantly try to estimate the latency of all the resolvers
## and adjust the load-balancing parameters accordingly, or to `false` to disable.
## Default is `true` that makes 'p2' `lb_strategy` work well.

lb_estimator = true

## Set to `true` to enable hot reloading of configuration files (like allowed-names.txt,
## blocked-names.txt, etc.) when they are modified. This can increase CPU and memory usage.
## Default is `false` (hot reloading is disabled).

# enable_hot_reload = false


###############################################################################
#                                Logging                                       #
###############################################################################

## Log level (0-6, default: 2 - 0 is very verbose, 6 only contains fatal errors)

# log_level = 2


## Log file for the application, as an alternative to sending logs to
## the standard system logging service (syslog/Windows event log).
##
## This file is different from other log files, and will not be
## automatically rotated by the application.

# log_file = 'dnscrypt-proxy.log'


## When using a log file, only keep logs from the most recent launch.

# log_file_latest = true


## Use the system logger (syslog on Unix, Event Log on Windows)

use_syslog = true


## Automatic log files rotation

# Maximum log files size in MB - Set to 0 for unlimited.
log_files_max_size = 10

# How long to keep backup files, in days
log_files_max_age = 7

# Maximum log files backups to keep (or 0 to keep all backups)
log_files_max_backups = 1


###############################################################################
#                           Certificate Management                             #
###############################################################################

## The maximum concurrency to reload certificates from the resolvers.
## Default is 10.

# cert_refresh_concurrency = 10


## Delay, in minutes, after which certificates are reloaded

cert_refresh_delay = 240


## Initially don't check DNSCrypt server certificates for expiration, and
## only start checking them after a first successful connection to a resolver.
## This can be useful on routers with no battery-backed clock.

# cert_ignore_timestamp = false


## DNSCrypt: Create a new, unique key for every single DNS query
## This may improve privacy but can also have a significant impact on CPU usage
## Only enable if you don't have a lot of network load

# dnscrypt_ephemeral_keys = false


## DoH: Disable TLS session tickets - increases privacy but also latency

# tls_disable_session_tickets = false


## DoH: Use TLS 1.2 and specific cipher suite instead of the server preference
## 49199 = TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
## 49195 = TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
## 52392 = TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
## 52393 = TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
##
## On non-Intel CPUs such as MIPS routers and ARM systems (Android, Raspberry Pi...),
## uncommenting the following line may improve performance.
## This may also help on Intel CPUs running 32-bit operating systems.
## However, this can cause issues fetching sources or connecting to some HTTP servers,
## and should not be set on regular CPUs.
##
## Keep tls_cipher_suite undefined to let the app automatically choose secure parameters.

# tls_cipher_suite = [52392, 49199]


## Log TLS key material to a file, for debugging purposes only.
## This file will contain the TLS master key, which can be used to decrypt
## all TLS traffic to/from DoH servers.
## Never ever enable except for debugging purposes with a tool such as mitmproxy.

# tls_key_log_file = '/tmp/keylog.txt'


###############################################################################
#                            Startup & Network                                 #
###############################################################################

## Bootstrap resolvers
##
## These are normal, non-encrypted DNS resolvers, that will be only used
## for one-shot queries when retrieving the initial resolvers list and if
## the system DNS configuration doesn't work.
##
## No user queries will ever be leaked through these resolvers, and they will
## not be used after IP addresses of DoH resolvers have been found (if you are
## using DoH).
##
## They will never be used if lists have already been cached, and if the stamps
## of the configured servers already include IP addresses (which is the case for
## most of DoH servers, and for all DNSCrypt servers and relays).
##
## They will not be used if the configured system DNS works, or after the
## proxy already has at least one usable secure resolver.
##
## Resolvers supporting DNSSEC are recommended, and, if you are using
## DoH, bootstrap resolvers should ideally be operated by a different entity
## than the DoH servers you will be using, especially if you have IPv6 enabled.
##
## People in China may want to use 114.114.114.114:53 here.
## Other popular options include 8.8.8.8, 9.9.9.9 and 1.1.1.1.
##
## If more than one resolver is specified, they will be tried in sequence.
##
## TL;DR: put valid standard resolver addresses here. Your actual queries will
## not be sent there. If you're using DNSCrypt or Anonymized DNS and your
## lists are up to date, these resolvers will not even be used.

bootstrap_resolvers = __BOOTSTRAP_RESOLVERS__


## When internal DNS resolution is required, for example to retrieve
## the resolvers list:
##
## - queries will be sent to dnscrypt-proxy itself, if it is already
##   running with active servers (*)
## - or else, queries will be sent to fallback servers
## - finally, if `ignore_system_dns` is `false`, queries will be sent
##   to the system DNS
##
## (*) this is incompatible with systemd sockets.
## `listen_addresses` must not be empty.

ignore_system_dns = true


## Maximum time (in seconds) to wait for network connectivity before
## initializing the proxy.
## Useful if the proxy is automatically started at boot, and network
## connectivity is not guaranteed to be immediately available.
## Use 0 to not test for connectivity at all (not recommended),
## and -1 to wait as much as possible.

netprobe_timeout = 60

## Address and port to try initializing a connection to, just to check
## if the network is up. It can be any address and any port, even if
## there is nothing answering these on the other side. Just don't use
## a local address, as the goal is to check for Internet connectivity.
## On Windows, a datagram with a single, nul byte will be sent, only
## when the system starts.
## On other operating systems, the connection will be initialized
## but nothing will be sent at all.

netprobe_address = '9.9.9.9:53'


## Offline mode - Do not use any remote encrypted servers.
## The proxy will remain fully functional to respond to queries that
## plugins can handle directly (forwarding, cloaking, ...)

# offline_mode = false


## Additional data to attach to outgoing queries.
## These strings will be added as TXT records to queries.
## Do not use, except on servers explicitly asking for extra data
## to be present.
## encrypted-dns-server can be configured to use this for access control
## in the [access_control] section

# query_meta = ['key1:value1', 'key2:value2', 'token:MySecretToken']


###############################################################################
#                                 Filters                                      #
###############################################################################

## Note: if you are using dnsmasq, disable the `dnssec` option in dnsmasq if you
## configure dnscrypt-proxy to do any kind of filtering (including the filters
## below and blocklists).
## You can still choose resolvers that do DNSSEC validation.


## Immediately respond to IPv6-related queries with an empty response
## This makes things faster when there is no IPv6 connectivity, but can
## also cause reliability issues with some stub resolvers.

block_ipv6 = __BLOCK_IPV6__


## Immediately respond to A and AAAA queries for host names without a domain name
## This also prevents "dotless domain names" from being resolved upstream.

block_unqualified = true


## Immediately respond to queries for local zones instead of leaking them to
## upstream resolvers (always causing errors or timeouts).

block_undelegated = true


## TTL for synthetic responses sent when a request has been blocked (due to
## IPv6 or blocklists).

reject_ttl = 10


###############################################################################
#                              Forwarding                                      #
###############################################################################

## Route queries for specific domains to a dedicated set of servers

## See the `example-forwarding-rules.txt` file for an example

# forwarding_rules = 'forwarding-rules.txt'


###############################################################################
#                              Cloaking                                        #
###############################################################################

## Cloaking returns a predefined address for a specific name.
## In addition to acting as a HOSTS file, it can also return the IP address
## of a different name. It will also do CNAME flattening.
## If 'cloak_ptr' is set, then PTR (reverse lookups) are enabled
## for cloaking rules that do not contain wild cards.
##
## See the `example-cloaking-rules.txt` file for an example

# cloaking_rules = 'cloaking-rules.txt'

## TTL used when serving entries in cloaking-rules.txt

# cloak_ttl = 600
# cloak_ptr = false


###############################################################################
#                                DNS Cache                                     #
###############################################################################

## Enable a DNS cache to reduce latency and outgoing traffic

cache = true


## Cache size

cache_size = 4096


## Minimum TTL for cached entries

cache_min_ttl = 60


## Maximum TTL for cached entries

cache_max_ttl = 86400


## Minimum TTL for negatively cached entries

cache_neg_min_ttl = 60


## Maximum TTL for negatively cached entries

cache_neg_max_ttl = 600


###############################################################################
#                           Captive portal handling                            #
###############################################################################

[captive_portals]

## A file that contains a set of names used by operating systems to
## check for connectivity and captive portals, along with hard-coded
## IP addresses to return.

# map_file = 'example-captive-portals.txt'


###############################################################################
#                            Local DoH server                                  #
###############################################################################

[local_doh]

## dnscrypt-proxy can act as a local DoH server. By doing so, web browsers
## requiring a direct connection to a DoH server in order to enable some
## features will enable these, without bypassing your DNS proxy.

## Addresses that the local DoH server should listen to

# listen_addresses = ['127.0.0.1:3000']


## Path of the DoH URL. This is not a file, but the part after the hostname
## in the URL. By convention, `/dns-query` is frequently chosen.
## For each `listen_address` the complete URL to access the server will be:
## `https://<listen_address><path>` (ex: `https://127.0.0.1/dns-query`)

# path = '/dns-query'


## Certificate file and key - Note that the certificate has to be trusted.
## Can be generated using the following command:
## openssl req -x509 -nodes -newkey rsa:2048 -days 5000 -sha256 -keyout localhost.pem -out localhost.pem
## See the documentation (wiki) for more information.

# cert_file = 'localhost.pem'
# cert_key_file = 'localhost.pem'


###############################################################################
#                              Query logging                                   #
###############################################################################

[query_log]

## Path to the query log file (absolute, or relative to the same directory as the config file)
## Can be set to /dev/stdout in order to log to the standard output.

# file = 'query.log'


## Query log format (currently supported: tsv and ltsv)

format = 'tsv'


## Do not log these query types, to reduce verbosity. Keep empty to log everything.

# ignored_qtypes = ['DNSKEY', 'NS']


###############################################################################
#                        Suspicious queries logging                            #
###############################################################################

[nx_log]

## Log queries for nonexistent zones
## These queries can reveal the presence of malware, broken/obsolete applications,
## and devices signaling their presence to 3rd parties.

## Path to the query log file (absolute, or relative to the same directory as the config file)

# file = 'nx.log'


## Query log format (currently supported: tsv and ltsv)

format = 'tsv'


###############################################################################
#                    Pattern-based blocking (blocklists)                       #
###############################################################################

## Blocklists are made of one pattern per line. Example of valid patterns:
##
##   example.com
##   =example.com
##   *sex*
##   ads.*
##   ads*.example.*
##   ads*.example[0-9]*.com
##
## Example blocklist files can be found at https://download.dnscrypt.info/blocklists/
## A script to build blocklists from public feeds can be found in the
## `utils/generate-domains-blocklists` directory of the dnscrypt-proxy source code.

[blocked_names]

## Path to the file of blocking rules (absolute, or relative to the same directory as the config file)

# blocked_names_file = 'blocked-names.txt'


## Optional path to a file logging blocked queries

# log_file = 'blocked-names.log'


## Optional log format: tsv or ltsv (default: tsv)

# log_format = 'tsv'


###############################################################################
#                  Pattern-based IP blocking (IP blocklists)                   #
###############################################################################

## IP blocklists are made of one pattern per line. Example of valid patterns:
##
##   127.*
##   fe80:abcd:*
##   192.168.1.4

[blocked_ips]

## Path to the file of blocking rules (absolute, or relative to the same directory as the config file)

# blocked_ips_file = 'blocked-ips.txt'


## Optional path to a file logging blocked queries

# log_file = 'blocked-ips.log'


## Optional log format: tsv or ltsv (default: tsv)

# log_format = 'tsv'


###############################################################################
#                 Pattern-based allow lists (blocklists bypass)                #
###############################################################################

## Allowlists support the same patterns as blocklists
## If a name matches an allowlist entry, the corresponding session
## will bypass names and IP filters.
##
## Time-based rules are also supported to make some websites only accessible at specific times of the day.

[allowed_names]

## Path to the file of allow list rules (absolute, or relative to the same directory as the config file)

# allowed_names_file = 'allowed-names.txt'


## Optional path to a file logging allowed queries

# log_file = 'allowed-names.log'


## Optional log format: tsv or ltsv (default: tsv)

# log_format = 'tsv'


###############################################################################
#           Pattern-based allowed IPs lists (blocklists bypass)                #
###############################################################################

## Allowed IP lists support the same patterns as IP blocklists
## If an IP response matches an allowed entry, the corresponding session
## will bypass IP filters.
##
## Time-based rules are also supported to make some websites only accessible at specific times of the day.

[allowed_ips]

## Path to the file of allowed ip rules (absolute, or relative to the same directory as the config file)

# allowed_ips_file = 'allowed-ips.txt'


## Optional path to a file logging allowed queries

# log_file = 'allowed-ips.log'

## Optional log format: tsv or ltsv (default: tsv)

# log_format = 'tsv'


###############################################################################
#                        Time access restrictions                              #
###############################################################################

## One or more weekly schedules can be defined here.
## Patterns in the name-based blocked_names file can optionally be followed with @schedule_name
## to apply the pattern 'schedule_name' only when it matches a time range of that schedule.
##
## For example, the following rule in a blocklist file:
## *.youtube.* @time-to-sleep
## would block access to YouTube during the times defined by the 'time-to-sleep' schedule.
##
## {after='21:00', before= '7:00'} matches 0:00-7:00 and 21:00-0:00
## {after= '9:00', before='18:00'} matches 9:00-18:00

[schedules]

# [schedules.time-to-sleep]
#   mon = [{after='21:00', before='7:00'}]
#   tue = [{after='21:00', before='7:00'}]
#   wed = [{after='21:00', before='7:00'}]
#   thu = [{after='21:00', before='7:00'}]
#   fri = [{after='23:00', before='7:00'}]
#   sat = [{after='23:00', before='7:00'}]
#   sun = [{after='21:00', before='7:00'}]

# [schedules.work]
#   mon = [{after='9:00', before='18:00'}]
#   tue = [{after='9:00', before='18:00'}]
#   wed = [{after='9:00', before='18:00'}]
#   thu = [{after='9:00', before='18:00'}]
#   fri = [{after='9:00', before='17:00'}]


###############################################################################
#                                Servers                                       #
###############################################################################

## Remote lists of available servers
## Multiple sources can be used simultaneously, but every source
## requires a dedicated cache file.
##
## Refer to the documentation for URLs of public sources.
##
## A prefix can be prepended to server names in order to
## avoid collisions if different sources share the same for
## different servers. In that case, names listed in `server_names`
## must include the prefixes.
##
## If the `urls` property is missing, cache files and valid signatures
## must already be present. This doesn't prevent these cache files from
## expiring after `refresh_delay` hours.
## `refreshed_delay` must be in the [24..168] interval.
## The minimum delay of 24 hours (1 day) avoids unnecessary requests to servers.
## The maximum delay of 168 hours (1 week) ensures cache freshness.

[sources]

### An example of a remote source from https://github.com/DNSCrypt/dnscrypt-resolvers

[sources.public-resolvers]
urls = [
  'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
  'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
]
cache_file = 'public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

### Anonymized DNS relays (disabled by default — enable only with anonymized_dns.routes)
# [sources.relays]
# urls = [
#   'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',
#   'https://download.dnscrypt.info/resolvers-list/v3/relays.md',
# ]
# cache_file = 'relays.md'
# minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
# refresh_delay = 73
# prefix = ''

### ODoH (Oblivious DoH) servers and relays

# [sources.odoh-servers]
#   urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-servers.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-servers.md']
#   cache_file = 'odoh-servers.md'
#   minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
#   refresh_delay = 73
#   prefix = ''
# [sources.odoh-relays]
#   urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/odoh-relays.md', 'https://download.dnscrypt.info/resolvers-list/v3/odoh-relays.md']
#   cache_file = 'odoh-relays.md'
#   minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
#   refresh_delay = 73
#   prefix = ''

### Quad9

# [sources.quad9-resolvers]
#   urls = ['https://quad9.net/dnscrypt/quad9-resolvers.md', 'https://raw.githubusercontent.com/Quad9DNS/dnscrypt-settings/main/dnscrypt/quad9-resolvers.md']
#   minisign_key = 'RWQBphd2+f6eiAqBsvDZEBXBGHQBJfeG6G+wJPPKxCZMoEQYpmoysKUN'
#   cache_file = 'quad9-resolvers.md'
#   prefix = 'quad9-'

### Another example source, with resolvers censoring some websites not appropriate for children
### This is a subset of the `public-resolvers` list, so enabling both is useless.

# [sources.parental-control]
#   urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/parental-control.md', 'https://download.dnscrypt.info/resolvers-list/v3/parental-control.md']
#   cache_file = 'parental-control.md'
#   minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'

### dnscry.pt servers - See https://www.dnscry.pt

#  [sources.dnscry-pt-resolvers]
#    urls = ["https://www.dnscry.pt/resolvers.md"]
#    minisign_key = "RWQM31Nwkqh01x88SvrBL8djp1NH56Rb4mKLHz16K7qsXgEomnDv6ziQ"
#    cache_file = "dnscry.pt-resolvers.md"
#    refresh_delay = 73
#    prefix = "dnscry.pt-"


###############################################################################
#                        Servers with known bugs                               #
###############################################################################

[broken_implementations]

## Cisco servers currently cannot handle queries larger than 1472 bytes, and don't
## truncate responses larger than questions as expected by the DNSCrypt protocol.
## This prevents large responses from being received over UDP and over relays.
##
## Older versions of the `dnsdist` server software had a bug with queries larger
## than 1500 bytes. This is fixed since `dnsdist` version 1.5.0, but
## some server may still run an outdated version.
##
## The list below enables workarounds to make non-relayed usage more reliable
## until the servers are fixed.

fragments_blocked = [
  'cisco',
  'cisco-ipv6',
  'cisco-familyshield',
  'cisco-familyshield-ipv6',
  'cisco-sandbox',
  'cleanbrowsing-adult',
  'cleanbrowsing-adult-ipv6',
  'cleanbrowsing-family',
  'cleanbrowsing-family-ipv6',
  'cleanbrowsing-security',
  'cleanbrowsing-security-ipv6',
]


###############################################################################
#                Certificate-based client authentication for DoH               #
###############################################################################

[doh_client_x509_auth]

## Use an X509 certificate to authenticate yourself when connecting to DoH servers.
## This is only useful if you are operating your own, private DoH server(s).
## 'creds' maps servers to certificates, and supports multiple entries.
## If you are not using the standard root CA, an optional "root_ca"
## property set to the path to a root CRT file can be added to a server entry.

# creds = [
#    { server_name='*', client_cert='client.crt', client_key='client.key' }
# ]


###############################################################################
#                          Anonymized DNS                                      #
###############################################################################

[anonymized_dns]

## Routes are indirect ways to reach DNSCrypt servers.
##
## A route maps a server name ("server_name") to one or more relays that will be
## used to connect to that server.
##
## A relay can be specified as a DNS Stamp (either a relay stamp, or a
## DNSCrypt stamp) or a server name.
##
## The following example routes "example-server-1" via `anon-example-1` or `anon-example-2`,
## and "example-server-2" via the relay whose relay DNS stamp is
## "sdns://gRIxMzcuNzQuMjIzLjIzNDo0NDM".
##
## !!! THESE ARE JUST EXAMPLES !!!
##
## Review the list of available relays from the "relays.md" file, and, for each
## server you want to use, define the relays you want connections to go through.
##
## Carefully choose relays and servers so that they are run by different entities.
##
## "server_name" can also be set to "*" to define a default route, for all servers:
## { server_name='*', via=['anon-example-1', 'anon-example-2'] }
##
## If a route is ["*"], the proxy automatically picks a relay on a distinct network.
## { server_name='*', via=['*'] } is also an option, but is likely to be suboptimal.
##
## Manual selection is always recommended over automatic selection, so that you can
## select (relay,server) pairs that work well and fit your own criteria (close by or
## in different countries, operated by different entities, on distinct ISPs...)

# routes = [
#    { server_name='example-server-1', via=['anon-example-1', 'anon-example-2'] },
#    { server_name='example-server-2', via=['sdns://gRIxMzcuNzQuMjIzLjIzNDo0NDM'] }
# ]


## Skip resolvers incompatible with anonymization instead of using them directly

skip_incompatible = false


## If public server certificates for a non-conformant server cannot be
## retrieved via a relay, try getting them directly. Actual queries
## will then always go through relays.

# direct_cert_fallback = false


###############################################################################
#                                 DNS64                                        #
###############################################################################

[dns64]

## DNS64 is a mechanism for synthesizing AAAA records from A records.
## It is used with an IPv6/IPv4 translator to enable client-server
## communication between an IPv6-only client and an IPv4-only server,
## without requiring any changes to either the IPv6 or the IPv4 node,
## for the class of applications that work through NATs.
##
## There are two options to synthesize such records:
## Option 1: Using a set of static IPv6 prefixes;
## Option 2: By discovering the IPv6 prefix from DNS64-enabled resolver.
##
## If both options are configured - only static prefixes are used.
## (Ref. RFC6147, RFC6052, RFC7050)
##
## Do not enable unless you know what DNS64 is and why you need it, or else
## you won't be able to connect to anything at all.

## Static prefix(es) as Pref64::/n CIDRs

# prefix = ['64:ff9b::/96']

## DNS64-enabled resolver(s) to discover Pref64::/n CIDRs
## These resolvers are used to query for Well-Known IPv4-only Name (WKN) "ipv4only.arpa." to discover only.
## Set with your ISP's resolvers in case of custom prefixes (other than Well-Known Prefix 64:ff9b::/96).
## IMPORTANT: Default resolvers listed below support Well-Known Prefix 64:ff9b::/96 only.

# resolver = ['[2606:4700:4700::64]:53', '[2001:4860:4860::64]:53']


###############################################################################
#                           IP Encryption                                      #
###############################################################################

[ip_encryption]

## Encrypt client IP addresses in plugin logs using IPCrypt
## This provides privacy for client IP addresses while maintaining
## the ability to distinguish between different clients in logs

## Encryption algorithm (default: "none")
## - "none": No encryption (default)
## - "ipcrypt-deterministic": Deterministic encryption (same IP always encrypts to same value) - requires 16-byte key
## - "ipcrypt-nd": Non-deterministic encryption with 8-byte tweak - requires 16-byte key
## - "ipcrypt-ndx": Non-deterministic encryption with 16-byte tweak (extended) - requires 32-byte key

algorithm = "none"

## Encryption key in hexadecimal format (required if algorithm is not "none")
## Key size depends on algorithm:
## - ipcrypt-deterministic: 32 hex chars (16 bytes) - Generate with: openssl rand -hex 16
## - ipcrypt-nd: 32 hex chars (16 bytes) - Generate with: openssl rand -hex 16
## - ipcrypt-ndx: 64 hex chars (32 bytes) - Generate with: openssl rand -hex 32
## Example for deterministic/nd: key = "1234567890abcdef1234567890abcdef"
## Example for ndx: key = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
## IMPORTANT: Keep this key secret

key = ""


###############################################################################
#                            Monitoring UI                                     #
###############################################################################

[monitoring_ui]

## Enable the monitoring UI
enabled = false

## Listen address for the monitoring UI
listen_address = "127.0.0.1:8080"

## Optional username and password for basic authentication
## To disable authentication, set username to an empty string: username = ""
## If both username and password are empty, no authentication is required
username = ""
password = ""

## Optional TLS certificate and key for HTTPS
## If both are empty, HTTP will be used
tls_certificate = ""
tls_key = ""

## Enable query logging in the monitoring UI
## This will show recent queries in the UI
enable_query_log = true

## Privacy level for the monitoring UI
## 0: show all details including client IPs
## 1: anonymize client IPs (default)
## 2: aggregate data only (no individual queries or domains shown)
privacy_level = 1

## Maximum number of recent query log entries to keep in memory
## Helps control memory usage on high-traffic servers
## Default: 100
# max_query_log_entries = 100

## Maximum memory usage in MB for recent query logs
## Automatic cleanup when limit is exceeded
## Default: 1
# max_memory_mb = 1

## Enable Prometheus metrics endpoint
## Default: false
# prometheus_enabled = false

## Path for Prometheus metrics endpoint
## Default: /metrics
# prometheus_path = "/metrics"


###############################################################################
#                            Static entries                                    #
###############################################################################

[static]

## Optional, local, static list of additional servers
## Mostly useful for testing your own servers.

# [static.myserver]
#   stamp = 'sdns://AQcAAAAAAAAAAAAQMi5kbnNjcnlwdC1jZXJ0Lg'

EOF

	sed -i \
		-e "s|__LISTEN_ADDRESSES__|${DNSCRYPT_LISTEN_ADDRESSES}|g" \
		-e "s|__IPV4_SERVERS__|${DNSCRYPT_IPV4_SERVERS}|g" \
		-e "s|__IPV6_SERVERS__|${DNSCRYPT_IPV6_SERVERS}|g" \
		-e "s|__BLOCK_IPV6__|${DNSCRYPT_BLOCK_IPV6}|g" \
		-e "s|__BOOTSTRAP_RESOLVERS__|${DNSCRYPT_BOOTSTRAP_RESOLVERS}|g" \
		-e "s|__SERVER_NAMES__|${DNSCRYPT_SERVER_NAMES}|g" \
		"$DNSCRYPT_CONFIG_FILE"

	if grep -qE '__LISTEN_ADDRESSES__|__IPV4_SERVERS__|__IPV6_SERVERS__|__BLOCK_IPV6__|__BOOTSTRAP_RESOLVERS__|__SERVER_NAMES__' "$DNSCRYPT_CONFIG_FILE"; then
		die "Failed to apply IPv4/IPv6 placeholders in $DNSCRYPT_CONFIG_FILE"
	fi
}

dnscrypt_configure_resolved() {
	local resolv="$DNSCRYPT_RESOLV_CONF"
	printf '[+] Freeing port 53 from systemd-resolved stub listener\n'
	mkdir -p -- "$DNSCRYPT_RESOLVED_DROPIN_DIR"
	cat >"$DNSCRYPT_RESOLVED_DROPIN" <<EOF
[Resolve]
${DNSCRYPT_RESOLVED_DNS_LINE}
FallbackDNS=
Domains=~.
DNSStubListener=no
EOF

	chattr -i "$resolv" 2>/dev/null || true
	rm -f -- "$resolv"
	printf '%s\n' "$DNSCRYPT_TEMP_RESOLV_CONF_CONTENT" >"$resolv"

	if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
		systemctl restart systemd-resolved || true
	fi
}

dnscrypt_port53_foreign_holder() {
	local pattern="$1"
	local line
	line="$(ss -ulnp 2>/dev/null | grep -E "$pattern" || true)"
	[[ -z "$line" ]] && return 1
	if printf '%s\n' "$line" | grep -q 'dnscrypt-proxy'; then
		return 1
	fi
	printf '%s\n' "$line"
	return 0
}

dnscrypt_check_port53() {
	local foreign=""
	if ! command -v ss >/dev/null 2>&1; then
		return 0
	fi
	if ((DNSCRYPT_HAS_IPV4 == 1)) && foreign="$(dnscrypt_port53_foreign_holder '127\.0\.0\.1:53\s')"; then
		die "127.0.0.1:53 is in use by another process: $foreign"
	fi
	if ((DNSCRYPT_HAS_IPV6 == 1)) && foreign="$(dnscrypt_port53_foreign_holder '\[::1\]:53\s|::1:53\s')"; then
		die "[::1]:53 is in use by another process: $foreign"
	fi
}

dnscrypt_write_unit() {
	printf '[+] Creating systemd service\n'
	cat >"$DNSCRYPT_SERVICE_FILE" <<EOF
[Unit]
Description=DNSCrypt client proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${DNSCRYPT_INSTALL_DIR}
ExecStart=${DNSCRYPT_INSTALL_DIR}/dnscrypt-proxy -config ${DNSCRYPT_CONFIG_FILE}
ExecStartPre=${DNSCRYPT_INSTALL_DIR}/dnscrypt-proxy -check -config ${DNSCRYPT_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=${DNSCRYPT_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

dnscrypt_lock_resolv() {
	local resolv="$DNSCRYPT_RESOLV_CONF"
	printf '[+] Locking resolv.conf\n'
	chattr -i "$resolv" 2>/dev/null || true
	rm -f -- "$resolv"
	printf '%s\n' "$DNSCRYPT_RESOLV_CONF_CONTENT" >"$resolv"
	chattr +i "$resolv"
}

dnscrypt_wait_ready() {
	local ready_dig_target ready=0 _
	printf '[+] Enabling and starting dnscrypt-proxy\n'
	run_cmd dnscrypt.service.enable systemctl enable dnscrypt-proxy
	run_cmd dnscrypt.service.restart systemctl restart dnscrypt-proxy
	printf '    service: %s, enabled=%s, mode=%s\n' \
		"$(systemctl is-active dnscrypt-proxy 2>/dev/null || echo unknown)" \
		"$(systemctl is-enabled dnscrypt-proxy 2>/dev/null || echo unknown)" \
		"$DNSCRYPT_MODE"

	for _ in $(seq 1 30); do
		if systemctl is-active --quiet dnscrypt-proxy; then
			break
		fi
		sleep 1
	done

	if ! systemctl is-active --quiet dnscrypt-proxy; then
		systemctl --no-pager --full status dnscrypt-proxy || true
		journalctl -u dnscrypt-proxy -n 50 --no-pager || true
		die "dnscrypt-proxy failed to start"
	fi

	if ((DNSCRYPT_HAS_IPV4 == 1)); then
		ready_dig_target="127.0.0.1"
	else
		ready_dig_target="::1"
	fi

	printf '[+] Waiting for local DNS to become ready (@%s)\n' "$ready_dig_target"
	for _ in $(seq 1 30); do
		if dig +time=2 +tries=1 +short example.com "@$ready_dig_target" >/dev/null 2>&1; then
			ready=1
			break
		fi
		sleep 1
	done
	if ((ready != 1)); then
		journalctl -u dnscrypt-proxy -n 50 --no-pager || true
		die "dnscrypt-proxy is running but not answering on ${ready_dig_target}:53"
	fi
}

dnscrypt_print_summary() {
	printf '[+] Testing\n'
	systemctl --no-pager --full status dnscrypt-proxy || true

	printf '\n[+] External connectivity used for config\n'
	[[ -n "$DNSCRYPT_PUBLIC_IPV4" ]] && printf '  IPv4: %s\n' "$DNSCRYPT_PUBLIC_IPV4" || printf '  IPv4: (none)\n'
	[[ -n "$DNSCRYPT_PUBLIC_IPV6" ]] && printf '  IPv6: %s\n' "$DNSCRYPT_PUBLIC_IPV6" || printf '  IPv6: (none)\n'

	printf '\n[+] Applied DNS settings\n'
	grep -E '^(server_names|listen_addresses|ipv4_servers|ipv6_servers|require_dnssec|block_ipv6|bootstrap_resolvers|lb_strategy|lb_estimator|use_syslog)[[:space:]]*=' "$DNSCRYPT_CONFIG_FILE" || true

	if ((DNSCRYPT_HAS_IPV4 == 1)); then
		printf '\n[+] DIG test (direct @127.0.0.1)\n'
		dig +time=5 +tries=2 google.com @127.0.0.1 || true
	fi
	if ((DNSCRYPT_HAS_IPV6 == 1)); then
		printf '\n[+] DIG test (direct @::1)\n'
		dig +time=5 +tries=2 google.com @::1 || true
	fi

	printf '\n[+] DIG test (system resolver)\n'
	dig +time=5 +tries=2 google.com || true

	printf '\n[+] Current DNS\n'
	ls -la "$DNSCRYPT_RESOLV_CONF" || true
	cat "$DNSCRYPT_RESOLV_CONF" || true

	printf '\n[+] Install directory contents\n'
	ls -la "$DNSCRYPT_INSTALL_DIR" || true

	printf '\n[+] Listening on :53\n'
	ss -ulnp | grep -E ':53\s' || true

	printf '\n[+] Done. dnscrypt-proxy %s is installed and set as system DNS.\n' "$DNSCRYPT_VERSION"
}

dnscrypt_run_install() {
	DNSCRYPT_SKIP_HEALTHY=0
	dnscrypt_detect_arch

	# Match vendor: deps first (curl needed for GitHub latest), then resolve version.
	printf '[+] Installing dependencies\n'
	run_cmd dnscrypt.deps apt-get update
	run_cmd dnscrypt.deps.install env DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar dnsutils

	dnscrypt_resolve_version
	dnscrypt_detect_existing

	printf '[+] Checking for existing installation\n'
	if ((DNSCRYPT_EXISTING_BINARY == 1 || DNSCRYPT_EXISTING_UNIT == 1 || DNSCRYPT_EXISTING_ACTIVE == 1)); then
		printf '    binary:  %s (%s/dnscrypt-proxy%s)\n' \
			"$DNSCRYPT_EXISTING_BINARY" "$DNSCRYPT_INSTALL_DIR" \
			"${DNSCRYPT_INSTALLED_VERSION:+ version $DNSCRYPT_INSTALLED_VERSION}"
		printf '    unit:    %s (%s)\n' "$DNSCRYPT_EXISTING_UNIT" "$DNSCRYPT_SERVICE_FILE"
		printf '    active:  %s\n' "$DNSCRYPT_EXISTING_ACTIVE"
		printf '    enabled: %s\n' "$DNSCRYPT_EXISTING_ENABLED"
	else
		printf '    none found\n'
	fi

	dnscrypt_decide_mode

	if ((DNSCRYPT_SKIP_HEALTHY == 1)); then
		printf '[+] Keeping existing binary: %s\n' "${DNSCRYPT_INSTALLED_VERSION}"
		printf '[+] Done. dnscrypt-proxy %s is already installed and set as system DNS.\n' "$DNSCRYPT_VERSION"
		return 0
	fi

	case "$DNSCRYPT_MODE" in
	install)
		dnscrypt_switch_to_public_dns
		dnscrypt_remove_distro_bits
		systemctl stop dnscrypt-proxy 2>/dev/null || true
		systemctl disable dnscrypt-proxy 2>/dev/null || true
		rm -f -- "$DNSCRYPT_SERVICE_FILE"
		pkill -x dnscrypt-proxy 2>/dev/null || true
		systemctl daemon-reload || true
		dnscrypt_install_binary
		;;
	upgrade)
		dnscrypt_remove_distro_bits
		dnscrypt_install_binary
		;;
	reconfigure)
		printf '[+] Keeping existing binary: %s\n' "$("$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" -version 2>/dev/null || true)"
		dnscrypt_remove_distro_bits
		rm -f -- \
			"$DNSCRYPT_INSTALL_DIR"/example-* \
			"$DNSCRYPT_INSTALL_DIR/localhost.pem" \
			"$DNSCRYPT_INSTALL_DIR/LICENSE"
		;;
	*)
		die "dnscrypt: unknown mode $DNSCRYPT_MODE"
		;;
	esac

	"$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" -version

	dnscrypt_detect_connectivity
	dnscrypt_write_config
	dnscrypt_configure_resolved
	dnscrypt_check_port53
	dnscrypt_write_unit

	printf '[+] Reloading systemd\n'
	systemctl daemon-reload

	printf '[+] Validating configuration\n'
	"$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy" -check -config "$DNSCRYPT_CONFIG_FILE"

	dnscrypt_wait_ready
	dnscrypt_lock_resolv
	dnscrypt_print_summary
}

install_dnscrypt_command() {
	require_opt_in --apply "$@"
	require_apply_confirmation "$@"
	dnscrypt_parse_args "$@" || return $?

	if [[ "$INSTALL_MOCK" == "1" ]]; then
		local mode_label="install" resolved_version="${DNSCRYPT_VERSION:-latest}"
		if ((DNSCRYPT_FORCE_REINSTALL == 1)); then
			mode_label="install --force"
		elif ((DNSCRYPT_RECONFIGURE_ONLY == 1)); then
			mode_label="reconfigure"
		fi
		run_cmd dnscrypt.deps apt-get install -y curl tar dnsutils
		if [[ -n "$DNSCRYPT_VERSION" ]]; then
			DNSCRYPT_VERSION="${DNSCRYPT_VERSION#v}"
			resolved_version="$DNSCRYPT_VERSION"
			run_cmd dnscrypt.resolve.pinned printf 'pinned %s\n' "$DNSCRYPT_VERSION"
		else
			resolved_version="2.1.18"
			DNSCRYPT_VERSION="$resolved_version"
			run_cmd dnscrypt.resolve.latest curl -fsSL "$DNSCRYPT_GITHUB_API_LATEST"
		fi
		run_cmd dnscrypt.mode "$mode_label" "$resolved_version"
		if ((DNSCRYPT_RECONFIGURE_ONLY == 0)); then
			run_cmd dnscrypt.download fetch "dnscrypt-proxy-${resolved_version}"
		fi
		run_cmd dnscrypt.config write "$DNSCRYPT_CONFIG_FILE"
		run_cmd dnscrypt.unit write "$DNSCRYPT_SERVICE_FILE"
		run_cmd dnscrypt.resolved write "$DNSCRYPT_RESOLVED_DROPIN"
		run_cmd dnscrypt.service.enable systemctl enable dnscrypt-proxy
		run_cmd dnscrypt.service.restart systemctl restart dnscrypt-proxy
		run_cmd dnscrypt.dig dig +time=2 +tries=1 +short example.com @127.0.0.1
		printf 'DNSCrypt mock install completed (mode=%s version=%s)\n' "$mode_label" "$resolved_version"
		return 0
	fi

	dnscrypt_run_install
	if ((DNSCRYPT_SKIP_HEALTHY == 1)); then
		printf 'DNSCrypt already installed as system DNS (DoH/DNSCrypt on localhost:53)\n'
	else
		printf 'DNSCrypt installed as system DNS (DoH/DNSCrypt on localhost:53)\n'
	fi
}

install_doctor_check_dnscrypt() {
	local status=0
	local binary="$DNSCRYPT_INSTALL_DIR/dnscrypt-proxy"
	local resolv_file=${INSTALL_TEST_RESOLV_CONF:-$DNSCRYPT_RESOLV_CONF}
	local module_file="$SCRIPT_DIR/modules/04_dnscrypt.sh"
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		if [[ -f "$module_file" ]] && declare -F install_dnscrypt_command >/dev/null 2>&1; then
			doctor_ok_detail "dnscrypt module: $module_file"
		else
			doctor_fail "dnscrypt module missing or incomplete: $module_file" || status=1
		fi
		run_cmd doctor.dnscrypt.binary test -x "$binary" || true
		run_cmd doctor.dnscrypt.service systemctl is-active dnscrypt-proxy || true
		((status == 0)) && doctor_ok "dnscrypt: module present (runtime checks skipped in mock)"
		return "$status"
	fi
	if [[ -x "$binary" ]]; then
		local version
		version=$("$binary" -version 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
		doctor_ok "dnscrypt binary: $binary${version:+ ($version)}"
		if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
			doctor_ok "dnscrypt-proxy service is active"
		else
			doctor_warn "dnscrypt-proxy service is not active"
			status=1
		fi
		if systemctl is-enabled --quiet dnscrypt-proxy 2>/dev/null; then
			doctor_ok_detail "dnscrypt-proxy service is enabled"
		else
			doctor_warn "dnscrypt-proxy service is not enabled"
		fi
		if [[ -r "$resolv_file" ]] && grep -Eq 'nameserver[[:space:]]+(127\.0\.0\.1|::1)([[:space:]]|$)' "$resolv_file"; then
			doctor_ok "resolv.conf points to localhost DNS"
		else
			doctor_warn "resolv.conf does not clearly point to 127.0.0.1/::1"
			status=1
		fi
		if command -v dig >/dev/null 2>&1; then
			if dig +time=2 +tries=1 +short example.com @127.0.0.1 >/dev/null 2>&1; then
				doctor_ok_detail "dig @127.0.0.1 succeeded"
			else
				doctor_warn "dig @127.0.0.1 failed"
				status=1
			fi
		fi
	else
		doctor_warn "dnscrypt binary missing: $binary (run: install.sh run dnscrypt --apply --yes)"
	fi
	return "$status"
}

uninstall_purge_dnscrypt() {
	local resolv_file=${INSTALL_TEST_RESOLV_CONF:-$DNSCRYPT_RESOLV_CONF}
	if [[ "$INSTALL_MOCK" == "1" ]]; then
		run_cmd dnscrypt.purge.chattr chattr -i "$resolv_file"
		run_cmd dnscrypt.purge.stop systemctl stop dnscrypt-proxy
		run_cmd dnscrypt.purge.disable systemctl disable dnscrypt-proxy
		run_cmd dnscrypt.purge.unit rm -f "$DNSCRYPT_SERVICE_FILE"
		run_cmd dnscrypt.purge.dropin rm -f "$DNSCRYPT_RESOLVED_DROPIN"
		run_cmd dnscrypt.purge.resolv bash -c "printf '%s\\n' 'nameserver 9.9.9.9' 'nameserver 1.1.1.1' 'options edns0' >'$resolv_file'"
		run_cmd dnscrypt.purge.dir rm -rf "$DNSCRYPT_INSTALL_DIR"
		run_cmd dnscrypt.purge.reload systemctl daemon-reload
		return 0
	fi
	run_cmd dnscrypt.purge.chattr chattr -i "$resolv_file" || true
	run_cmd dnscrypt.purge.stop systemctl stop dnscrypt-proxy || true
	run_cmd dnscrypt.purge.disable systemctl disable dnscrypt-proxy || true
	run_cmd dnscrypt.purge.unit rm -f -- "$DNSCRYPT_SERVICE_FILE"
	run_cmd dnscrypt.purge.dropin rm -f -- "$DNSCRYPT_RESOLVED_DROPIN"
	run_cmd dnscrypt.purge.resolv bash -c "printf '%s\\n' 'nameserver 9.9.9.9' 'nameserver 1.1.1.1' 'nameserver 2620:fe::fe' 'nameserver 2606:4700:4700::1111' 'options edns0' >'$resolv_file'"
	run_cmd dnscrypt.purge.dir rm -rf -- "$DNSCRYPT_INSTALL_DIR"
	run_cmd dnscrypt.purge.reload systemctl daemon-reload || true
	if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
		run_cmd dnscrypt.purge.resolved systemctl restart systemd-resolved || true
	fi
}
