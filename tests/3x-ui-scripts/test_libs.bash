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
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/runtime_common.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/panel_runtime.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/inbound_runtime.bash"
# shellcheck source=/dev/null
. "$SCRIPTS_DIR/lib/xray_runtime.bash"

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
	first=$(json_upsert_outbound_by_tag "$base" '{"tag":"usque","protocol":"socks","settings":{"servers":[{"address":"usque","port":1080}]}}')
	second=$(json_upsert_outbound_by_tag "$first" '{"tag":"usque","protocol":"socks","settings":{"servers":[{"address":"usque","port":1080}]}}')
	count=$(printf '%s' "$second" | jq '[.xraySetting.outbounds[] | select(.tag=="usque")] | length')
	protocol=$(printf '%s' "$second" | jq -r '.xraySetting.outbounds[] | select(.tag=="usque") | .protocol')
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
	local input cleaned managed_count direct_count custom_count custom_subjects
	input='{"xraySetting":{"outbounds":[{"tag":"direct"},{"tag":"warp-retired"},{"tag":"tor-proxy"},{"tag":"warp-custom"},{"tag":"tor-custom"}],"routing":{"rules":[{"outboundTag":"tor-proxy"},{"balancerTag":"warp-balancer"},{"outboundTag":"blocked"},{"balancerTag":"custom-balancer"}],"balancers":[{"tag":"warp-balancer"},{"tag":"custom"},{"tag":"warp-custom-balancer"},{"tag":"tor-custom-balancer"}]},"burstObservatory":{"subjectSelector":["warp-custom","tor-custom","custom-out","usque"]}}}'
	cleaned=$(json_remove_managed_xray_artifacts "$input")
	managed_count=$(printf '%s' "$cleaned" | jq '[.. | objects | select((.tag? // .outboundTag? // .balancerTag? // "") as $t | $t == "warp-retired" or $t == "tor-proxy" or $t == "warp-balancer")] | length')
	direct_count=$(printf '%s' "$cleaned" | jq '[.xraySetting.outbounds[]? | select(.tag=="direct")] | length')
	custom_count=$(printf '%s' "$cleaned" | jq '[.. | objects | select((.tag? // .outboundTag? // .balancerTag? // "") as $t | $t == "warp-custom" or $t == "tor-custom" or $t == "custom-balancer" or $t == "custom" or $t == "warp-custom-balancer" or $t == "tor-custom-balancer")] | length')
	custom_subjects=$(printf '%s' "$cleaned" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	assert_eq 0 "$managed_count" "managed artifacts were not removed"
	assert_eq 1 "$direct_count" "unmanaged outbound was removed"
	assert_eq 6 "$custom_count" "unmanaged routing artifacts must be preserved"
	assert_eq "custom-out,tor-custom,warp-custom" "$custom_subjects" "unmanaged observatory subjects must be preserved"
}

test_desired_clients_are_deterministic() {
	local desired shared_email shared_sub shared_flow vision_flow xhttp_flow grpc_flow
	export CLIENT_EMAIL_PREFIX=autogen
	export CLIENT_SUB_ID=stable-sub
	desired=$(build_desired_state)
	shared_email=$(printf '%s' "$desired" | jq -r '.clients.shared.email')
	shared_sub=$(printf '%s' "$desired" | jq -r '.clients.shared.subId')
	shared_flow=$(printf '%s' "$desired" | jq -r '.clients.shared.flow')
	vision_flow=$(printf '%s' "$desired" | jq -r '.clients.shared.visionFlow')
	xhttp_flow=$(printf '%s' "$desired" | jq -r '.clients.shared.xhttpFlow')
	grpc_flow=$(printf '%s' "$desired" | jq -r '.clients.shared.grpcFlow')
	assert_eq autogen "$shared_email" "shared client email default mismatch"
	assert_eq stable-sub "$shared_sub" "shared client sub id mismatch"
	assert_eq "" "$shared_flow" "shared first-class client flow must stay empty"
	assert_eq "xtls-rprx-vision" "$vision_flow" "Vision inbound client flow mismatch"
	assert_eq "" "$xhttp_flow" "XHTTP VLESS client flow must stay empty"
	assert_eq "" "$grpc_flow" "gRPC VLESS client flow must stay empty"
}

test_desired_inbound_remarks_use_country_flag() {
	local desired vision_remark xhttp_remark grpc_remark hysteria2_remark
	export EMOJI_FLAG="🇩🇪"
	desired=$(build_desired_state)
	vision_remark=$(printf '%s' "$desired" | jq -r '.inbounds.vision.remark')
	xhttp_remark=$(printf '%s' "$desired" | jq -r '.inbounds.xhttp.remark')
	grpc_remark=$(printf '%s' "$desired" | jq -r '.inbounds.grpc.remark')
	hysteria2_remark=$(printf '%s' "$desired" | jq -r '.inbounds.hysteria2.remark')
	assert_eq "🇩🇪 vless-tcp-reality" "$vision_remark" "vision inbound remark must use the detected country flag"
	assert_eq "🇩🇪 vless-xhttp" "$xhttp_remark" "xhttp inbound remark must use the detected country flag"
	assert_eq "🇩🇪 vless-grpc-tls" "$grpc_remark" "gRPC inbound remark must use the detected country flag"
	assert_eq "🇩🇪 hysteria2" "$hysteria2_remark" "Hysteria2 inbound remark must use the detected country flag"
	unset EMOJI_FLAG
}

test_runtime_env_preserves_explicit_optional_inbound_flags() {
	local tmp old_pwd
	tmp=$(mktemp -d)
	old_pwd=$PWD
	mkdir -p "$tmp/runtime" "$tmp/3x-ui"
	printf 'ENABLE_VLESS_GRPC=true\nENABLE_HYSTERIA2=false\n' >"$tmp/.env"
	printf 'ENABLE_VLESS_GRPC="${ENABLE_VLESS_GRPC:-true}"\nENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"\n' >"$tmp/3x-ui/3x-ui.env"
	export ENABLE_VLESS_GRPC=false
	export ENABLE_HYSTERIA2=true
	cd "$tmp"
	load_runtime_env "$tmp/runtime"
	cd "$old_pwd"
	assert_eq false "$ENABLE_VLESS_GRPC" "explicit gRPC flag must override env files"
	assert_eq true "$ENABLE_HYSTERIA2" "explicit Hysteria2 flag must override env files"
	rm -rf "$tmp"
	unset ENABLE_VLESS_GRPC ENABLE_HYSTERIA2
}

