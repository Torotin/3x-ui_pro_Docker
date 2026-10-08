#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS_DIR="$ROOT_DIR/docker-proxy/3x-ui/scripts"

# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/log.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/download.bash"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected=$1 actual=$2 message=$3
	if [[ "$expected" != "$actual" ]]; then
		fail "$message (expected '$expected', got '$actual')"
	fi
}

download_test_join() {
	local IFS=,
	printf '%s' "$*"
}

download_test_stub_curl() {
	local out= transport=direct
	while (($# > 0)); do
		case "$1" in
		-o)
			out=$2
			shift 2
			;;
		-x)
			transport=$2
			shift 2
			;;
		--noproxy)
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	DOWNLOAD_TEST_CURL_LOG+=("$transport")
	if [[ -n "${DOWNLOAD_TEST_FAIL_TRANSPORTS:-}" && "$DOWNLOAD_TEST_FAIL_TRANSPORTS" == *"|$transport|"* ]]; then
		return "${DOWNLOAD_TEST_CURL_RC:-28}"
	fi
	if [[ -n "${DOWNLOAD_TEST_BAD_CHECKSUM_TRANSPORT:-}" && "$transport" == "$DOWNLOAD_TEST_BAD_CHECKSUM_TRANSPORT" ]]; then
		printf 'bad-payload' >"$out"
		return 0
	fi
	printf '%s' "${DOWNLOAD_TEST_PAYLOAD:-ok}" >"$out"
	return 0
}

test_download_default_transports_include_stack_proxies() {
	local got
	local -a got_arr
	unset DOWNLOAD_TRANSPORTS ENABLE_MIHOMO XRAY_MANAGED_TOR USQUE_HOST USQUE_PORT MIHOMO_PROXY_HOST MIHOMO_PROXY_PORT TOR_PROXY_HOST TOR_PROXY_PORT
	mapfile -t got_arr < <(download_default_transports)
	got=$(download_test_join "${got_arr[@]}")
	assert_eq "direct,socks5h://usque:1080,http://mihomo:7890,socks5h://tor-proxy:1080" "$got" "default transports must try direct then usque, mihomo and tor"
}

test_download_default_transports_honor_disabled_flags() {
	local got
	local -a got_arr
	ENABLE_MIHOMO=false
	XRAY_MANAGED_TOR=false
	mapfile -t got_arr < <(download_default_transports)
	got=$(download_test_join "${got_arr[@]}")
	assert_eq "direct,socks5h://usque:1080" "$got" "disabled mihomo/tor flags must drop those transports"
	unset ENABLE_MIHOMO XRAY_MANAGED_TOR
}

test_download_transport_candidates_prefer_cache() {
	local tmp got
	local -a got_arr
	tmp=$(mktemp -d)
	printf 'http://mihomo:7890\n' >"$tmp/cache"
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS="direct,socks5h://usque:1080,http://mihomo:7890"
	mapfile -t got_arr < <(download_transport_candidates)
	got=$(download_test_join "${got_arr[@]}")
	assert_eq "http://mihomo:7890,direct,socks5h://usque:1080" "$got" "cached transport must be tried first"
	rm -rf "$tmp"
	unset DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS
}

test_download_file_atomic_falls_back_to_socks_proxy() {
	local tmp dest
	tmp=$(mktemp -d)
	dest="$tmp/out.bin"
	DOWNLOAD_TEST_CURL_LOG=()
	DOWNLOAD_TEST_FAIL_TRANSPORTS="|direct|"
	DOWNLOAD_TEST_PAYLOAD=from-usque
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS="direct,socks5h://usque:1080"
	curl() { download_test_stub_curl "$@"; }
	download_file_atomic "https://example.invalid/xray.zip" "$dest" || fail "fallback download must succeed via usque"
	assert_eq from-usque "$(cat "$dest")" "fallback payload must come from usque"
	assert_eq "direct,socks5h://usque:1080" "$(download_test_join "${DOWNLOAD_TEST_CURL_LOG[@]}")" "direct must be attempted before usque"
	assert_eq socks5h://usque:1080 "$(tr -d '\r\n' <"$tmp/cache")" "winning socks transport must be cached"
	unset -f curl
	unset DOWNLOAD_TEST_FAIL_TRANSPORTS DOWNLOAD_TEST_PAYLOAD DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS
	DOWNLOAD_TEST_CURL_LOG=()
	rm -rf "$tmp"
}

