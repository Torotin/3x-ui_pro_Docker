#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPTS_DIR="$ROOT_DIR/docker-proxy/3x-ui/scripts"

# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/log.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/json_state.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/desired_state.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/env.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/http.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/3xui_api.bash"

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

test_redaction_masks_secrets() {
	local redacted
	redacted=$(redact_secrets 'password=secret privateKey=abc token=tok-secret Cookie: sid=123')
	[[ "$redacted" != *secret* ]] || fail "password was not redacted"
	[[ "$redacted" != *abc* ]] || fail "privateKey was not redacted"
	[[ "$redacted" != *tok-secret* ]] || fail "token was not redacted"
	[[ "$redacted" != *sid=123* ]] || fail "cookie was not redacted"
}

test_upsert_outbound_by_tag_is_idempotent() {
	local base first second count protocol
	base=$(cat "$ROOT_DIR/tests/3x-ui-scripts/fixtures/xray-base.json")
	first=$(json_upsert_outbound_by_tag "$base" '{"tag":"warp-docker","protocol":"socks","settings":{"servers":[{"address":"warp","port":1080}]}}')
	second=$(json_upsert_outbound_by_tag "$first" '{"tag":"warp-docker","protocol":"socks","settings":{"servers":[{"address":"warp","port":1080}]}}')
	count=$(printf '%s' "$second" | jq '[.xraySetting.outbounds[] | select(.tag=="warp-docker")] | length')
	protocol=$(printf '%s' "$second" | jq -r '.xraySetting.outbounds[] | select(.tag=="warp-docker") | .protocol')
	assert_eq 1 "$count" "outbound was duplicated"
	assert_eq socks "$protocol" "outbound protocol mismatch"
}

test_dns_replace_preserves_unknown_fields() {
	local base updated host server_count
	base=$(cat "$ROOT_DIR/tests/3x-ui-scripts/fixtures/xray-base.json")
	updated=$(json_replace_dns_servers "$base" '[{"address":"adguard","port":53,"skipFallback":false}]')
	host=$(printf '%s' "$updated" | jq -r '.xraySetting.dns.hosts["example.local"]')
	server_count=$(printf '%s' "$updated" | jq '.xraySetting.dns.servers | length')
	assert_eq 127.0.0.1 "$host" "dns hosts were not preserved"
	assert_eq 1 "$server_count" "dns server count mismatch"
}

test_remove_managed_xray_artifacts_only_removes_our_tags() {
	local input cleaned managed_count direct_count
	input='{"xraySetting":{"outbounds":[{"tag":"direct"},{"tag":"warp-docker"},{"tag":"tor-proxy"}],"routing":{"rules":[{"outboundTag":"tor-proxy"},{"balancerTag":"warp-balancer"},{"outboundTag":"blocked"}],"balancers":[{"tag":"warp-balancer"},{"tag":"custom"}]}}}'
	cleaned=$(json_remove_managed_xray_artifacts "$input")
	managed_count=$(printf '%s' "$cleaned" | jq '[.. | objects | select((.tag? // .outboundTag? // .balancerTag? // "") as $t | $t == "warp-docker" or $t == "tor-proxy" or $t == "warp-balancer")] | length')
	direct_count=$(printf '%s' "$cleaned" | jq '[.xraySetting.outbounds[]? | select(.tag=="direct")] | length')
	assert_eq 0 "$managed_count" "managed artifacts were not removed"
	assert_eq 1 "$direct_count" "unmanaged outbound was removed"
}

test_desired_clients_are_deterministic() {
	local desired vision_email xhttp_email vision_sub xhttp_sub
	export CLIENT_EMAIL_PREFIX=autogen
	export CLIENT_SUB_ID=stable-sub
	desired=$(build_desired_state)
	vision_email=$(printf '%s' "$desired" | jq -r '.clients.vision.email')
	xhttp_email=$(printf '%s' "$desired" | jq -r '.clients.xhttp.email')
	vision_sub=$(printf '%s' "$desired" | jq -r '.clients.vision.subId')
	xhttp_sub=$(printf '%s' "$desired" | jq -r '.clients.xhttp.subId')
	assert_eq autogen-vision "$vision_email" "vision email default mismatch"
	assert_eq autogen-xhttp "$xhttp_email" "xhttp email default mismatch"
	assert_eq stable-sub "$vision_sub" "vision sub id mismatch"
	assert_eq stable-sub "$xhttp_sub" "xhttp sub id mismatch"
}