test_runtime_env_normalizes_explicit_optional_inbound_flags() {
	local tmp old_pwd
	tmp=$(mktemp -d)
	old_pwd=$PWD
	mkdir -p "$tmp/runtime" "$tmp/3x-ui"
	printf 'ENABLE_VLESS_GRPC=false\nENABLE_HYSTERIA2=true\n' >"$tmp/.env"
	printf 'ENABLE_VLESS_GRPC="${ENABLE_VLESS_GRPC:-false}"\nENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"\n' >"$tmp/3x-ui/3x-ui.env"
	export ENABLE_VLESS_GRPC=YES
	export ENABLE_HYSTERIA2=0
	cd "$tmp"
	load_runtime_env "$tmp/runtime"
	cd "$old_pwd"
	assert_eq true "$ENABLE_VLESS_GRPC" "explicit gRPC flag aliases must normalize to true"
	assert_eq false "$ENABLE_HYSTERIA2" "explicit Hysteria2 flag aliases must normalize to false"
	rm -rf "$tmp"
	unset ENABLE_VLESS_GRPC ENABLE_HYSTERIA2
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

test_client_vless_uuid_normalizes_api_variants() {
	local from_uuid from_auth invalid invalid_random_secret
	from_uuid=$(client_vless_uuid '{"uuid":"11111111-2222-3333-8444-555555555555","id":7}')
	from_auth=$(client_vless_uuid '{"uuid":"","id":7,"auth":"5c06031be7354024b568009e0cb47422"}')
	invalid=$(client_vless_uuid '{"id":7,"auth":""}' 2>/dev/null || true)
	invalid_random_secret=$(client_vless_uuid '{"id":7,"uuid":"5c06031b-e735-e024-7568-009e0cb47422","password":"d9c67df9b9e4cd267c58c6cca150f1be","auth":"5c06031be735e0247568009e0cb47422"}' 2>/dev/null || true)
	assert_eq "11111111-2222-3333-8444-555555555555" "$from_uuid" "client UUID field must be preferred"
	assert_eq "5c06031b-e735-4024-b568-009e0cb47422" "$from_auth" "valid 32-hex auth fallback must normalize to UUID"
	assert_eq "" "$invalid" "numeric row id must not be treated as VLESS UUID"
	assert_eq "" "$invalid_random_secret" "random 32-hex secrets must not be treated as VLESS UUID"
}

test_inbound_vless_client_uuid_recovers_polluted_global_client() {
	local recovered
	inbound_by_id_json() {
		printf '%s' '{"settings":{"clients":[{"email":"autogen","id":"5c06031b-e735-4024-b568-009e0cb47422","flow":"xtls-rprx-vision"}]}}'
	}
	recovered=$(inbound_vless_client_uuid 1 autogen)
	unset -f inbound_by_id_json
	assert_eq "5c06031b-e735-4024-b568-009e0cb47422" "$recovered" "VLESS UUID must recover from inbound settings"
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

test_resolve_panel_base_tries_new_password_when_username_is_unchanged() {
	local attempts
	export USERNAME=admin PASSWORD=old-password NEW_ADMIN_USERNAME=admin NEW_ADMIN_PASSWORD=new-password
	export webPort=52025 webBasePath=/panel WEBDOMAIN=example.test
	HTTP_ATTEMPTS=4
	HTTP_LOG_FAILURES=1
	# shellcheck disable=SC2034 # resolve_panel_base reads/restores these globals dynamically
	HTTP_CONNECT_TIMEOUT=2
	# shellcheck disable=SC2034 # resolve_panel_base reads/restores these globals dynamically
	HTTP_MAX_TIME=8
	xui_login() {
		printf '%s %s %s\n' "$1" "$2" "$3" >>"$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
		[[ "$2" == "admin" && "$3" == "new-password" ]]
	}
	rm -f "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
	resolve_panel_base || fail "resolve_panel_base must try NEW_ADMIN_PASSWORD even when username is unchanged"
	attempts=$(cat "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts")
	rm -f "$ROOT_DIR/tests/3x-ui-scripts/.login-attempts"
	grep -Fq "admin old-password" <<<"$attempts" || fail "old credential was not tried"
	grep -Fq "admin new-password" <<<"$attempts" || fail "new credential was not tried"
	assert_eq new-password "$PASSWORD" "resolved password must switch to NEW_ADMIN_PASSWORD"
	unset -f xui_login
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

test_client_api_uses_3x_ui_31_json_routes() {
	local call_log add_has_json update_has_json add_path update_path list_path attach_path
	call_log=$(mktemp)
	export XUI_API_TOKEN=test-token
	# shellcheck disable=SC2034 # xui_url reads URL_BASE_RESOLVED as a runtime global
	URL_BASE_RESOLVED=http://127.0.0.1:2053/panel
	http_request() {
		printf '%s\n' "$*" >>"$call_log"
		return 0
	}
	xui_add_client '{"client":{"email":"a@example.test"},"inboundIds":[1]}'
	xui_update_client a@example.test '{"email":"a@example.test"}'
	xui_list_clients
	xui_attach_client a@example.test '{"inboundIds":[2]}'
	add_path=$(grep -Fc "panel/api/clients/add" "$call_log" || true)
	update_path=$(grep -Fc "panel/api/clients/update/a@example.test" "$call_log" || true)
	list_path=$(grep -Fc "panel/api/clients/list" "$call_log" || true)
	attach_path=$(grep -Fc "panel/api/clients/a@example.test/attach" "$call_log" || true)
	add_has_json=$(grep -F "panel/api/clients/add" "$call_log" | grep -Fc "Content-Type: application/json" || true)
	update_has_json=$(grep -F "panel/api/clients/update/a@example.test" "$call_log" | grep -Fc "Content-Type: application/json" || true)
	rm -f "$call_log"
	unset -f http_request
	unset XUI_API_TOKEN
	assert_eq 1 "$add_path" "3x-ui 3.1 add client route mismatch"
	assert_eq 1 "$update_path" "3x-ui 3.1 update client route mismatch"
	assert_eq 1 "$list_path" "3x-ui 3.1 list clients route mismatch"
	assert_eq 1 "$attach_path" "3x-ui 3.1 attach client route mismatch"
	assert_eq 1 "$add_has_json" "3x-ui 3.1 add client must send JSON"
	assert_eq 1 "$update_has_json" "3x-ui 3.1 update client must send JSON"
}

test_create_mutations_use_single_long_request() {
	local observed=()
	HTTP_ATTEMPTS=4
	HTTP_MAX_TIME=8
	# shellcheck disable=SC2034 # xui_api_post_once_long reads this runtime override dynamically
	HTTP_LONG_MAX_TIME=180
	XUI_API_TOKEN=
	# shellcheck disable=SC2034 # xui_api_auth_args reads the cached token dynamically
	XUI_API_TOKEN_RESOLVED=
	URL_BASE_RESOLVED=http://127.0.0.1:2053
	xui_csrf_args() {
		return 0
	}
	http_request() {
		observed+=("$HTTP_ATTEMPTS:$HTTP_MAX_TIME:$2")
		return 0
	}
	xui_add_inbound --data-urlencode "port=62093"
	xui_add_client '{"client":{"email":"a@example.test"},"inboundIds":[1]}'
	unset -f http_request xui_csrf_args
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/3xui_api.bash"
	assert_eq "1:180:http://127.0.0.1:2053/panel/api/inbounds/add" "${observed[0]}" "Inbound create must not retry a slow mutation"
	assert_eq "1:180:http://127.0.0.1:2053/panel/api/clients/add" "${observed[1]}" "Client create must not retry a slow mutation"
	assert_eq 4 "$HTTP_ATTEMPTS" "Mutation request must restore HTTP_ATTEMPTS"
	assert_eq 8 "$HTTP_MAX_TIME" "Mutation request must restore HTTP_MAX_TIME"
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

test_custom_geo_resources_default_to_requested_dat_files() {
	local resources count first_type first_alias first_url fourth_type fourth_alias last_type last_alias
	unset CUSTOM_GEO_RESOURCES
	resources=$(custom_geo_resources_json)
	count=$(printf '%s' "$resources" | jq 'length')
	first_type=$(printf '%s' "$resources" | jq -r '.[0].type')
	first_alias=$(printf '%s' "$resources" | jq -r '.[0].alias')
	first_url=$(printf '%s' "$resources" | jq -r '.[0].url')
	fourth_type=$(printf '%s' "$resources" | jq -r '.[3].type')
	fourth_alias=$(printf '%s' "$resources" | jq -r '.[3].alias')
	last_type=$(printf '%s' "$resources" | jq -r '.[6].type')
	last_alias=$(printf '%s' "$resources" | jq -r '.[6].alias')
	assert_eq 7 "$count" "default custom geo resource count mismatch"
	assert_eq geosite "$first_type" "default first custom geo type mismatch"
	assert_eq geosite_refilter "$first_alias" "default first custom geo alias mismatch"
	assert_eq https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat "$first_url" "default first custom geo URL mismatch"
	assert_eq geoip "$fourth_type" "default fourth custom geo type mismatch"
	assert_eq geoip_zkeenip "$fourth_alias" "default fourth custom geo alias mismatch"
	assert_eq geosite "$last_type" "default adlist custom geo type mismatch"
	assert_eq adlist "$last_alias" "default adlist custom geo alias mismatch"
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
	local domains has_gov has_yandex has_ucoz has_webdomain
	domains=$(json_warp_managed_domains screenhub.linkpc.net)
	has_gov=$(printf '%s' "$domains" | jq 'index("ext:geosite_RU.dat:category-gov-ru") != null')
	has_yandex=$(printf '%s' "$domains" | jq 'index("ext:geosite_RU.dat:yandex") != null')
	has_ucoz=$(printf '%s' "$domains" | jq 'index("ext:geosite_RU.dat:ucoz-ru") != null')
	has_webdomain=$(printf '%s' "$domains" | jq 'index("domain:screenhub.linkpc.net") != null')
	assert_eq true "$has_gov" "old WARP gov RU rule was not restored"
	assert_eq true "$has_yandex" "old WARP yandex rule was not restored"
	assert_eq false "$has_ucoz" "WARP routing must not reference missing ucoz-ru geosite code"
	assert_eq false "$has_webdomain" "web domain must be routed by a separate WARP rule"
}

test_managed_xray_inserts_webdomain_rule_between_api_and_warp_rules() {
	local base dns updated api_index webdomain_index warp_index webdomain_balancer warp_balancer_count
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"blocked","protocol":"blackhole","settings":{}}],"routing":{"rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}]},"dns":{"hosts":{"example.local":"127.0.0.1"}}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true false false '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net")
	api_index=$(printf '%s' "$updated" | jq '.xraySetting.routing.rules | map((.outboundTag // "") == "api") | index(true)')
	webdomain_index=$(printf '%s' "$updated" | jq '.xraySetting.routing.rules | map(((.balancerTag // "") == "warp-balancer") and ((.domain // []) == ["domain:screenhub.linkpc.net"])) | index(true)')
	warp_index=$(printf '%s' "$updated" | jq '.xraySetting.routing.rules | map(((.balancerTag // "") == "warp-balancer") and (((.domain // []) | index("ext:geosite_RU.dat:category-gov-ru")) != null)) | index(true)')
	webdomain_balancer=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[] | select((.domain // []) == ["domain:screenhub.linkpc.net"]) | .balancerTag')
	warp_balancer_count=$(printf '%s' "$updated" | jq '[.xraySetting.routing.rules[] | select((.balancerTag // "") == "warp-balancer")] | length')
	assert_eq 0 "$api_index" "API rule must remain first in fixture"
	assert_eq 1 "$webdomain_index" "web domain WARP rule must be inserted immediately after API"
	assert_eq 2 "$warp_index" "broad WARP rule must be inserted after the web domain rule"
	assert_eq warp-balancer "$webdomain_balancer" "web domain rule must use WARP balancer"
	assert_eq 2 "$warp_balancer_count" "managed state must create separate web domain and broad WARP rules"
}

test_managed_xray_restores_warp_tor_dns_without_missing_balancer_refs() {
	local base dns updated selector_count tor_port dns_first burst_destination
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"blocked","protocol":"blackhole","settings":{}}],"routing":{"rules":[]},"dns":{"hosts":{"example.local":"127.0.0.1"}}}}'
	dns='[{"address":"adguard","port":53,"skipFallback":false}]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true true true '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	selector_count=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector[] | select(.=="usque")] | length')
	tor_port=$(printf '%s' "$updated" | jq -r '.xraySetting.outbounds[] | select(.tag=="tor-proxy") | .settings.servers[0].port')
	dns_first=$(printf '%s' "$updated" | jq -r '.xraySetting.dns.servers[0].address')
	burst_destination=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.pingConfig.destination')
	assert_eq 1 "$selector_count" "WARP balancer does not reference available usque"
	assert_eq 1080 "$tor_port" "TOR outbound must use current tor-proxy:1080 endpoint"
	assert_eq adguard "$dns_first" "DNS servers were not restored"
	assert_eq https://connectivitycheck.gstatic.com/generate_204 "$burst_destination" "burstObservatory ping destination mismatch"
}