test_download_file_atomic_skips_checksum_mismatch_and_retries() {
	local tmp dest checksum
	tmp=$(mktemp -d)
	dest="$tmp/out.bin"
	checksum=$(printf 'ok' | sha256sum | awk '{print $1}')
	DOWNLOAD_TEST_CURL_LOG=()
	DOWNLOAD_TEST_FAIL_TRANSPORTS=""
	DOWNLOAD_TEST_BAD_CHECKSUM_TRANSPORT=direct
	DOWNLOAD_TEST_PAYLOAD=ok
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS="direct,socks5h://usque:1080"
	curl() { download_test_stub_curl "$@"; }
	download_file_atomic "https://example.invalid/xray.zip" "$dest" "$checksum" || fail "checksum mismatch must fall through to the next transport"
	assert_eq ok "$(cat "$dest")" "valid checksum payload must be installed"
	assert_eq socks5h://usque:1080 "$(tr -d '\r\n' <"$tmp/cache")" "checksum failure must not cache the bad transport"
	unset -f curl
	unset DOWNLOAD_TEST_BAD_CHECKSUM_TRANSPORT DOWNLOAD_TEST_PAYLOAD DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS
	DOWNLOAD_TEST_CURL_LOG=()
	rm -rf "$tmp"
}

test_download_file_atomic_returns_failure_when_all_transports_fail() {
	local tmp dest
	tmp=$(mktemp -d)
	dest="$tmp/out.bin"
	DOWNLOAD_TEST_FAIL_TRANSPORTS="|direct|socks5h://usque:1080|"
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS="direct,socks5h://usque:1080"
	curl() { download_test_stub_curl "$@"; }
	if download_file_atomic "https://example.invalid/xray.zip" "$dest"; then
		fail "download_file_atomic must return failure when every transport fails"
	fi
	[[ ! -e "$dest" ]] || fail "failed download must not replace the destination"
	unset -f curl
	unset DOWNLOAD_TEST_FAIL_TRANSPORTS DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS
	rm -rf "$tmp"
}

test_download_url_fallbacks_are_tried_after_primary() {
	local tmp dest
	tmp=$(mktemp -d)
	dest="$tmp/out.bin"
	DOWNLOAD_TEST_CURL_LOG=()
	DOWNLOAD_TEST_FAIL_TRANSPORTS="|direct|"
	DOWNLOAD_TEST_PAYLOAD=from-fallback-url
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS=direct
	DOWNLOAD_URL_FALLBACKS="https://mirror.example/xray.zip"
	curl() {
		local out= url=
		while (($# > 0)); do
			case "$1" in
			-o)
				out=$2
				shift 2
				;;
			--noproxy | -x)
				shift 2
				;;
			https://* | http://*)
				url=$1
				shift
				;;
			*)
				shift
				;;
			esac
		done
		DOWNLOAD_TEST_CURL_LOG+=("$url")
		if [[ "$url" == https://mirror.example/xray.zip ]]; then
			printf '%s' "$DOWNLOAD_TEST_PAYLOAD" >"$out"
			return 0
		fi
		return 28
	}
	download_file_atomic "https://github.example/xray.zip" "$dest" || fail "URL fallback must succeed after the primary URL fails"
	assert_eq from-fallback-url "$(cat "$dest")" "fallback URL payload mismatch"
	assert_eq "https://github.example/xray.zip,https://mirror.example/xray.zip" "$(download_test_join "${DOWNLOAD_TEST_CURL_LOG[@]}")" "primary URL must be tried before fallbacks"
	unset -f curl
	unset DOWNLOAD_TEST_FAIL_TRANSPORTS DOWNLOAD_TEST_PAYLOAD DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS DOWNLOAD_URL_FALLBACKS
	DOWNLOAD_TEST_CURL_LOG=()
	rm -rf "$tmp"
}

test_xray_update_keeps_existing_binary_on_download_failure() {
	local file="$SCRIPTS_DIR/00_BeforeStart/xray_update.sh"
	grep -Fq 'keeping existing binary' "$file" || fail "xray_update must keep an existing binary when download fails"
	grep -Fq 'Failed to download xray and no existing binary' "$file" || fail "xray_update must die only when no xray binary is present"
}

test_download_default_transports_include_stack_proxies
test_download_default_transports_honor_disabled_flags
test_download_transport_candidates_prefer_cache
test_download_file_atomic_falls_back_to_socks_proxy
test_download_file_atomic_skips_checksum_mismatch_and_retries
test_download_file_atomic_returns_failure_when_all_transports_fail
test_download_url_fallbacks_are_tried_after_primary
test_xray_update_keeps_existing_binary_on_download_failure
printf 'test_download.bash: OK\n'