test_desired_inbound_remarks_use_country_flag() {
	local desired vision_remark xhttp_remark
	export EMOJI_FLAG="🇩🇪"
	desired=$(build_desired_state)
	vision_remark=$(printf '%s' "$desired" | jq -r '.inbounds.vision.remark')
	xhttp_remark=$(printf '%s' "$desired" | jq -r '.inbounds.xhttp.remark')
	assert_eq "🇩🇪 vless-tcp-reality" "$vision_remark" "vision inbound remark must use the detected country flag"
	assert_eq "🇩🇪 vless-xhttp" "$xhttp_remark" "xhttp inbound remark must use the detected country flag"
	unset EMOJI_FLAG
}

test_managed_inbound_remarks_include_legacy_names() {
	local desired remarks has_new has_legacy
	export EMOJI_FLAG="🇩🇪"
	desired=$(build_desired_state)
	remarks=$(managed_inbound_remarks_json vision "$desired")
	has_new=$(printf '%s' "$remarks" | jq -r 'index("🇩🇪 vless-tcp-reality") != null')
	has_legacy=$(printf '%s' "$remarks" | jq -r 'index("managed:vless-tcp-reality") != null')
	assert_eq true "$has_new" "managed remarks must include the desired flag-based name"
	assert_eq true "$has_legacy" "managed remarks must include the legacy managed name for migration"
	unset EMOJI_FLAG
}

test_country_flag_sources_include_iso_code_fallbacks() {
	local sources first_source source_count has_ipapi has_country_is has_cloudflare_ip
	sources=$(country_flag_sources)
	first_source=$(printf '%s\n' "$sources" | sed '/^$/d' | head -n1)
	source_count=$(printf '%s\n' "$sources" | sed '/^$/d' | wc -l | tr -d ' ')
	has_ipapi=$(printf '%s\n' "$sources" | grep -Fc "https://ipapi.co/json/")
	has_country_is=$(printf '%s\n' "$sources" | grep -Fc "https://api.country.is/")
	has_cloudflare_ip=$(printf '%s\n' "$sources" | grep -Fc "http://1.1.1.1/cdn-cgi/trace")
	[[ "$source_count" -ge 6 ]] || fail "country flag detection must try at least six providers"
	assert_eq "http://1.1.1.1/cdn-cgi/trace||trace_loc" "$first_source" "DNS-free Cloudflare trace must be the primary country flag source"
	assert_eq 1 "$has_ipapi" "country flag detection must include ipapi.co fallback"
	assert_eq 1 "$has_country_is" "country flag detection must include country.is fallback"
	assert_eq 1 "$has_cloudflare_ip" "country flag detection must include a DNS-free Cloudflare trace fallback"
}

test_country_code_to_flag_converts_iso_alpha2() {
	local flag
	flag=$(country_code_to_flag de)
	assert_eq "🇩🇪" "$flag" "country code fallback must convert ISO alpha-2 to flag emoji"
}

test_country_flag_value_from_trace_extracts_loc() {
	local flag
	flag=$(country_flag_value trace_loc $'fl=1\nloc=DE\nwarp=off')
	assert_eq "🇩🇪" "$flag" "Cloudflare trace fallback must convert loc to flag emoji"
}