test_xhttp_stream_uses_minimal_context_headers_and_sockopt() {
	local stream headers server content_type connection cache_control access_origin access_methods access_headers tproxy force_tls penetrate ep_sni ep_fp ep_alpn ep_insecure
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
	penetrate=$(printf '%s' "$stream" | jq -r '.sockopt.penetrate')
	ep_sni=$(printf '%s' "$stream" | jq -r '.externalProxy[0].sni')
	ep_fp=$(printf '%s' "$stream" | jq -r '.externalProxy[0].fingerprint')
	ep_alpn=$(printf '%s' "$stream" | jq -r '(.externalProxy[0].alpn // []) | join(",")')
	ep_insecure=$(printf '%s' "$stream" | jq -r '[.. | objects | select(has("allowInsecure"))] | length')
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
	assert_eq null "$penetrate" "XHTTP sockopt must not emit removed penetrate field"
	assert_eq screenhub.linkpc.net "$ep_sni" "XHTTP externalProxy must publish SNI for TLS subscriptions"
	[[ "$ep_fp" =~ ^(random|firefox|safari)$ ]] || fail "XHTTP externalProxy fingerprint must be random/firefox/safari; got '$ep_fp'"
	assert_eq h2,http/1.1 "$ep_alpn" "XHTTP externalProxy must publish modern TLS ALPN hints"
	assert_eq 0 "$ep_insecure" "XHTTP stream must not contain removed allowInsecure anywhere"
}

test_grpc_stream_uses_tls_backend_settings() {
	local stream network security service_name alpn cert_file key_file scheme fp ep_sni ep_fp ep_alpn insecure
	stream=$(build_grpc_stream_json /grpc screenhub.linkpc.net /etc/x-ui/xray.crt /etc/x-ui/xray.key)
	network=$(printf '%s' "$stream" | jq -r '.network')
	security=$(printf '%s' "$stream" | jq -r '.security')
	service_name=$(printf '%s' "$stream" | jq -r '.grpcSettings.serviceName')
	alpn=$(printf '%s' "$stream" | jq -r '.tlsSettings.alpn | join(",")')
	cert_file=$(printf '%s' "$stream" | jq -r '.tlsSettings.certificates[0].certificateFile')
	key_file=$(printf '%s' "$stream" | jq -r '.tlsSettings.certificates[0].keyFile')
	scheme=$(printf '%s' "$stream" | jq -r '.externalProxy[0].forceTls')
	fp=$(printf '%s' "$stream" | jq -r '.tlsSettings.settings.fingerprint')
	ep_sni=$(printf '%s' "$stream" | jq -r '.externalProxy[0].sni')
	ep_fp=$(printf '%s' "$stream" | jq -r '.externalProxy[0].fingerprint')
	ep_alpn=$(printf '%s' "$stream" | jq -r '(.externalProxy[0].alpn // []) | join(",")')
	insecure=$(printf '%s' "$stream" | jq -r '[.. | objects | select(has("allowInsecure"))] | length')
	assert_eq grpc "$network" "gRPC stream must use grpc network"
	assert_eq tls "$security" "gRPC stream must use TLS backend security"
	assert_eq grpc "$service_name" "gRPC serviceName must strip the leading slash"
	assert_eq h2 "$alpn" "gRPC backend TLS ALPN must prefer h2 only"
	assert_eq /etc/x-ui/xray.crt "$cert_file" "gRPC TLS certificate path mismatch"
	assert_eq /etc/x-ui/xray.key "$key_file" "gRPC TLS key path mismatch"
	assert_eq tls "$scheme" "gRPC externalProxy must publish TLS links"
	[[ "$fp" =~ ^(random|firefox|safari)$ ]] || fail "gRPC TLS fingerprint must be random/firefox/safari; got '$fp'"
	assert_eq screenhub.linkpc.net "$ep_sni" "gRPC externalProxy must publish SNI for TLS subscriptions"
	[[ "$ep_fp" =~ ^(random|firefox|safari)$ ]] || fail "gRPC externalProxy fingerprint must be random/firefox/safari; got '$ep_fp'"
	assert_eq h2 "$ep_alpn" "gRPC externalProxy must publish h2 ALPN"
	assert_eq 0 "$insecure" "gRPC stream must not contain removed allowInsecure anywhere"
}

