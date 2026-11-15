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
	local out='' transport=direct
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
	ENABLE_MIHOMO=true
	mapfile -t got_arr < <(download_default_transports)
	got=$(download_test_join "${got_arr[@]}")
	assert_eq "direct,socks5h://usque:1080,http://mihomo:7890,socks5h://tor-proxy:1080" "$got" "enabled mihomo must try direct then usque, mihomo and tor"
	unset ENABLE_MIHOMO
}

test_download_default_transports_honor_disabled_flags() {
	local got
	local -a got_arr
	# shellcheck disable=SC2034 # download_default_transports reads these globals.
	ENABLE_MIHOMO=false
	# shellcheck disable=SC2034 # download_default_transports reads these globals.
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
	# shellcheck disable=SC2034 # download_transport_candidates reads this global.
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	# shellcheck disable=SC2034 # download_transport_candidates reads this global.
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
	# shellcheck disable=SC2034 # download_with_fallbacks reads this global.
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	# shellcheck disable=SC2034 # download_with_fallbacks reads this global.
	DOWNLOAD_TRANSPORTS=direct
	# shellcheck disable=SC2034 # download_with_fallbacks reads this global.
	DOWNLOAD_URL_FALLBACKS="https://mirror.example/xray.zip"
	curl() {
		local out='' url=''
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

test_download_github_release_json_tries_proxy_after_direct() {
	local tmp got log
	tmp=$(mktemp -d)
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS="direct,socks5h://usque:1080"
	# Лог в файл: curl вызывается из $(...) subshell, массив родителя не обновляется.
	DOWNLOAD_TEST_CURL_LOG_FILE="$tmp/curl.log"
	: >"$DOWNLOAD_TEST_CURL_LOG_FILE"
	curl() {
		local url='' transport=direct
		while (($# > 0)); do
			case "$1" in
			-x)
				transport=$2
				shift 2
				;;
			--noproxy)
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
		printf '%s:%s\n' "$transport" "$url" >>"$DOWNLOAD_TEST_CURL_LOG_FILE"
		if [[ "$transport" == socks5h://usque:1080 ]]; then
			printf '%s' '{"assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/1","name":"geosite.dat"}]}'
			return 0
		fi
		return 22
	}
	got=$(download_github_asset_api_url 'https://github.com/o/r/releases/latest/download/geosite.dat')
	assert_eq 'https://api.github.com/repos/o/r/releases/assets/1' "$got" "API resolve must succeed via usque after direct fails"
	log=$(tr '\n' ' ' <"$DOWNLOAD_TEST_CURL_LOG_FILE")
	[[ "$log" == *'direct:https://api.github.com/repos/o/r/releases/latest'* ]] || fail "direct API resolve must be tried"
	[[ "$log" == *'socks5h://usque:1080:https://api.github.com/repos/o/r/releases/latest'* ]] || fail "usque API resolve must be tried"
	unset -f curl
	unset DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS DOWNLOAD_TEST_CURL_LOG_FILE
	rm -rf "$tmp"
}

test_download_github_mirror_candidates_are_listed() {
	local got
	local -a got_arr
	DOWNLOAD_GITHUB_MIRRORS=https://ghfast.top
	DOWNLOAD_GITHUB_MIRRORS_ENABLED=true
	DOWNLOAD_GITHUB_ASSET_API=false
	unset DOWNLOAD_URL_FALLBACKS
	curl() { return 22; }
	mapfile -t got_arr < <(download_url_candidates 'https://github.com/o/r/releases/latest/download/geosite.dat')
	got=$(download_test_join "${got_arr[@]}")
	assert_eq 'https://ghfast.top/https://github.com/o/r/releases/latest/download/geosite.dat,https://github.com/o/r/releases/latest/download/geosite.dat' "$got" "github mirror must precede browser URL"
	unset -f curl
	unset DOWNLOAD_GITHUB_MIRRORS DOWNLOAD_GITHUB_MIRRORS_ENABLED DOWNLOAD_GITHUB_ASSET_API
}

test_download_github_asset_api_is_preferred_over_release_url() {
	local tmp dest
	tmp=$(mktemp -d)
	dest="$tmp/geosite.dat"
	DOWNLOAD_TEST_CURL_LOG=()
	DOWNLOAD_TRANSPORT_CACHE="$tmp/cache"
	DOWNLOAD_TRANSPORTS=direct
	unset DOWNLOAD_URL_FALLBACKS
	DOWNLOAD_GITHUB_ASSET_API=true
	curl() {
		local out='' url='' accept=''
		while (($# > 0)); do
			case "$1" in
			-o)
				out=$2
				shift 2
				;;
			-H)
				[[ "$2" == Accept:* ]] && accept=$2
				shift 2
				;;
			--noproxy | -x | --connect-timeout | --max-time | --speed-limit | --speed-time)
				shift 2
				;;
			-fsSL)
				shift
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
		if [[ "$url" == https://api.github.com/repos/1andrevich/Re-filter-lists/releases/latest ]]; then
			printf '%s' '{"assets":[{"url":"https://api.github.com/repos/1andrevich/Re-filter-lists/releases/assets/42","name":"geosite.dat"}]}'
			return 0
		fi
		if [[ "$url" == https://api.github.com/repos/1andrevich/Re-filter-lists/releases/assets/42 ]]; then
			[[ "$accept" == 'Accept: application/octet-stream' ]] || return 22
			printf 'asset-payload' >"$out"
			return 0
		fi
		# browser/release URL must not be required for success
		return 22
	}
	download_file_atomic \
		"https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat" \
		"$dest" || fail "GitHub Assets API rewrite must succeed when release CDN returns 504"
	assert_eq asset-payload "$(cat "$dest")" "Assets API payload mismatch"
	[[ "${DOWNLOAD_TEST_CURL_LOG[*]}" == *'https://api.github.com/repos/1andrevich/Re-filter-lists/releases/assets/42'* ]] ||
		fail "Assets API download URL must be attempted"
	[[ "${DOWNLOAD_TEST_CURL_LOG[*]}" != *'https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat'* ]] ||
		fail "browser release URL must not be needed after Assets API success"
	unset -f curl
	unset DOWNLOAD_TRANSPORT_CACHE DOWNLOAD_TRANSPORTS DOWNLOAD_GITHUB_ASSET_API
	DOWNLOAD_TEST_CURL_LOG=()
	rm -rf "$tmp"
}

test_download_curl_headers_for_github_asset_api() {
	local got
	got=$(download_curl_headers_for_url 'https://api.github.com/repos/owner/repo/releases/assets/123' | tr '\n' ' ')
	[[ "$got" == *'Accept: application/octet-stream'* ]] || fail "Assets API must request octet-stream"
	got=$(download_curl_headers_for_url 'https://github.com/owner/repo/releases/latest/download/x.dat' || true)
	[[ -z "$got" ]] || fail "non-asset URLs must not get Assets API headers"
}

test_xray_update_keeps_existing_binary_on_download_failure() {
	local file="$SCRIPTS_DIR/00_BeforeStart/xray_update.sh"
	grep -Fq 'keeping existing binary' "$file" || fail "xray_update must keep an existing binary when download fails"
	grep -Fq 'Failed to download xray and no existing binary' "$file" || fail "xray_update must die only when no xray binary is present"
}

test_download_db_keeps_existing_on_failure() {
	local file="$SCRIPTS_DIR/00_BeforeStart/download-db.sh"
	grep -Fq 'Keeping existing' "$file" || fail "download-db must keep existing geodata when download fails"
	grep -Fq 'continuing without this geodata asset' "$file" || fail "download-db must continue when geodata is missing"
}

test_download_default_transports_include_stack_proxies
test_download_default_transports_honor_disabled_flags
test_download_transport_candidates_prefer_cache
test_download_file_atomic_falls_back_to_socks_proxy
test_download_file_atomic_skips_checksum_mismatch_and_retries
test_download_file_atomic_returns_failure_when_all_transports_fail
test_download_url_fallbacks_are_tried_after_primary
test_download_github_release_json_tries_proxy_after_direct
test_download_github_mirror_candidates_are_listed
test_download_github_asset_api_is_preferred_over_release_url
test_download_curl_headers_for_github_asset_api
test_xray_update_keeps_existing_binary_on_download_failure
test_download_db_keeps_existing_on_failure
printf 'test_download.bash: OK\n'