test_resolve_panel_base_prioritizes_configured_web_port() {
	local first_base
	export USERNAME=admin PASSWORD=admin NEW_ADMIN_USERNAME='' NEW_ADMIN_PASSWORD=''
	export webPort=52025 webBasePath=/panel WEBDOMAIN=example.test
	HTTP_ATTEMPTS=4
	HTTP_LOG_FAILURES=1
	# shellcheck disable=SC2034 # resolve_panel_base reads/restores these globals dynamically
	HTTP_CONNECT_TIMEOUT=2
	# shellcheck disable=SC2034 # resolve_panel_base reads/restores these globals dynamically
	HTTP_MAX_TIME=8
	xui_login() {
		printf '%s\n' "$1" >>"$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
		return 1
	}
	rm -f "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
	resolve_panel_base || true
	first_base=$(head -n1 "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts")
	rm -f "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
	assert_eq "https://127.0.0.1:52025/panel" "$first_base" "configured webPort was not tried first"
	assert_eq 4 "$HTTP_ATTEMPTS" "HTTP_ATTEMPTS was not restored"
	assert_eq 1 "$HTTP_LOG_FAILURES" "HTTP_LOG_FAILURES was not restored"
}

test_normalize_base_path_accepts_empty_input() {
	local result
	result=$(normalize_base_path "")
	assert_eq "" "$result" "empty base path must normalize to empty string"
	normalize_base_path "" >/dev/null || fail "empty base path must return success"
}

test_http_request_temp_files_are_created_under_tmp_root() {
	local tmp_root body
	tmp_root=$(mktemp -d)
	# shellcheck disable=SC2034 # http_request reads TMP_ROOT as a runtime global
	TMP_ROOT=$tmp_root
	# shellcheck disable=SC2034 # http_init/http_request read COOKIE_JAR as a runtime global
	COOKIE_JAR="$tmp_root/cookies.txt"
	http_init "$tmp_root"
	curl() {
		local out=
		while (($# > 0)); do
			case "$1" in
			-o)
				out=$2
				shift 2
				;;
			-w)
				shift 2
				;;
			*)
				shift
				;;
			esac
		done
		printf '{"success":true}' >"$out"
		printf '200'
	}
	http_request GET "http://127.0.0.1/test" || fail "http_request fixture failed"
	body=$HTTP_BODY_FILE
	case "$body" in
	"$tmp_root"/*) ;;
	*) fail "HTTP_BODY_FILE must be created under TMP_ROOT, got $body" ;;
	esac
	http_body | jq -e '.success == true' >/dev/null || fail "http_body must read successful response"
	rm -rf "$tmp_root"
	unset -f curl
	unset TMP_ROOT COOKIE_JAR
}

test_panel_api_requests_use_bearer_token_when_configured() {
	local call_log auth_count path_count settings_auth_count
	call_log=$(mktemp)
	export XUI_API_TOKEN=test-token
	# shellcheck disable=SC2034 # xui_url reads URL_BASE_RESOLVED as a runtime global
	URL_BASE_RESOLVED=http://127.0.0.1:2053/panel
	http_request() {
		printf '%s\n' "$*" >>"$call_log"
		return 0
	}
	xui_list_inbounds
	xui_add_inbound --data-urlencode "remark=test"
	xui_restart_xray
	xui_get_panel_settings
	auth_count=$(grep -Fc "Authorization: Bearer test-token" "$call_log")
	path_count=$(grep -Fc "panel/api/inbounds" "$call_log")
	grep -Fq "panel/api/server/restartXrayService" "$call_log" || fail "Xray restart must use the panel API server route"
	settings_auth_count=$(grep -F "panel/setting/all" "$call_log" | grep -Fc "Authorization: Bearer test-token" || true)
	rm -f "$call_log"
	unset -f http_request
	unset XUI_API_TOKEN
	assert_eq 3 "$auth_count" "Bearer token must be sent on panel API requests"
	assert_eq 2 "$path_count" "inbound API requests were not captured"
	assert_eq 0 "$settings_auth_count" "Bearer token must not be sent on non-/panel/api routes"
}

test_panel_api_requests_read_bearer_token_from_sqlite_when_env_is_empty() {
	local call_log auth_count
	call_log=$(mktemp)
	XUI_API_TOKEN=
	# shellcheck disable=SC2034 # xui_url reads URL_BASE_RESOLVED as a runtime global
	URL_BASE_RESOLVED=http://127.0.0.1:2053
	sqlite3() {
		[[ "$1" == "/etc/x-ui/x-ui.db" ]] || fail "unexpected sqlite database path: $1"
		[[ "$2" == "select value from settings where key='secret';" ]] || fail "unexpected sqlite query: $2"
		printf '%s\n' db-token
	}
	http_request() {
		printf '%s\n' "$*" >>"$call_log"
		return 0
	}
	xui_list_inbounds
	auth_count=$(grep -Fc "Authorization: Bearer db-token" "$call_log")
	rm -f "$call_log"
	unset -f http_request sqlite3
	unset XUI_API_TOKEN
	assert_eq 1 "$auth_count" "Bearer token must fall back to the SQLite secret setting"
}

test_xui_login_replays_csrf_token() {
	local call_log login_has_csrf
	call_log=$(mktemp)
	unset -f xui_login
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/3xui_api.bash"
	http_request() {
		printf '%s\n' "$*" >>"$call_log"
		case "$2" in
		*/csrf-token)
			# shellcheck disable=SC2034 # xui_csrf_token reads HTTP_CODE as shared HTTP state
			HTTP_CODE=200
			HTTP_BODY_FILE=$(mktemp)
			printf '{"success":true,"obj":"csrf-fixture"}' >"$HTTP_BODY_FILE"
			;;
		*/login)
			# shellcheck disable=SC2034 # http_success_json reads HTTP_CODE as shared HTTP state
			HTTP_CODE=200
			HTTP_BODY_FILE=$(mktemp)
			printf '{"success":true}' >"$HTTP_BODY_FILE"
			;;
		esac
		return 0
	}
	xui_login "http://127.0.0.1:25713/panel-base" admin admin || fail "xui_login fixture failed"
	login_has_csrf=$(grep -F "/login" "$call_log" | grep -Fc "X-CSRF-Token: csrf-fixture" || true)
	rm -f "$call_log" "${HTTP_BODY_FILE:-}"
	unset -f http_request
	assert_eq 1 "$login_has_csrf" "login POST must include the minted CSRF token"
}