test_hysteria2_stream_and_settings_use_required_auth() {
	local stream settings components network security alpn masq_type masq_url auth stream_auth email protocol tg_id group comment
	stream=$(build_hysteria2_stream_json screenhub.linkpc.net /etc/x-ui/xray.crt /etc/x-ui/xray.key transport-auth)
	settings=$(build_hysteria2_settings_json '' "$(build_desired_state)")
	components=$(build_inbound_components_json hysteria2 "$(build_desired_state)")
	network=$(printf '%s' "$stream" | jq -r '.network')
	security=$(printf '%s' "$stream" | jq -r '.security')
	alpn=$(printf '%s' "$stream" | jq -r '.tlsSettings.alpn | join(",")')
	masq_type=$(printf '%s' "$stream" | jq -r '.hysteriaSettings.masquerade.type')
	masq_url=$(printf '%s' "$stream" | jq -r '.hysteriaSettings.masquerade.url')
	auth=$(printf '%s' "$settings" | jq -r '.clients[0].auth')
	stream_auth=$(printf '%s' "$components" | jq -r '.streamSettings.hysteriaSettings.auth')
	email=$(printf '%s' "$settings" | jq -r '.clients[0].email')
	protocol=$(printf '%s' "$components" | jq -r '.protocol')
	tg_id=$(printf '%s' "$settings" | jq -r '.clients[0].tgId')
	group=$(printf '%s' "$settings" | jq -r '.clients[0].group')
	comment=$(printf '%s' "$settings" | jq -r '.clients[0].comment')
	assert_eq hysteria "$network" "Hysteria2 stream must use hysteria transport"
	assert_eq tls "$security" "Hysteria2 stream must use TLS"
	assert_eq h3 "$alpn" "Hysteria2 TLS ALPN must use h3"
	assert_eq proxy "$masq_type" "Hysteria2 masquerade must proxy the public site"
	assert_eq https://screenhub.linkpc.net/ "$masq_url" "Hysteria2 masquerade URL mismatch"
	[[ -n "$auth" ]] || fail "Hysteria2 client auth must be generated"
	[[ -n "$stream_auth" ]] || fail "Hysteria2 transport auth must match the managed client auth"
	assert_eq "$(printf '%s' "$components" | jq -r '.settings.clients[0].auth')" "$stream_auth" "Hysteria2 transport auth must mirror inbound client auth"
	assert_eq autogen "$email" "Hysteria2 must reuse the shared managed client email"
	assert_eq hysteria "$protocol" "Hysteria2 inbound must use Xray hysteria protocol with version=2"
	assert_eq 0 "$tg_id" "Hysteria2 client tgId must be numeric for 3x-ui 3.1 validation"
	assert_eq "" "$group" "Hysteria2 client group must be present as an empty string"
	assert_eq "" "$comment" "Hysteria2 client comment must be present as an empty string"
}

test_vision_stream_restores_old_reality_external_proxy() {
	local stream force_tls short_id_count
	stream=$(build_vision_stream_json traefik:4443 screenhub.linkpc.net private public '["aa","bb"]' '{}' '' '')
	force_tls=$(printf '%s' "$stream" | jq -r '.externalProxy[0].forceTls')
	short_id_count=$(printf '%s' "$stream" | jq '.realitySettings.shortIds | length')
	assert_eq same "$force_tls" "old Vision externalProxy forceTls was not restored"
	assert_eq 2 "$short_id_count" "Vision shortIds were not preserved"
}

test_vision_stream_is_clean_self_steal() {
	local stream show target target_xver server_name empty_short_ids max_time_diff legacy_max_timediff penetrate fp insecure
	stream=$(build_vision_stream_json telemt:9443 screenhub.linkpc.net private public '["aa","bb"]' "$(build_sockopt_json false AsIs off)" '' '' 1)
	show=$(printf '%s' "$stream" | jq -r '.realitySettings.show')
	target=$(printf '%s' "$stream" | jq -r '.realitySettings.target // empty')
	target_xver=$(printf '%s' "$stream" | jq -r '.realitySettings.xver')
	server_name=$(printf '%s' "$stream" | jq -r '.realitySettings.serverNames[0]')
	empty_short_ids=$(printf '%s' "$stream" | jq '[.realitySettings.shortIds[] | select(. == "")] | length')
	max_time_diff=$(printf '%s' "$stream" | jq -r '.realitySettings.maxTimeDiff')
	legacy_max_timediff=$(printf '%s' "$stream" | jq -r '.realitySettings.maxTimediff')
	penetrate=$(printf '%s' "$stream" | jq -r '.sockopt.penetrate')
	fp=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.fingerprint')
	insecure=$(printf '%s' "$stream" | jq -r '[.. | objects | select(has("allowInsecure"))] | length')
	assert_eq false "$show" "Reality show must be false for anti-probing clean install"
	assert_eq telemt:9443 "$target" "Reality self-steal target must point to Telemt before Traefik"
	assert_eq 1 "$target_xver" "Reality self-steal target must send PROXY protocol to Telemt"
	assert_eq screenhub.linkpc.net "$server_name" "Reality serverNames must whitelist the public front domain"
	assert_eq 0 "$empty_short_ids" "Reality shortIds must not contain empty example values"
	assert_eq 0 "$max_time_diff" "Reality stream must use current maxTimeDiff field"
	assert_eq null "$legacy_max_timediff" "Reality stream must not use legacy misspelled maxTimediff field"
	assert_eq null "$penetrate" "Reality sockopt must not emit removed penetrate field"
	[[ "$fp" =~ ^(random|firefox|safari)$ ]] || fail "Reality fingerprint must be random/firefox/safari; got '$fp'"
	assert_eq 0 "$insecure" "Reality stream must not contain removed allowInsecure anywhere"
}

test_existing_vision_stream_is_sanitized_without_regenerating_keys() {
	local current stream private_key public_key fingerprint insecure legacy_max_timediff
	current='{"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"privateKey":"old-private","maxTimediff":0,"settings":{"publicKey":"old-public","fingerprint":"chrome","allowInsecure":false}},"sockopt":{"penetrate":true},"externalProxy":[{"forceTls":"same","dest":"screenhub.linkpc.net","port":443,"allowInsecure":false}]}}'
	stream=$(build_inbound_stream_json vision "$current")
	private_key=$(printf '%s' "$stream" | jq -r '.realitySettings.privateKey')
	public_key=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.publicKey')
	fingerprint=$(printf '%s' "$stream" | jq -r '.realitySettings.settings.fingerprint')
	insecure=$(printf '%s' "$stream" | jq -r '[.. | objects | select(has("allowInsecure"))] | length')
	legacy_max_timediff=$(printf '%s' "$stream" | jq -r '.realitySettings.maxTimediff')
	assert_eq old-private "$private_key" "existing Vision private key must be preserved"
	assert_eq old-public "$public_key" "existing Vision public key must be preserved"
	[[ "$fingerprint" =~ ^(random|firefox|safari)$ ]] || fail "existing Vision fingerprint must be refreshed; got '$fingerprint'"
	assert_eq 0 "$insecure" "existing Vision stream must be stripped from allowInsecure"
	assert_eq null "$legacy_max_timediff" "existing Vision stream must drop legacy maxTimediff"
}

test_vision_settings_include_telemt_fallback_preserving_clients() {
	local inbound settings fallback_dest clients decryption encryption
	export VISION_FALLBACK_HOST=telemt
	export VISION_FALLBACK_PORT=9443
	export VISION_FALLBACK_XVER=1
	inbound='{"settings":"{\"clients\":[{\"id\":\"client-id\",\"email\":\"a@example.test\"}],\"decryption\":\"none\",\"encryption\":\"none\"}"}'
	settings=$(build_vless_settings_json vision "$inbound")
	fallback_dest=$(printf '%s' "$settings" | jq -r '.fallbacks[0].dest')
	clients=$(printf '%s' "$settings" | jq '.clients | length')
	decryption=$(printf '%s' "$settings" | jq -r '.decryption')
	encryption=$(printf '%s' "$settings" | jq -r '.encryption')
	assert_eq telemt:9443 "$fallback_dest" "Vision fallback must point to Telemt"
	assert_eq 1 "$clients" "Vision update must preserve existing clients"
	assert_eq none "$decryption" "Vision VLESS settings must keep decryption=none"
	assert_eq none "$encryption" "Vision VLESS settings must keep encryption=none for subscription outbounds"
}

