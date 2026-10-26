#!/usr/bin/env bash
set -Eeuo pipefail

# Required: SUB_ID of an existing shared client. If omitted, discover the first
# client subId from the live panel database. Optional overrides below.
WEBDOMAIN=${WEBDOMAIN:-}
SUB_PORT=${SUB_PORT:-}
CLASH_PATH=${CLASH_PATH:-}
JSON_PATH=${JSON_PATH:-}
SUB_ID=${SUB_ID:-}

PANEL_BACKUP=/tmp/panel-settings-backup.json
PANEL_BEFORE_HAPP=/tmp/panel-settings-happ-before.json
PANEL_AFTER_HAPP=/tmp/panel-settings-happ-after.json
CLASH_OUT=/tmp/clash-spike.yaml
JSON_OUT=/tmp/json-spike.json
RESTORE_DONE=0

load_host_env() {
	if [[ -r /opt/docker-proxy/compose.d/.env ]]; then
		set -a
		# shellcheck disable=SC1091
		. /opt/docker-proxy/compose.d/.env
		set +a
	fi
	WEBDOMAIN=${WEBDOMAIN:-${WEBDOMAIN:-streambase.linkpc.net}}
	SUB_PORT=${SUB_PORT:-${PORT_LOCAL_VLESS_SUBSCRIBE:-}}
	CLASH_PATH=${CLASH_PATH:-${URI_CLASH_PATH:-}}
	JSON_PATH=${JSON_PATH:-${URI_JSON_PATH:-}}
}

container_panel_settings() {
	docker exec -i 3x-ui bash -s <<'INNER'
set -Eeuo pipefail
LIB=/mnt/sh/lib
. "$LIB/log.bash"
. "$LIB/env.bash"
. "$LIB/http.bash"
. "$LIB/3xui_api.bash"
. "$LIB/runtime_common.bash"
. "$LIB/panel_runtime.bash"
. "$LIB/desired_state.bash"
load_runtime_env /mnt/sh/01_AfterStart
TMP_ROOT=$(mktemp -d); http_init "$TMP_ROOT"
resolve_panel_base || die "login failed"
xui_get_panel_settings || die "get settings failed"
http_success_json || die "get settings body failed"
api_obj_json
INNER
}

base64_one_line() {
	if base64 -w0 </dev/null >/dev/null 2>&1; then
		base64 -w0
	else
		base64 | tr -d '\n'
	fi
}

container_apply_panel_settings() {
	local body=$1 body_b64
	body_b64=$(printf '%s' "$body" | base64_one_line)
	docker exec -e PANEL_BODY_B64="$body_b64" -i 3x-ui bash -s <<'INNER'
set -Eeuo pipefail
LIB=/mnt/sh/lib
. "$LIB/log.bash"
. "$LIB/env.bash"
. "$LIB/http.bash"
. "$LIB/3xui_api.bash"
. "$LIB/runtime_common.bash"
. "$LIB/panel_runtime.bash"
. "$LIB/desired_state.bash"
load_runtime_env /mnt/sh/01_AfterStart
TMP_ROOT=$(mktemp -d); http_init "$TMP_ROOT"
resolve_panel_base || die "login failed"
body=$(printf '%s' "$PANEL_BODY_B64" | base64 -d)
xui_update_panel_settings "$body" || die "update settings failed"
http_success_json || die "update settings body failed: $(http_body)"
INNER
}

wait_subscription_ready() {
	local url=$1 i
	for i in $(seq 1 45); do
		if docker exec 3x-ui wget -qO- --timeout=2 --header "Host: ${WEBDOMAIN}" "$url" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

restart_panel_for_subscriptions() {
	local url=$1
	docker restart 3x-ui >/dev/null
	wait_subscription_ready "$url" || true
	sleep 2
}

normalize_path() {
	local path=$1
	[[ -n "$path" ]] || return 0
	case "$path" in
		/*) printf '%s' "$path" ;;
		*) printf '/%s' "$path" ;;
	esac
}

join_sub_url_path() {
	local base=$1 id=$2
	case "$base" in
		*/) printf '%s%s' "$base" "$id" ;;
		*) printf '%s/%s' "$base" "$id" ;;
	esac
}

discover_from_panel() {
	local settings=$1
	if [[ -z "$SUB_PORT" || "$SUB_PORT" == "null" ]]; then
		SUB_PORT=$(jq -r '.subPort // empty' <<<"$settings")
	fi
	if [[ -z "$CLASH_PATH" || "$CLASH_PATH" == "null" ]]; then
		CLASH_PATH=$(jq -r '.subClashPath // empty' <<<"$settings")
	fi
	if [[ -z "$JSON_PATH" || "$JSON_PATH" == "null" ]]; then
		JSON_PATH=$(jq -r '.subJsonPath // empty' <<<"$settings")
	fi
	if [[ -z "$WEBDOMAIN" || "$WEBDOMAIN" == "null" ]]; then
		WEBDOMAIN=$(jq -r '.subDomain // empty' <<<"$settings")
	fi
}

discover_sub_id() {
	[[ -n "$SUB_ID" ]] && return 0
	SUB_ID=$(docker exec -i 3x-ui python3 <<'PY'
import json, sqlite3
c = sqlite3.connect("/etc/x-ui/x-ui.db")
for (settings,) in c.execute("SELECT settings FROM inbounds"):
    data = json.loads(settings or "{}")
    for client in data.get("clients") or []:
        sub_id = client.get("subId") or ""
        if sub_id:
            print(sub_id)
            raise SystemExit
PY
)
}