test_non_bearer_api_post_replays_csrf_token() {
	local call_log settings_has_csrf
	call_log=$(mktemp)
	unset XUI_API_TOKEN XUI_API_TOKEN_RESOLVED
	# shellcheck disable=SC2034 # xui_url reads URL_BASE_RESOLVED as a runtime global
	URL_BASE_RESOLVED=http://127.0.0.1:25713/panel-base
	http_request() {
		printf '%s\n' "$*" >>"$call_log"
		case "$2" in
		*/csrf-token)
			# shellcheck disable=SC2034 # xui_csrf_token reads HTTP_CODE as shared HTTP state
			HTTP_CODE=200
			HTTP_BODY_FILE=$(mktemp)
			printf '{"success":true,"obj":"csrf-fixture"}' >"$HTTP_BODY_FILE"
			;;
		*/panel/setting/all)
			# shellcheck disable=SC2034 # http_success_json reads HTTP_CODE as shared HTTP state
			HTTP_CODE=200
			HTTP_BODY_FILE=$(mktemp)
			printf '{"success":true,"obj":{}}' >"$HTTP_BODY_FILE"
			;;
		esac
		return 0
	}
	xui_get_panel_settings || fail "xui_get_panel_settings fixture failed"
	settings_has_csrf=$(grep -F "/panel/setting/all" "$call_log" | grep -Fc "X-CSRF-Token: csrf-fixture" || true)
	rm -f "$call_log" "${HTTP_BODY_FILE:-}"
	unset -f http_request
	assert_eq 1 "$settings_has_csrf" "non-Bearer POST requests must include a CSRF token"
}