test_vless_client_api_payloads_match_3x_ui_31_contract() {
	local client create_payload tg_id group security inbound_count create_email update_email update_uuid update_auth update_password legacy_settings
	client=$(vless_client_api_json client-id a@example.test stable-sub xtls-rprx-vision client-password client-auth)
	create_payload=$(vless_client_create_payload_json '[12,13]' "$client")
	tg_id=$(printf '%s' "$client" | jq -r '.tgId')
	group=$(printf '%s' "$client" | jq -r '.group')
	security=$(printf '%s' "$client" | jq -r '.security')
	update_email=$(printf '%s' "$client" | jq -r '.email')
	update_uuid=$(printf '%s' "$client" | jq -r '.uuid')
	update_password=$(printf '%s' "$client" | jq -r '.password')
	update_auth=$(printf '%s' "$client" | jq -r '.auth')
	inbound_count=$(printf '%s' "$create_payload" | jq '.inboundIds | length')
	create_email=$(printf '%s' "$create_payload" | jq -r '.client.email')
	legacy_settings=$(printf '%s' "$create_payload" | jq -r '.settings // empty')
	assert_eq 0 "$tg_id" "3x-ui 3.1 client tgId must be numeric"
	assert_eq "" "$group" "3x-ui 3.1 client group must be present as an empty string"
	assert_eq auto "$security" "3x-ui 3.1 client security must default to auto"
	assert_eq a@example.test "$update_email" "3x-ui 3.1 update payload must be the direct client object"
	assert_eq client-id "$update_uuid" "3x-ui 3.1 VLESS payload must include uuid as well as id"
	assert_eq client-password "$update_password" "shared client payload must carry password for non-VLESS protocols"
	assert_eq client-auth "$update_auth" "shared client payload must carry Hysteria auth"
	assert_eq 2 "$inbound_count" "3x-ui 3.1 create payload must support shared client attachments"
	assert_eq a@example.test "$create_email" "3x-ui 3.1 create payload must wrap client object"
	assert_eq "" "$legacy_settings" "3x-ui 3.1 client create payload must not use legacy settings wrapper"
}

test_shared_client_create_still_syncs_vless_inbounds_without_grpc() {
	local desired add_payload add_inbounds synced=()
	export MODE=apply
	export CLIENT_EMAIL_PREFIX=autogen
	export CLIENT_SUB_ID=stable-sub
	# shellcheck disable=SC2034 # record_change mutates this runtime global during the fixture.
	CHANGE_COUNT=0
	# shellcheck disable=SC2034 # ensure_shared_client mutates this runtime global during the fixture.
	RESTART_XRAY_REQUIRED=0
	desired=$(build_desired_state)
	clients_json() {
		printf '[]\n'
	}
	xui_add_client() {
		add_payload=$1
	}
	xui_attach_client() {
		fail "new shared client must not need a separate attach call"
	}
	http_success_json() {
		return 0
	}
	repair_shared_client_db() {
		return 0
	}
	ensure_vless_inbound_client() {
		synced+=("$1:$4:$5")
	}
	ensure_vless_stream() {
		return 0
	}
	ensure_shared_client 1 2 "" 4 "$desired"
	add_inbounds=$(printf '%s' "$add_payload" | jq -r '.inboundIds | join(",")')
	assert_eq "1,2,4" "$add_inbounds" "shared client create must target Vision, XHTTP and Hysteria2 when gRPC is disabled"
	assert_eq "1:xtls-rprx-vision:Vision" "${synced[0]}" "Vision inbound client must be explicitly synchronized after shared client create"
	assert_eq "2::XHTTP" "${synced[1]}" "XHTTP inbound client must be explicitly synchronized after shared client create"
	assert_eq 2 "${#synced[@]}" "only VLESS inbounds are synchronized inside ensure_shared_client"
	[[ -n "$ENSURE_SHARED_CLIENT_ID" ]] || fail "shared client id must be available after create"
	unset -f clients_json xui_add_client xui_attach_client http_success_json repair_shared_client_db ensure_vless_inbound_client ensure_vless_stream
	unset MODE CLIENT_EMAIL_PREFIX CLIENT_SUB_ID
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/inbound_runtime.bash"
}

test_existing_shared_client_with_invalid_uuid_is_repaired() {
	local desired update_payload synced=()
	export MODE=apply
	export CLIENT_EMAIL_PREFIX=autogen
	export CLIENT_SUB_ID=stable-sub
	# shellcheck disable=SC2034 # record_change mutates this runtime global during the fixture.
	CHANGE_COUNT=0
	# shellcheck disable=SC2034 # ensure_shared_client mutates this runtime global during the fixture.
	RESTART_XRAY_REQUIRED=0
	desired=$(build_desired_state)
	clients_json() {
		printf '%s\n' '[{"id":1,"email":"autogen","subId":"old-sub","uuid":"5c06031b-e735-e024-7568-009e0cb47422","password":"d9c67df9b9e4cd267c58c6cca150f1be","auth":"5c06031be735e0247568009e0cb47422","flow":"","inboundIds":[1,2,4]}]'
	}
	inbound_vless_client_uuid() {
		return 1
	}
	new_uuid() {
		printf '%s' "87853b09-32fc-49e0-95ad-2651948b7e3e"
	}
	xui_update_client() {
		update_payload=$2
	}
	xui_attach_client() {
		fail "invalid UUID repair must not attach already attached inbounds"
	}
	http_success_json() {
		return 0
	}
	repair_shared_client_db() {
		return 0
	}
	ensure_vless_inbound_client() {
		synced+=("$2:$5")
	}
	ensure_vless_stream() {
		return 0
	}
	ensure_shared_client 1 2 "" 4 "$desired"
	assert_eq "87853b09-32fc-49e0-95ad-2651948b7e3e" "$(printf '%s' "$update_payload" | jq -r '.id')" "invalid first-class UUID must be replaced with a valid UUID"
	assert_eq "87853b09-32fc-49e0-95ad-2651948b7e3e" "$(printf '%s' "$update_payload" | jq -r '.uuid')" "update payload must carry matching uuid"
	assert_eq 2 "${#synced[@]}" "repaired UUID must be synced to VLESS inbounds"
	assert_eq "87853b09-32fc-49e0-95ad-2651948b7e3e:Vision" "${synced[0]}" "Vision sync must use repaired UUID"
	unset -f clients_json inbound_vless_client_uuid new_uuid xui_update_client xui_attach_client http_success_json repair_shared_client_db ensure_vless_inbound_client ensure_vless_stream
	unset MODE CLIENT_EMAIL_PREFIX CLIENT_SUB_ID
	. "$SCRIPTS_DIR/lib/inbound_runtime.bash"
}