restore_panel_settings() {
	[[ -s "$PANEL_BACKUP" ]] || return 0
	[[ "$RESTORE_DONE" == "0" ]] || return 0
	echo "restore_started=yes"
	if container_apply_panel_settings "$(cat "$PANEL_BACKUP")"; then
		docker restart 3x-ui >/dev/null
		sleep 5
		echo "restore_ok=yes"
		RESTORE_DONE=1
	else
		echo "restore_ok=no"
		return 1
	fi
	local live
	live=$(container_panel_settings)
	jq -c '{subEnableRouting:(.subEnableRouting // null), subRoutingRules:(.subRoutingRules // null)}' <<<"$live" >"$PANEL_AFTER_HAPP"
	if cmp -s "$PANEL_BEFORE_HAPP" "$PANEL_AFTER_HAPP"; then
		echo "happ_routing_untouched=yes"
	else
		echo "happ_routing_untouched=no"
		echo "happ_before=$(cat "$PANEL_BEFORE_HAPP")"
		echo "happ_after=$(cat "$PANEL_AFTER_HAPP")"
	fi
}

cleanup() {
	local status=$?
	if [[ "$RESTORE_DONE" == "0" && -s "$PANEL_BACKUP" ]]; then
		restore_panel_settings || true
	fi
	exit "$status"
}

trap cleanup EXIT

main() {
	load_host_env
	local current probe_yaml probe_json clash_url json_url json_rule
	current=$(container_panel_settings)
	printf '%s' "$current" >"$PANEL_BACKUP"
	jq -c '{subEnableRouting:(.subEnableRouting // null), subRoutingRules:(.subRoutingRules // null)}' <<<"$current" >"$PANEL_BEFORE_HAPP"
	discover_from_panel "$current"
	discover_sub_id

	WEBDOMAIN=${WEBDOMAIN:-streambase.linkpc.net}
	SUB_PORT=${SUB_PORT:?could not discover sub port}
	CLASH_PATH=$(normalize_path "${CLASH_PATH:?could not discover Clash path}")
	JSON_PATH=$(normalize_path "${JSON_PATH:-}")
	SUB_ID=${SUB_ID:?could not discover SUB_ID}

	local probe_host="spike-host.${WEBDOMAIN}"
	local probe_rule="spike-rule.${WEBDOMAIN}"
	local probe_filter="spike-filter.${WEBDOMAIN}"
	local json_probe_domain="spike-json.${WEBDOMAIN}"

	probe_yaml=$(cat <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
  - name: ADMIN
    type: select
    hidden: true
    proxies:
      - PROXY
hosts:
  ${probe_host}: 203.0.113.10
dns:
  fake-ip-filter:
    - ${probe_filter}
rules:
  - DOMAIN,${probe_rule},ADMIN
  - MATCH,PROXY
EOF
)
	json_rule=$(jq -nc --arg d "$json_probe_domain" '{type:"field",domain:[$d],outboundTag:"direct"}')
	probe_json=$(jq -c --arg rules "$probe_yaml" --argjson json_rule "$json_rule" '
		.subClashEnableRouting = (if (.subClashEnableRouting | type) == "boolean" then true else "true" end)
		| .subClashRules = $rules
		| .subJsonRoutingRules = (
			if (.subJsonRoutingRules | type) == "array" then [$json_rule]
			else ([$json_rule] | tojson)
			end
		)
	' <<<"$current")

	echo "WEBDOMAIN=${WEBDOMAIN}"
	echo "SUB_PORT=${SUB_PORT}"
	echo "CLASH_PATH=${CLASH_PATH}"
	echo "JSON_PATH=${JSON_PATH}"
	echo "SUB_ID=${SUB_ID}"

	clash_url=$(join_sub_url_path "$CLASH_PATH" "$SUB_ID")
	container_apply_panel_settings "$probe_json"
	local live
	live=$(container_panel_settings)
	echo "stored_enable=$(jq -r '.subClashEnableRouting' <<<"$live")"
	echo "stored_rules_has_spike=$(jq -r --arg rule "$probe_rule" '(.subClashRules // "") | contains($rule)' <<<"$live")"
	restart_panel_for_subscriptions "http://127.0.0.1:${SUB_PORT}${clash_url}"

	docker exec 3x-ui wget -qO- --header "Host: ${WEBDOMAIN}" "http://127.0.0.1:${SUB_PORT}${clash_url}" \
		| tee "$CLASH_OUT" >/dev/null

	grep -Fq "DOMAIN,${probe_rule},ADMIN" "$CLASH_OUT" && echo merge_rules=yes || echo merge_rules=no
	grep -Fq "name: ADMIN" "$CLASH_OUT" && echo merge_proxy_groups=yes || echo merge_proxy_groups=no
	grep -Fq "hidden: true" "$CLASH_OUT" && echo supports_hidden_admin=yes || echo supports_hidden_admin=no
	grep -Fq "${probe_host}" "$CLASH_OUT" && echo merge_hosts=yes || echo merge_hosts=no
	grep -Fq "${probe_filter}" "$CLASH_OUT" && echo merge_dns=yes || echo merge_dns=no
	if grep -A20 'name: PROXY' "$CLASH_OUT" | grep -Eqi 'vless|hysteria|reality|xhttp'; then
		echo preserves_proxy_node_list=yes
	else
		echo preserves_proxy_node_list=no
	fi

	if [[ -n "$JSON_PATH" ]]; then
		json_url=$(join_sub_url_path "$JSON_PATH" "$SUB_ID")
		if docker exec 3x-ui wget -qO- --header "Host: ${WEBDOMAIN}" "http://127.0.0.1:${SUB_PORT}${json_url}" \
			| tee "$JSON_OUT" >/dev/null; then
			grep -Fq "$json_probe_domain" "$JSON_OUT" && echo json_routing_effective=yes || echo json_routing_effective=no
		else
			echo json_routing_effective=no
		fi
	else
		echo json_routing_effective=no
	fi

	restore_panel_settings
}

main "$@"