test_custom_geo_resources_default_to_previous_dat_files() {
	local resources count site_type site_alias ip_type ip_alias
	unset CUSTOM_GEO_RESOURCES
	resources=$(custom_geo_resources_json)
	count=$(printf '%s' "$resources" | jq 'length')
	site_type=$(printf '%s' "$resources" | jq -r '.[0].type')
	site_alias=$(printf '%s' "$resources" | jq -r '.[0].alias')
	ip_type=$(printf '%s' "$resources" | jq -r '.[1].type')
	ip_alias=$(printf '%s' "$resources" | jq -r '.[1].alias')
	assert_eq 2 "$count" "default custom geo resource count mismatch"
	assert_eq geosite "$site_type" "default geosite type mismatch"
	assert_eq zxc-rv-adlist "$site_alias" "default geosite alias mismatch"
	assert_eq geoip "$ip_type" "default geoip type mismatch"
	assert_eq zkeenip "$ip_alias" "default geoip alias mismatch"
}

test_custom_geo_resources_parse_custom_entries() {
	local resources count url
	export CUSTOM_GEO_RESOURCES=$'geosite|ads|https://example.test/ads.dat\n# comment\ngeoip|corp|https://example.test/ip.dat'
	resources=$(custom_geo_resources_json)
	count=$(printf '%s' "$resources" | jq 'length')
	url=$(printf '%s' "$resources" | jq -r '.[1].url')
	assert_eq 2 "$count" "custom geo parser resource count mismatch"
	assert_eq https://example.test/ip.dat "$url" "custom geo parser URL mismatch"
}

test_panel_keys_restore_old_cert_fields() {
	local keys
	keys=$(desired_panel_keys)
	grep -qx webCertFile <<<"$keys" || fail "webCertFile is missing from desired panel keys"
	grep -qx webKeyFile <<<"$keys" || fail "webKeyFile is missing from desired panel keys"
	grep -qx subClashEnable <<<"$keys" || fail "subClashEnable is missing from desired panel keys"
	grep -qx subSupportUrl <<<"$keys" || fail "subSupportUrl is missing from desired panel keys"
	grep -qx ldapEnable <<<"$keys" || fail "ldapEnable is missing from desired panel keys"
}

test_warp_domains_restore_old_ru_rules() {
	local domains has_gov has_yandex has_webdomain
	domains=$(json_warp_managed_domains screenhub.linkpc.net)
	has_gov=$(printf '%s' "$domains" | jq 'index("ext:geosite_RU.dat:category-gov-ru") != null')
	has_yandex=$(printf '%s' "$domains" | jq 'index("ext:geosite_RU.dat:yandex") != null')
	has_webdomain=$(printf '%s' "$domains" | jq 'index("domain:screenhub.linkpc.net") != null')
	assert_eq true "$has_gov" "old WARP gov RU rule was not restored"
	assert_eq true "$has_yandex" "old WARP yandex rule was not restored"
	assert_eq true "$has_webdomain" "web domain was not included in WARP routing domains"
}

test_managed_xray_restores_warp_tor_dns_without_missing_balancer_refs() {
	local base dns updated selector_count tor_port dns_first burst_destination
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"blocked","protocol":"blackhole","settings":{}}],"routing":{"rules":[]},"dns":{"hosts":{"example.local":"127.0.0.1"}}}}'
	dns='[{"address":"adguard","port":53,"skipFallback":false}]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true true true true "screenhub.linkpc.net")
	selector_count=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector[] | select(.=="warp-docker")] | length')
	tor_port=$(printf '%s' "$updated" | jq -r '.xraySetting.outbounds[] | select(.tag=="tor-proxy") | .settings.servers[0].port')
	dns_first=$(printf '%s' "$updated" | jq -r '.xraySetting.dns.servers[0].address')
	burst_destination=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.pingConfig.destination')
	assert_eq 1 "$selector_count" "WARP balancer does not reference available warp-docker"
	assert_eq 1080 "$tor_port" "TOR outbound must use current tor-proxy:1080 endpoint"
	assert_eq adguard "$dns_first" "DNS servers were not restored"
	assert_eq https://connectivitycheck.gstatic.com/generate_204 "$burst_destination" "burstObservatory ping destination mismatch"
}