test_vless_inbound_client_sync_writes_uuid() {
	local inbound desired current_settings desired_settings client_id
	desired=$(build_desired_state)
	client_id="f5382230-6a5e-aed7-357e-4578f8c53bdd"
	inbound='{"settings":"{\"clients\":[{\"email\":\"autogen\",\"flow\":\"xtls-rprx-vision\"}],\"decryption\":\"none\",\"encryption\":\"none\"}"}'
	current_settings=$(json_field_object "$inbound" settings)
	desired_settings=$(jq -nc --argjson current "$current_settings" --argjson client "$(vless_client_api_json "$client_id" autogen stable-sub xtls-rprx-vision)" '
      $current
      | .decryption = "none"
      | .encryption = "none"
      | .clients = (((.clients // []) | map(select(.email != $client.email))) + [$client])
    ')
	assert_eq "$client_id" "$(printf '%s' "$desired_settings" | jq -r '.clients[0].id')" "synced VLESS inbound client must include UUID id"
	assert_eq "$client_id" "$(printf '%s' "$desired_settings" | jq -r '.clients[0].uuid')" "synced VLESS inbound client must include uuid field"
	assert_eq xtls-rprx-vision "$(printf '%s' "$desired_settings" | jq -r '.clients[0].flow')" "Vision flow must be preserved"
}

test_tor_balancer_uses_single_proxy_endpoint() {
	local base dns updated selector_count rule_balancer ports
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" false true false '[]' "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	selector_count=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="tor-balancer") | .selector[]] | length')
	rule_balancer=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[] | select(.balancerTag=="tor-balancer") | .balancerTag')
	ports=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="tor-proxy" or .tag=="torproxy") | "\(.tag):\(.settings.servers[0].port)"] | sort | join(",")')
	assert_eq 1 "$selector_count" "TOR balancer must include one selector"
	assert_eq tor-balancer "$rule_balancer" "TOR routing must use balancerTag"
	assert_eq "tor-proxy:1080" "$ports" "TOR outbound endpoints mismatch"
}

test_warp_balancer_uses_usque_without_console_warp() {
	local base dns updated selectors protocols usque_port burst_subjects observatory fallback
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true false false '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net" '[]')
	selectors=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector | sort | join(",")')
	protocols=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="warp" or .tag=="usque") | "\(.tag):\(.protocol)"] | sort | join(",")')
	usque_port=$(printf '%s' "$updated" | jq -r '.xraySetting.outbounds[] | select(.tag=="usque") | .settings.servers[0].port')
	burst_subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	observatory=$(printf '%s' "$updated" | jq -r '.xraySetting.observatory')
	fallback=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .fallbackTag')
	assert_eq "usque" "$selectors" "WARP balancer selectors mismatch"
	assert_eq "usque:socks" "$protocols" "WARP outbound protocols mismatch"
	assert_eq 1080 "$usque_port" "usque outbound port mismatch"
	assert_eq "usque" "$burst_subjects" "WARP burstObservatory selectors mismatch"
	assert_eq null "$observatory" "legacy observatory must not be used with managed balancers"
	assert_eq blocked "$fallback" "WARP balancer fallbackTag mismatch"
}

test_warp_balancer_can_opt_in_console_warp() {
	local base dns updated selectors protocols burst_subjects warp_console
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[]}}}'
	dns='[]'
	warp_console='{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"test","address":["172.16.0.2/32"],"peers":[{"publicKey":"peer","allowedIPs":["0.0.0.0/0"],"endpoint":"engage.cloudflareclient.com:2408"}]}}'
	updated=$(json_apply_managed_xray_state "$base" "$dns" true false false '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net" '[]' "$warp_console")
	selectors=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.balancers[] | select(.tag=="warp-balancer") | .selector | sort | join(",")')
	protocols=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="warp" or .tag=="usque") | "\(.tag):\(.protocol)"] | sort | join(",")')
	burst_subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	assert_eq "usque,warp" "$selectors" "Console WARP opt-in selectors mismatch"
	assert_eq "usque:socks,warp:wireguard" "$protocols" "Console WARP opt-in protocols mismatch"
	assert_eq "usque,warp" "$burst_subjects" "Console WARP opt-in burstObservatory selectors mismatch"
}

test_mihomo_outbound_and_terminal_rule_are_added_when_available() {
	local base updated outbound_count last_rule_tag last_rule_network
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}}],"routing":{"rules":[{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}]}}}'

	updated=$(json_apply_managed_xray_state "$base" '[]' false false false '[]' "screenhub.linkpc.net" '[]' '' true '[{"tag":"mihomo","host":"mihomo","port":7890}]')
	outbound_count=$(printf '%s' "$updated" | jq '[.xraySetting.outbounds[]? | select(.tag=="mihomo" and .protocol=="socks" and .settings.servers[0].address=="mihomo" and .settings.servers[0].port==7890 and (.settings.servers[0].users | length)==0)] | length')
	last_rule_tag=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[-1].outboundTag')
	last_rule_network=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[-1].network')

	assert_eq 1 "$outbound_count" "Mihomo SOCKS outbound must be added when endpoint is available"
	assert_eq mihomo "$last_rule_tag" "Mihomo rule must be appended as the terminal routing rule"
	assert_eq tcp,udp "$last_rule_network" "Mihomo terminal routing rule must cover TCP and UDP"
}

test_existing_mihomo_outbound_and_rule_are_preserved() {
	local base updated port rule_index last_rule_tag
	base='{"xraySetting":{"outbounds":[{"tag":"mihomo","protocol":"socks","settings":{"servers":[{"address":"custom-mihomo","port":17890,"users":[{"user":"kept"}]}]}}],"routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"mihomo"},{"type":"field","outboundTag":"blocked","ip":["geoip:private"]}]}}}'

	updated=$(json_apply_managed_xray_state "$base" '[]' false false false '[]' "screenhub.linkpc.net" '[]' '' true '[{"tag":"mihomo","host":"mihomo","port":7890}]')
	port=$(printf '%s' "$updated" | jq -r '.xraySetting.outbounds[] | select(.tag=="mihomo") | .settings.servers[0].port')
	rule_index=$(printf '%s' "$updated" | jq '.xraySetting.routing.rules | map((.outboundTag // "") == "mihomo") | index(true)')
	last_rule_tag=$(printf '%s' "$updated" | jq -r '.xraySetting.routing.rules[-1].outboundTag')

	assert_eq 17890 "$port" "existing Mihomo outbound must not be overwritten"
	assert_eq 0 "$rule_index" "existing Mihomo routing rule must not be moved"
	assert_eq blocked "$last_rule_tag" "existing terminal rule order must be preserved when Mihomo rule already exists"
}

test_managed_burst_observatory_preserves_custom_subjects() {
	local base dns updated subjects custom_observatory
	base='{"xraySetting":{"outbounds":[],"routing":{"rules":[],"balancers":[]},"burstObservatory":{"subjectSelector":["custom-out"],"pingConfig":{"destination":"https://old.example/204"}}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$(json_remove_managed_xray_artifacts "$base")" "$dns" false true false '[]' "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	custom_observatory=$(printf '%s' "$updated" | jq -r '.xraySetting.observatory')
	assert_eq "custom-out,tor-proxy" "$subjects" "custom burstObservatory subjects were not preserved"
	assert_eq null "$custom_observatory" "unexpected observatory object was created"
}

test_managed_xray_preserves_unmanaged_balancers_and_rules() {
	local base dns updated custom_balancers custom_rules custom_outbounds
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"custom-proxy","protocol":"socks","settings":{"servers":[{"address":"custom","port":1080}]}}],"routing":{"rules":[{"type":"field","balancerTag":"custom-balancer","domain":["domain:example.com"]},{"type":"field","outboundTag":"custom-proxy","domain":["domain:direct.example"]}],"balancers":[{"tag":"custom-balancer","selector":["custom-proxy"],"strategy":{"type":"random"}}]},"burstObservatory":{"subjectSelector":["custom-proxy"],"pingConfig":{"destination":"https://old.example/204"}}}}'
	dns='[]'
	updated=$(json_apply_managed_xray_state "$(json_remove_managed_xray_artifacts "$base")" "$dns" true true false '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	custom_balancers=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="custom-balancer")] | length')
	custom_rules=$(printf '%s' "$updated" | jq '[.xraySetting.routing.rules[] | select((.balancerTag // "")=="custom-balancer" or (.outboundTag // "")=="custom-proxy")] | length')
	custom_outbounds=$(printf '%s' "$updated" | jq '[.xraySetting.outbounds[] | select(.tag=="custom-proxy")] | length')
	assert_eq 1 "$custom_balancers" "custom balancer must survive managed Xray update"
	assert_eq 2 "$custom_rules" "custom routing rules must survive managed Xray update"
	assert_eq 1 "$custom_outbounds" "custom outbound must survive managed Xray update"
}