test_xhttp_stream_uses_minimal_context_headers_and_sockopt() {
	local stream headers server content_type connection cache_control access_origin access_methods access_headers tproxy force_tls
	stream=$(build_xhttp_stream_json /xhttp screenhub.linkpc.net)
	headers=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers')
	server=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers.Server')
	content_type=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers["Content-Type"]')
	connection=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers.Connection')
	cache_control=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers["Cache-Control"]')
	access_origin=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers["Access-Control-Allow-Origin"]')
	access_methods=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers["Access-Control-Allow-Methods"]')
	access_headers=$(printf '%s' "$stream" | jq -r '.xhttpSettings.headers["Access-Control-Allow-Headers"]')
	tproxy=$(printf '%s' "$stream" | jq -r '.sockopt.tproxy')
	force_tls=$(printf '%s' "$stream" | jq -r '.externalProxy[0].forceTls')
	assert_eq 3 "$(printf '%s' "$headers" | jq 'length')" "XHTTP headers should stay minimal"
	assert_eq null "$server" "XHTTP headers must not spoof nginx Server"
	assert_eq null "$content_type" "XHTTP headers must not force HTML content type"
	assert_eq null "$connection" "XHTTP headers must not force hop-by-hop Connection"
	assert_eq null "$access_headers" "XHTTP headers must not add unnecessary CORS request headers"
	assert_eq no-store "$cache_control" "XHTTP cache policy should match transport semantics"
	assert_eq "*" "$access_origin" "XHTTP CORS origin should match official transport guidance"
	assert_eq "GET, POST" "$access_methods" "XHTTP CORS methods should match official transport guidance"
	assert_eq tproxy "$tproxy" "old XHTTP sockopt tproxy was not restored"
	assert_eq tls "$force_tls" "XHTTP externalProxy must publish TLS subscription links through Traefik"
}

test_vision_stream_restores_old_reality_external_proxy() {
	local stream force_tls short_id_count
	stream=$(build_vision_stream_json traefik:4443 screenhub.linkpc.net private public '["aa","bb"]' '{}' '' '')
	force_tls=$(printf '%s' "$stream" | jq -r '.externalProxy[0].forceTls')
	short_id_count=$(printf '%s' "$stream" | jq '.realitySettings.shortIds | length')
	assert_eq same "$force_tls" "old Vision externalProxy forceTls was not restored"
	assert_eq 2 "$short_id_count" "Vision shortIds were not preserved"
}

test_vision_settings_include_traefik_fallback_preserving_clients() {
	local inbound settings fallback_dest clients decryption encryption
	export VISION_FALLBACK_HOST=traefik
	export VISION_FALLBACK_PORT=4443
	export VISION_FALLBACK_XVER=1
	inbound='{"settings":"{\"clients\":[{\"id\":\"client-id\",\"email\":\"a@example.test\"}],\"decryption\":\"none\",\"encryption\":\"none\"}"}'
	settings=$(build_vless_settings_json vision "$inbound")
	fallback_dest=$(printf '%s' "$settings" | jq -r '.fallbacks[0].dest')
	clients=$(printf '%s' "$settings" | jq '.clients | length')
	decryption=$(printf '%s' "$settings" | jq -r '.decryption')
	encryption=$(printf '%s' "$settings" | jq -r '.encryption')
	assert_eq traefik:4443 "$fallback_dest" "Vision fallback must point to Traefik websecure"
	assert_eq 1 "$clients" "Vision update must preserve existing clients"
	assert_eq none "$decryption" "Vision VLESS settings must keep decryption=none"
	assert_eq none "$encryption" "Vision VLESS settings must keep encryption=none for subscription outbounds"
}

test_tor_balancer_uses_two_available_hosts() {
	local base dns updated selector_count rule_balancer ports
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" false true false false "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080},{"tag":"torproxy","host":"torproxy","port":9050}]')
	selector_count=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="tor-balancer") | .selector[]] | length')
	rule_balancer=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[] | select(.balancerTag=="tor-balancer") | .balancerTag')
	ports=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="tor-proxy" or .tag=="torproxy") | "\(.tag):\(.settings.servers[0].port)"] | sort | join(",")')
	assert_eq 2 "$selector_count" "TOR balancer must include two selectors"
	assert_eq tor-balancer "$rule_balancer" "TOR routing must use balancerTag"
	assert_eq "tor-proxy:1080,torproxy:9050" "$ports" "TOR outbound endpoints mismatch"
}

test_warp_balancer_uses_docker_and_usque_without_console_warp() {
	local base dns updated selectors protocols usque_port burst_subjects observatory fallback
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true false false true "screenhub.linkpc.net" '[]')
	selectors=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector | sort | join(",")')
	protocols=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="warp" or .tag=="warp-docker" or .tag=="usque") | "\(.tag):\(.protocol)"] | sort | join(",")')
	usque_port=$(printf '%s' "$updated" | jq -r '.xraySetting.outbounds[] | select(.tag=="usque") | .settings.servers[0].port')
	burst_subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	observatory=$(printf '%s' "$updated" | jq -r '.xraySetting.observatory')
	fallback=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .fallbackTag')
	assert_eq "usque,warp-docker" "$selectors" "WARP balancer selectors mismatch"
	assert_eq "usque:socks,warp-docker:socks" "$protocols" "WARP outbound protocols mismatch"
	assert_eq 1080 "$usque_port" "usque outbound port mismatch"
	assert_eq "usque,warp-docker" "$burst_subjects" "WARP burstObservatory selectors mismatch"
	assert_eq null "$observatory" "legacy observatory must not be used with managed balancers"
	assert_eq blocked "$fallback" "WARP balancer fallbackTag mismatch"
}

test_warp_balancer_can_opt_in_console_warp() {
	local base dns updated selectors protocols burst_subjects warp_console
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	warp_console='{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"test","address":["172.16.0.2/32"],"peers":[{"publicKey":"peer","allowedIPs":["0.0.0.0/0"],"endpoint":"engage.cloudflareclient.com:2408"}]}}'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true false false true "screenhub.linkpc.net" '[]' "$warp_console")
	selectors=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector | sort | join(",")')
	protocols=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="warp" or .tag=="warp-docker" or .tag=="usque") | "\(.tag):\(.protocol)"] | sort | join(",")')
	burst_subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	assert_eq "usque,warp,warp-docker" "$selectors" "Console WARP opt-in selectors mismatch"
	assert_eq "usque:socks,warp-docker:socks,warp:wireguard" "$protocols" "Console WARP opt-in protocols mismatch"
	assert_eq "usque,warp,warp-docker" "$burst_subjects" "Console WARP opt-in burstObservatory selectors mismatch"
}

test_managed_burst_observatory_preserves_custom_subjects() {
	local base dns updated subjects custom_observatory
	base='{"xraySetting":{"outbounds":[],"routing":{"rules":[],"balancers":[]},"burstObservatory":{"subjectSelector":["custom-out"],"pingConfig":{"destination":"https://old.example/204"}}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$(json_remove_managed_xray_artifacts "$base")" "$dns" false true false false "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	custom_observatory=$(printf '%s' "$updated" | jq -r '.xraySetting.observatory')
	assert_eq "custom-out,tor-proxy" "$subjects" "custom burstObservatory subjects were not preserved"
	assert_eq null "$custom_observatory" "unexpected observatory object was created"
}