test_unhealthy_external_proxies_create_no_managed_xray_artifacts() {
	local base updated managed_outbounds managed_balancers managed_rules subjects
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"blocked","protocol":"blackhole","settings":{}}],"routing":{"rules":[],"balancers":[]},"burstObservatory":null}}'
	updated=$(json_apply_managed_xray_state "$base" '[]' true true false '[]' "screenhub.linkpc.net" '[]')
	managed_outbounds=$(printf '%s' "$updated" | jq '[.xraySetting.outbounds[] | select(.tag=="usque" or .tag=="tor-proxy" or .tag=="torproxy")] | length')
	managed_balancers=$(printf '%s' "$updated" | jq '[.xraySetting.routing.balancers[] | select(.tag=="warp-balancer" or .tag=="tor-balancer")] | length')
	managed_rules=$(printf '%s' "$updated" | jq '[.xraySetting.routing.rules[] | select(.balancerTag=="warp-balancer" or .balancerTag=="tor-balancer")] | length')
	subjects=$(printf '%s' "$updated" | jq '[.xraySetting.burstObservatory.subjectSelector[]?] | length')
	assert_eq 0 "$managed_outbounds" "unhealthy proxies must not produce managed outbounds"
	assert_eq 0 "$managed_balancers" "unhealthy proxies must not produce managed balancers"
	assert_eq 0 "$managed_rules" "unhealthy proxies must not produce managed routing rules"
	assert_eq 0 "$subjects" "unhealthy proxies must not produce observatory subjects"
}

test_only_healthy_external_proxies_enter_xray_state() {
	local base updated outbounds subjects
	base='{"xraySetting":{"outbounds":[{"tag":"direct","protocol":"freedom","settings":{}},{"tag":"blocked","protocol":"blackhole","settings":{}}],"routing":{"rules":[],"balancers":[]}}}'
	updated=$(json_apply_managed_xray_state "$base" '[]' true true false '[{"tag":"usque","host":"usque","port":1080}]' "screenhub.linkpc.net" '[{"tag":"tor-proxy","host":"tor-proxy","port":1080}]')
	outbounds=$(printf '%s' "$updated" | jq -r '[.xraySetting.outbounds[] | select(.tag=="usque" or .tag=="tor-proxy" or .tag=="torproxy") | .tag] | sort | join(",")')
	subjects=$(printf '%s' "$updated" | jq -r '.xraySetting.burstObservatory.subjectSelector | sort | join(",")')
	assert_eq "tor-proxy,usque" "$outbounds" "only healthy proxy endpoints must become outbounds"
	assert_eq "tor-proxy,usque" "$subjects" "only healthy proxy endpoints must be observed"
}

test_runtime_does_not_probe_legacy_torproxy_endpoint() {
	if grep -Rq 'TOR_PROXY_ALT_' "$SCRIPTS_DIR/01_AfterStart" "$SCRIPTS_DIR/lib"; then
		fail "managed runtime must not retain alternate torproxy endpoint defaults or probes"
	fi
}

test_warp_proxy_probe_requires_confirmed_warp_route() {
	curl() {
		printf 'fl=1\nwarp=on\n'
	}
	warp_proxy_available usque 1080 || fail "warp=on response must pass WARP proxy probe"
	curl() {
		printf 'fl=1\nwarp=off\n'
	}
	if warp_proxy_available usque 1080; then
		fail "warp=off response must fail WARP proxy probe"
	fi
	unset -f curl
}

test_tor_proxy_probe_requires_confirmed_tor_route() {
	curl() {
		printf '{"IsTor":true}\n'
	}
	tor_proxy_available tor-proxy 1080 || fail "IsTor=true response must pass TOR proxy probe"
	curl() {
		printf '{"IsTor":false}\n'
	}
	if tor_proxy_available tor-proxy 1080; then
		fail "IsTor=false response must fail TOR proxy probe"
	fi
	unset -f curl
}

test_apply_managed_xray_passes_mihomo_endpoint_only_when_reachable() {
	local tmp seen_file
	tmp=$(mktemp -d)
	seen_file="$tmp/seen"
	HTTP_BODY_FILE="$tmp/body.json"
	# shellcheck disable=SC2034 # apply_managed_xray consumes this runtime global.
	TMP_ROOT="$tmp"
	export MODE=apply
	export XRAY_MANAGED_DNS=false
	export XRAY_MANAGED_WARP=false
	export XRAY_MANAGED_TOR=false
	export ENABLE_MIHOMO=true
	export MIHOMO_PROXY_HOST=mihomo
	export MIHOMO_PROXY_PORT=7890
	export WEBDOMAIN=screenhub.linkpc.net
	# shellcheck disable=SC2034 # record_change mutates this runtime global in apply fixtures.
	CHANGE_COUNT=0
	# shellcheck disable=SC2034 # apply_managed_xray mutates this runtime global when updates are applied.
	RESTART_PANEL_REQUIRED=0
	# shellcheck disable=SC2034 # apply_managed_xray mutates this runtime global when updates are applied.
	RESTART_XRAY_REQUIRED=0
	xui_get_xray_settings() {
		printf '%s\n' '{"obj":"{\"xraySetting\":{\"outbounds\":[],\"routing\":{\"rules\":[]}}}"}' >"$HTTP_BODY_FILE"
	}
	http_success_json() {
		return 0
	}
	available_dns_servers() {
		printf '[]'
	}
	tcp_endpoint_available() {
		[[ "$1:$2" == "mihomo:7890" ]]
	}
	json_apply_managed_xray_state() {
		printf '%s\n' "${11}" >>"$seen_file"
		printf '%s' "$1"
	}
	plan_or_apply() {
		return 1
	}

	apply_managed_xray

	assert_eq '[{"tag":"mihomo","host":"mihomo","port":7890}]' "$(sed -n '1p' "$seen_file")" "reachable Mihomo endpoint must be passed to managed Xray state"
	tcp_endpoint_available() {
		return 1
	}
	: >"$seen_file"
	apply_managed_xray
	assert_eq '[]' "$(sed -n '1p' "$seen_file")" "unreachable Mihomo endpoint must not be passed to managed Xray state"
	unset -f xui_get_xray_settings http_success_json available_dns_servers tcp_endpoint_available json_apply_managed_xray_state plan_or_apply
	unset MODE XRAY_MANAGED_DNS XRAY_MANAGED_WARP XRAY_MANAGED_TOR ENABLE_MIHOMO MIHOMO_PROXY_HOST MIHOMO_PROXY_PORT WEBDOMAIN
	rm -rf "$tmp"
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/xray_runtime.bash"
}

test_afterstart_entrypoint_loads_runtime_modules() {
	local script module function
	script="$SCRIPTS_DIR/01_AfterStart/3x-ui-upd.sh"
	for module in runtime_common panel_runtime inbound_runtime xray_runtime; do
		[[ -f "$SCRIPTS_DIR/lib/$module.bash" ]] ||
			fail "after-start runtime module is missing: $module.bash"
		grep -Fq ". \"\$LIB_DIR/$module.bash\"" "$script" ||
			fail "after-start entrypoint must source $module.bash"
	done
	for function in record_change ensure_panel_settings ensure_inbound apply_managed_xray restart_if_needed; do
		if grep -Eq "^${function}\\(\\)" "$script"; then
			fail "after-start entrypoint must not retain domain function: $function"
		fi
	done
}