test_warp_outbound_from_registration_prefers_panel_host_endpoint() {
	local config outbound endpoint reserved
	config='{"client_id":"N1cA","peers":[{"public_key":"peer-pub","endpoint":{"v4":"162.159.192.10:0","host":"engage.cloudflareclient.com:2408"}}],"interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:8e67:a9a4:3ae0:2482:245b"}}}'
	outbound=$(warp_outbound_from_config "$config" "private-key" '[1,2,3]')
	endpoint=$(printf '%s' "$outbound" | jq -r '.settings.peers[0].endpoint')
	reserved=$(printf '%s' "$outbound" | jq -r '.settings.reserved | join(",")')
	assert_eq engage.cloudflareclient.com:2408 "$endpoint" "WARP registration endpoint must match panel GUI host endpoint"
	assert_eq 55,87,0 "$reserved" "WARP reserved bytes must be derived from panel client_id"
}

test_existing_warp_outbound_endpoint_is_normalized() {
	local outbound normalized endpoint
	outbound='{"tag":"warp","protocol":"wireguard","settings":{"peers":[{"endpoint":"162.159.192.5:2408"}]}}'
	normalized=$(normalize_warp_outbound_endpoint "$outbound")
	endpoint=$(printf '%s' "$normalized" | jq -r '.settings.peers[0].endpoint')
	assert_eq engage.cloudflareclient.com:2408 "$endpoint" "Existing WARP outbound endpoint was not normalized"
}

test_xray_api_inbound_uses_documented_dokodemo_protocol() {
	local protocol
	protocol=$(jq -r '.inbounds[] | select(.tag=="api") | .protocol' "$ROOT_DIR/docker-proxy/3x-ui/configs/config.json")
	assert_eq dokodemo-door "$protocol" "Xray API inbound must use documented dokodemo-door protocol"
}

test_lampac_hide_interface_waits_for_lampa_global() {
	local file="$ROOT_DIR/docker-proxy/lampac-docker/plugins/override/hide_interface.js"
	grep -Fq "function waitForLampa()" "$file" || fail "hide_interface must wait for window.Lampa"
	grep -Fq "typeof window.Lampa !== 'undefined'" "$file" || fail "hide_interface must check window.Lampa before init"
	if grep -Fq "if (typeof Lampa !== 'undefined')" "$file" || grep -Fq "Lampa.Listener.follow('app', function" "$file"; then
		fail "hide_interface must not access Lampa.Listener from the undefined-Lampa startup branch"
	fi
}

test_redaction_masks_secrets
test_upsert_outbound_by_tag_is_idempotent
test_dns_replace_preserves_unknown_fields
test_remove_managed_xray_artifacts_only_removes_our_tags
test_desired_clients_are_deterministic
test_desired_inbound_remarks_use_country_flag
test_managed_inbound_remarks_include_legacy_names
test_country_flag_sources_include_iso_code_fallbacks
test_country_code_to_flag_converts_iso_alpha2
test_country_flag_value_from_trace_extracts_loc
test_resolve_panel_base_prioritizes_configured_web_port
test_normalize_base_path_accepts_empty_input
test_http_request_temp_files_are_created_under_tmp_root
test_panel_api_requests_use_bearer_token_when_configured
test_panel_api_requests_read_bearer_token_from_sqlite_when_env_is_empty
test_xui_login_replays_csrf_token
test_non_bearer_api_post_replays_csrf_token
test_custom_geo_resources_default_to_previous_dat_files
test_custom_geo_resources_parse_custom_entries
test_panel_keys_restore_old_cert_fields
test_warp_domains_restore_old_ru_rules
test_managed_xray_restores_warp_tor_dns_without_missing_balancer_refs
test_xhttp_stream_uses_minimal_context_headers_and_sockopt
test_vision_stream_restores_old_reality_external_proxy
test_vision_settings_include_traefik_fallback_preserving_clients
test_tor_balancer_uses_two_available_hosts
test_warp_balancer_uses_docker_and_usque_without_console_warp
test_warp_balancer_can_opt_in_console_warp
test_managed_burst_observatory_preserves_custom_subjects
test_warp_outbound_from_registration_prefers_panel_host_endpoint
test_existing_warp_outbound_endpoint_is_normalized
test_xray_api_inbound_uses_documented_dokodemo_protocol
test_lampac_hide_interface_waits_for_lampa_global
printf 'test_libs.bash: OK\n'