test_afterstart_entrypoint_preserves_pipeline_order() {
	local script block expression line previous=0
	script="$SCRIPTS_DIR/01_AfterStart/3x-ui-upd.sh"
	block=$(sed -n '/^main()/,/^}/p' "$script")
	for expression in \
		'http_init "$TMP_ROOT"' \
		'load_runtime_env "$SCRIPT_DIR"' \
		'require_apply_mode' \
		'check_dependencies' \
		'resolve_panel_base || die "Could not resolve and login to 3x-ui panel."' \
		'detect_country_flag || true' \
		'desired=$(build_desired_state)' \
		'ensure_panel_settings' \
		'update_admin_credentials_if_needed' \
		'resolve_panel_base || die "Could not login after panel settings update."' \
		'ensure_custom_geo_resources' \
		'update_builtin_geofiles_if_enabled' \
		'ensure_inbound vision "$desired"' \
		'ensure_inbound xhttp "$desired"' \
		'ensure_inbound grpc "$desired"' \
		'ensure_inbound hysteria2 "$desired"' \
		'ensure_shared_client "$vision_id" "$xhttp_id" "$grpc_id" "$hysteria2_id" "$desired"' \
		'ensure_grpc_client "$grpc_id" "$ENSURE_SHARED_CLIENT_ID" "$desired"' \
		'ensure_hysteria2_client "$hysteria2_id" "$desired"' \
		'repair_shared_client_after_inbound_sync "$desired"' \
		'apply_managed_xray' \
		'restart_if_needed'; do
		line=$(grep -nF "$expression" <<<"$block" | head -n1 | cut -d: -f1)
		[[ -n "$line" && "$line" -gt "$previous" ]] ||
			fail "after-start pipeline order changed near: $expression"
		previous=$line
	done
}

test_afterstart_entrypoint_initializes_optional_inbound_ids() {
	local script main_decl
	script="$SCRIPTS_DIR/01_AfterStart/3x-ui-upd.sh"
	main_decl=$(sed -n '/^main()/,/TMP_ROOT=/p' "$script")
	grep -Fq 'grpc_id=' <<<"$main_decl" ||
		fail "gRPC inbound id must be initialized for ENABLE_VLESS_GRPC=false"
	grep -Fq 'hysteria2_id=' <<<"$main_decl" ||
		fail "Hysteria2 inbound id must be initialized for ENABLE_HYSTERIA2=false"
	grep -Fq 'ENABLE_VLESS_GRPC:-false' "$script" ||
		fail "gRPC must default to disabled in the runtime entrypoint"
}

test_afterstart_check_mode_bootstraps_without_apply() {
	local output
	output=$(MODE=check LIB_DIR="$SCRIPTS_DIR/lib" bash "$SCRIPTS_DIR/01_AfterStart/3x-ui-upd.sh" 2>&1) ||
		fail "MODE=check entrypoint startup failed"
	grep -Fq 'Dependency and environment check passed.' <<<"$output" ||
		fail "MODE=check must complete before panel or Xray mutations"
}

test_xray_template_update_requests_core_restart() {
	local script block
	script="$SCRIPTS_DIR/lib/xray_runtime.bash"
	block=$(sed -n '/^apply_managed_xray()/,/^}/p' "$script")
	grep -Fq 'RESTART_XRAY_REQUIRED=1' <<<"$block" ||
		fail "managed Xray template update must request an Xray core restart"
}

test_panel_restart_does_not_suppress_xray_restart() {
	local script block
	script="$SCRIPTS_DIR/lib/xray_runtime.bash"
	block=$(sed -n '/^restart_if_needed()/,/^}/p' "$script")
	if grep -Fq 'elif ((RESTART_XRAY_REQUIRED == 1))' <<<"$block"; then
		fail "panel restart must not suppress a required Xray core restart"
	fi
}

test_wait_managed_xray_ports_checks_hysteria_udp_when_enabled() {
	local checks joined
	checks=()
	export ENABLE_HYSTERIA2=true
	export PORT_LOCAL_VISION=1443
	export PORT_LOCAL_XHTTP=2443
	export PORT_LOCAL_HYSTERIA=3443
	export XRAY_RESTART_PORT_TIMEOUT=1
	wait_tcp_port() {
		checks+=("tcp:$2:$4")
		return 0
	}
	wait_udp_port_listener() {
		checks+=("udp:$1:$3")
		return 0
	}

	wait_managed_xray_ports

	joined=$(printf '%s\n' "${checks[@]}" | paste -sd ' ' -)
	assert_eq "tcp:1443:Vision inbound 1443 tcp:2443:XHTTP inbound 2443 udp:3443:Hysteria2 inbound 3443/udp" "$joined" "managed port wait must include Hysteria2 UDP listener"
	unset -f wait_tcp_port wait_udp_port_listener
	unset ENABLE_HYSTERIA2 PORT_LOCAL_VISION PORT_LOCAL_XHTTP PORT_LOCAL_HYSTERIA XRAY_RESTART_PORT_TIMEOUT
	# shellcheck source=/dev/null
	. "$SCRIPTS_DIR/lib/xray_runtime.bash"
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
test_runtime_env_preserves_explicit_optional_inbound_flags
test_runtime_env_normalizes_explicit_optional_inbound_flags
test_desired_inbound_remarks_use_country_flag
test_managed_inbound_remarks_include_legacy_names
test_country_flag_sources_include_iso_code_fallbacks
test_country_code_to_flag_converts_iso_alpha2
test_country_flag_value_from_trace_extracts_loc
test_client_vless_uuid_normalizes_api_variants
test_inbound_vless_client_uuid_recovers_polluted_global_client
test_resolve_panel_base_prioritizes_configured_web_port
test_resolve_panel_base_tries_new_password_when_username_is_unchanged
test_normalize_base_path_accepts_empty_input
test_http_request_temp_files_are_created_under_tmp_root
test_panel_api_requests_use_bearer_token_when_configured
test_client_api_uses_3x_ui_31_json_routes
test_create_mutations_use_single_long_request
test_panel_api_requests_read_bearer_token_from_sqlite_when_env_is_empty
test_xui_login_replays_csrf_token
test_non_bearer_api_post_replays_csrf_token
test_custom_geo_resources_default_to_requested_dat_files
test_custom_geo_resources_parse_custom_entries
test_panel_keys_restore_old_cert_fields
test_warp_domains_restore_old_ru_rules
test_managed_xray_restores_warp_tor_dns_without_missing_balancer_refs
test_xhttp_stream_uses_minimal_context_headers_and_sockopt
test_grpc_stream_uses_tls_backend_settings
test_hysteria2_stream_and_settings_use_required_auth
test_vision_stream_restores_old_reality_external_proxy
test_vision_stream_is_clean_self_steal
test_existing_vision_stream_is_sanitized_without_regenerating_keys
test_vision_settings_include_telemt_fallback_preserving_clients
test_vless_client_api_payloads_match_3x_ui_31_contract
test_shared_client_create_still_syncs_vless_inbounds_without_grpc
test_existing_shared_client_with_invalid_uuid_is_repaired
test_vless_inbound_client_sync_writes_uuid
test_tor_balancer_uses_single_proxy_endpoint
test_warp_balancer_uses_usque_without_console_warp
test_warp_balancer_can_opt_in_console_warp
test_mihomo_outbound_and_terminal_rule_are_added_when_available
test_existing_mihomo_outbound_and_rule_are_preserved
test_managed_burst_observatory_preserves_custom_subjects
test_managed_xray_preserves_unmanaged_balancers_and_rules
test_unhealthy_external_proxies_create_no_managed_xray_artifacts
test_only_healthy_external_proxies_enter_xray_state
test_runtime_does_not_probe_legacy_torproxy_endpoint
test_warp_proxy_probe_requires_confirmed_warp_route
test_tor_proxy_probe_requires_confirmed_tor_route
test_apply_managed_xray_passes_mihomo_endpoint_only_when_reachable
test_afterstart_entrypoint_loads_runtime_modules
test_afterstart_entrypoint_preserves_pipeline_order
test_afterstart_entrypoint_initializes_optional_inbound_ids
test_afterstart_check_mode_bootstraps_without_apply
test_xray_template_update_requests_core_restart
test_panel_restart_does_not_suppress_xray_restart
test_wait_managed_xray_ports_checks_hysteria_udp_when_enabled
test_warp_outbound_from_registration_prefers_panel_host_endpoint
test_existing_warp_outbound_endpoint_is_normalized
test_xray_api_inbound_uses_documented_dokodemo_protocol
test_lampac_hide_interface_waits_for_lampa_global
printf 'test_libs.bash: OK\n'
