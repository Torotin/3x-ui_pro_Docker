#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@"
fi
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR=${LIB_DIR:-"$SCRIPT_DIR/../lib"}
if [[ ! -f "$LIB_DIR/log.bash" && -f /mnt/sh/lib/log.bash ]]; then
	LIB_DIR=/mnt/sh/lib
fi
TMP_ROOT=
CHANGE_COUNT=0
RESTART_PANEL_REQUIRED=0
RESTART_XRAY_REQUIRED=0
ENSURE_INBOUND_ID=

# shellcheck source=../lib/log.bash
. "$LIB_DIR/log.bash"
# shellcheck source=../lib/env.bash
. "$LIB_DIR/env.bash"
# shellcheck source=../lib/http.bash
. "$LIB_DIR/http.bash"
# shellcheck source=../lib/3xui_api.bash
. "$LIB_DIR/3xui_api.bash"
# shellcheck source=../lib/json_state.bash
. "$LIB_DIR/json_state.bash"
# shellcheck source=../lib/desired_state.bash
. "$LIB_DIR/desired_state.bash"

cleanup() {
	[[ -n "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

record_change() {
	CHANGE_COUNT=$((CHANGE_COUNT + 1))
	log INFO "$*"
}

plan_or_apply() {
	local message=$1
	if [[ "$MODE" == "plan" ]]; then
		record_change "PLAN: $message"
		return 1
	fi
	record_change "APPLY: $message"
	return 0
}

body_json() {
	http_body | jq -c .
}

api_obj_json() {
	jq -c '.obj // {}' "$HTTP_BODY_FILE"
}

panel_settings_args() {
	local current=$1 var env_val value args=()
	while IFS= read -r var; do
		env_val=${!var-}
		if [[ -n "$env_val" ]]; then
			value=$env_val
		else
			value=$(jq -r --arg key "$var" 'if .[$key] == null then "" else .[$key] end' <<<"$current")
		fi
		args+=(--data-urlencode "$var=$value")
	done < <(desired_panel_keys)
	printf '%s\0' "${args[@]}"
}

panel_desired_json() {
	local current=$1 var env_val value desired='{}'
	while IFS= read -r var; do
		env_val=${!var-}
		if [[ -n "$env_val" ]]; then
			value=$env_val
		else
			value=$(jq -r --arg key "$var" 'if .[$key] == null then "" else .[$key] end' <<<"$current")
		fi
		desired=$(jq -c --arg key "$var" --arg value "$value" '.[$key] = $value' <<<"$desired")
	done < <(desired_panel_keys)
	printf '%s' "$desired"
}

panel_current_managed_json() {
	local current=$1 var value projected='{}'
	while IFS= read -r var; do
		value=$(jq -r --arg key "$var" 'if .[$key] == null then "" else (.[$key]|tostring) end' <<<"$current")
		projected=$(jq -c --arg key "$var" --arg value "$value" '.[$key] = $value' <<<"$projected")
	done < <(desired_panel_keys)
	printf '%s' "$projected"
}

ensure_panel_settings() {
	local current current_projected desired args
	xui_get_panel_settings || die "Failed to read panel settings."
	http_success_json || die "Panel settings API failed: $(http_body)"
	current=$(api_obj_json)
	desired=$(panel_desired_json "$current")
	current_projected=$(panel_current_managed_json "$current")
	if json_equal "$current_projected" "$desired"; then
		log INFO "Panel settings already match desired state."
		return 0
	fi
	mapfile -d '' -t args < <(panel_settings_args "$current")

	if plan_or_apply "panel settings updated"; then
		xui_update_panel_settings "${args[@]}" || die "Failed to update panel settings."
		http_success_json || die "Panel settings update failed: $(http_body)"
		RESTART_PANEL_REQUIRED=1
	fi
}

update_admin_credentials_if_needed() {
	[[ -n "$NEW_ADMIN_USERNAME" && -n "$NEW_ADMIN_PASSWORD" ]] || {
		log INFO "Admin credential update skipped."
		return 0
	}
	if [[ "$USERNAME" == "$NEW_ADMIN_USERNAME" && "$PASSWORD" == "$NEW_ADMIN_PASSWORD" ]]; then
		log INFO "Admin credentials already match desired state."
		return 0
	fi
	if plan_or_apply "admin credentials updated"; then
		xui_update_admin_credentials || die "Failed to update admin credentials."
		http_success_json || die "Admin credential update failed: $(http_body)"
		USERNAME=$NEW_ADMIN_USERNAME
		PASSWORD=$NEW_ADMIN_PASSWORD
		export USERNAME PASSWORD
	fi
}

custom_geo_list_json() {
	xui_custom_geo_list || die "Failed to list custom geo resources."
	http_success_json || die "Custom geo list API failed: $(http_body)"
	jq -c '.obj // []' "$HTTP_BODY_FILE"
}

ensure_custom_geo_resources() {
	local desired existing count index type alias url match id current_url
	[[ "$CUSTOM_GEO_API_ENABLED" == "true" ]] || {
		log INFO "Custom geo API management skipped."
		return 0
	}

	desired=$(custom_geo_resources_json)
	count=$(jq 'length' <<<"$desired")
	if ((count == 0)); then
		log INFO "Custom geo API management skipped: no resources configured."
		return 0
	fi

	existing=$(custom_geo_list_json)
	for ((index = 0; index < count; index++)); do
		type=$(jq -r ".[$index].type" <<<"$desired")
		alias=$(jq -r ".[$index].alias" <<<"$desired")
		url=$(jq -r ".[$index].url" <<<"$desired")
		match=$(jq -c --arg type "$type" --arg alias "$alias" '.[] | select(.type == $type and .alias == $alias)' <<<"$existing" | head -n1)
		if [[ -n "$match" ]]; then
			id=$(jq -r '.id' <<<"$match")
			current_url=$(jq -r '.url // ""' <<<"$match")
			if [[ "$current_url" == "$url" ]]; then
				log INFO "custom geo already exists type=$type alias=$alias id=$id."
				continue
			fi
			if plan_or_apply "custom geo updated type=$type alias=$alias"; then
				xui_custom_geo_update "$id" "$type" "$alias" "$url" || die "Failed to update custom geo alias=$alias."
				http_success_json || die "Custom geo update failed alias=$alias: $(http_body)"
			fi
		else
			if plan_or_apply "custom geo added type=$type alias=$alias"; then
				xui_custom_geo_add "$type" "$alias" "$url" || die "Failed to add custom geo alias=$alias."
				http_success_json || die "Custom geo add failed alias=$alias: $(http_body)"
			fi
		fi
	done

	if [[ "$MODE" == "apply" && "$CUSTOM_GEO_UPDATE_ALL_ON_START" == "true" ]]; then
		xui_custom_geo_update_all || die "Failed to update all custom geo resources."
		http_success_json || die "Custom geo update-all failed: $(http_body)"
		log INFO "Custom geo resources refreshed through panel API."
	elif [[ "$MODE" == "plan" && "$CUSTOM_GEO_UPDATE_ALL_ON_START" == "true" ]]; then
		log INFO "PLAN: custom geo update-all would be requested."
	fi
}

update_builtin_geofiles_if_enabled() {
	[[ "$GEOFILES_UPDATE_ON_START" == "true" ]] || {
		log INFO "Built-in geofile update skipped."
		return 0
	}
	if [[ "$MODE" == "plan" ]]; then
		log INFO "PLAN: built-in geofile update-all would be requested."
		return 0
	fi
	xui_update_geofiles || die "Failed to request built-in geofile update."
	http_success_json || die "Built-in geofile update failed: $(http_body)"
	log INFO "Built-in geoip/geosite files refreshed through panel API."
}

inbounds_json() {
	xui_list_inbounds || die "Failed to list inbounds."
	http_success_json || die "Inbound list API failed: $(http_body)"
	jq -c '.obj // []' "$HTTP_BODY_FILE"
}

find_inbound_by_port() {
	local inbounds=$1 port=$2 protocol=$3
	jq -r --argjson port "$port" --arg protocol "$protocol" '
      .[] | select((.port|tonumber) == $port and .protocol == $protocol) | .id
    ' <<<"$inbounds" | head -n1
}

find_client_id() {
	local inbound=$1 email=$2 sub_id=$3
	jq -r --arg email "$email" --arg subId "$sub_id" '
      (.settings | fromjson? // {} | .clients // [])
      | .[]
      | select(.email == $email or .subId == $subId)
      | .id
    ' <<<"$inbound" | head -n1
}

managed_conflict_check() {
	local inbound=$1 expected_remark=$2 port=$3
	[[ -n "$inbound" && "$inbound" != "null" ]] || return 0
	local remark
	remark=$(jq -r '.remark // ""' <<<"$inbound")
	if [[ "$remark" != "$expected_remark" && "$remark" != *"$expected_remark"* ]]; then
		die "Inbound port $port is occupied by unmanaged inbound remark='$remark'. Refusing to overwrite."
	fi
}

new_uuid() {
	if [[ -r /proc/sys/kernel/random/uuid ]]; then
		cat /proc/sys/kernel/random/uuid
	else
		jq -nr 'now|tostring|@base64' | sha256sum | cut -c1-32
	fi
}

generate_short_ids_json() {
	local count=${1:-8} max_bytes=${2:-8} ids='[]' raw len hex i
	for ((i = 0; i < count; i++)); do
		raw=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ' || printf '4')
		len=$((2 + raw % (max_bytes - 1)))
		if command -v openssl >/dev/null 2>&1; then
			hex=$(openssl rand -hex "$len" 2>/dev/null)
		else
			hex=$(head -c "$len" /dev/urandom | od -An -vtx1 | tr -d ' \n')
		fi
		ids=$(jq -c --arg id "$hex" '. + [$id]' <<<"$ids")
	done
	printf '%s' "$ids"
}

find_xray_bin() {
	local candidate arch_name
	case "$(uname -m)" in
	x86_64) arch_name=amd64 ;;
	aarch64) arch_name=arm64 ;;
	armv7l) arch_name=arm ;;
	*) arch_name=amd64 ;;
	esac
	for candidate in \
		"${XRAY_BIN_PATH:-}" \
		"${XUI_BIN_FOLDER:-/app/bin}/xray-linux-$arch_name" \
		"${XUI_BIN_FOLDER:-/app/bin}/xray" \
		"$(command -v xray 2>/dev/null || true)"; do
		[[ -n "$candidate" && -x "$candidate" ]] && {
			printf '%s' "$candidate"
			return 0
		}
	done
	return 1
}

generate_wg_keys() {
	local xray_bin output hash decoded b1 b2 b3
	xray_bin=$(find_xray_bin) || die "Failed to find xray binary for WARP registration."
	output=$("$xray_bin" wg 2>/dev/null) || die "Failed to run xray wg for WARP registration."
	WG_PRIVATE_KEY=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$output" | head -n1)
	WG_PUBLIC_KEY=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$output" | head -n1)
	[[ -n "$WG_PUBLIC_KEY" ]] || WG_PUBLIC_KEY=$(awk -F': ' '/Password/ {print $2}' <<<"$output" | head -n1)
	hash=$(awk -F': ' '/Hash32/ {print $2}' <<<"$output" | head -n1)
	WG_RESERVED_JSON='[10,14,188]'
	if [[ -n "$hash" ]]; then
		decoded=$(printf '%s' "$hash" | base64 -d 2>/dev/null | head -c 3 || true)
		if [[ -n "$decoded" ]]; then
			read -r b1 b2 b3 < <(printf '%s' "$decoded" | od -An -tu1 | tr -s ' ' | sed 's/^ //')
			if [[ -n "${b1:-}" && -n "${b2:-}" && -n "${b3:-}" ]]; then
				WG_RESERVED_JSON="[$b1,$b2,$b3]"
			fi
		fi
	fi
	[[ -n "$WG_PRIVATE_KEY" && -n "$WG_PUBLIC_KEY" ]] || die "xray wg did not return WARP keys."
}

extract_warp_obj() {
	local file=$1
	jq -cr 'try (.obj | fromjson) catch (.obj // empty)' "$file"
}

warp_config_json_from_obj() {
	local obj=$1
	jq -c '.config.config // .config // {}' <<<"$obj"
}

ensure_warp_console_outbound() {
	local current=$1 existing obj config outbound private_key
	existing=$(jq -c '.xraySetting.outbounds[]? | select(.tag=="warp" and .protocol=="wireguard")' <<<"$current" | head -n1)
	if [[ -n "$existing" ]]; then
		xui_warp_config || true
		if http_success_json; then
			obj=$(extract_warp_obj "$HTTP_BODY_FILE")
			if [[ -n "$obj" && "$obj" != "null" ]]; then
				config=$(warp_config_json_from_obj "$obj")
				private_key=$(jq -r '.settings.secretKey // empty' <<<"$existing")
				if [[ -n "$private_key" ]] && outbound=$(warp_outbound_from_config "$config" "$private_key"); then
					printf '%s' "$outbound"
					return 0
				fi
			fi
		fi
		normalize_warp_outbound_endpoint "$existing"
		return 0
	fi
	if [[ "$WARP_REUSE_PANEL_CONFIG" == "true" ]]; then
		xui_warp_config || true
		if http_success_json; then
			obj=$(extract_warp_obj "$HTTP_BODY_FILE")
			if [[ -n "$obj" && "$obj" != "null" ]]; then
				config=$(warp_config_json_from_obj "$obj")
				private_key=$(jq -r '.interface.private_key // .config.interface.private_key // .privateKey // empty' <<<"$config")
				if [[ -n "$private_key" ]] && outbound=$(warp_outbound_from_config "$config" "$private_key"); then
					printf '%s' "$outbound"
					return 0
				fi
			fi
		fi
	fi
	if [[ "$MODE" == "plan" ]]; then
		log INFO "PLAN: WARP console registration would be requested."
		return 1
	fi
	generate_wg_keys
	xui_warp_register "$WG_PUBLIC_KEY" "$WG_PRIVATE_KEY" || die "Failed to register WARP through panel API."
	http_success_json || die "WARP registration API failed: $(http_body)"
	obj=$(extract_warp_obj "$HTTP_BODY_FILE")
	[[ -n "$obj" && "$obj" != "null" ]] || die "WARP registration response has no obj."
	config=$(warp_config_json_from_obj "$obj")
	outbound=$(warp_outbound_from_config "$config" "$WG_PRIVATE_KEY" "$WG_RESERVED_JSON") || die "Failed to build WARP outbound from registration response."
	log INFO "WARP registered through panel API."
	printf '%s' "$outbound"
}

get_vless_auth() {
	if [[ "$USE_VLESS_PQ" != "true" ]]; then
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_DEC=none
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_ENC=none
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_LABEL=
		return 0
	fi
	xui_get_vless_enc || return 1
	if http_success_json; then
		local picked
		picked=$(jq -c '.obj.auths[]? | select((.label // "" | ascii_downcase | contains("post-quantum")) or (.label // "" | ascii_downcase | contains("ml-kem"))) // empty' "$HTTP_BODY_FILE" | head -n1)
		[[ -n "$picked" ]] || picked=$(jq -c '.obj.auths[0] // empty' "$HTTP_BODY_FILE")
		VLESS_DEC=$(jq -r '.decryption // "none"' <<<"$picked")
		VLESS_ENC=$(jq -r '.encryption // "none"' <<<"$picked")
		VLESS_LABEL=$(jq -r '.label // ""' <<<"$picked")
	else
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_DEC=none
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_ENC=none
		# shellcheck disable=SC2034 # consumed by build_vless_settings_json from desired_state.bash
		VLESS_LABEL=
		log WARN "VLESS auth API failed; falling back to none."
	fi
}

get_x25519_keys() {
	xui_get_x25519 || return 1
	http_success_json || return 1
	X25519_PRIVATE_KEY=$(jq -r '.obj.privateKey // empty' "$HTTP_BODY_FILE")
	X25519_PUBLIC_KEY=$(jq -r '.obj.publicKey // empty' "$HTTP_BODY_FILE")
	[[ -n "$X25519_PRIVATE_KEY" && -n "$X25519_PUBLIC_KEY" ]]
}

build_inbound_stream_json() {
	local kind=$1 current=${2:-}
	if [[ -n "$current" && "$current" != "null" && "$kind" == "vision" ]]; then
		json_field_object "$current" streamSettings
		return 0
	fi

	if [[ "$kind" == "vision" ]]; then
		get_x25519_keys || die "Failed to get X25519 keys for Vision inbound."
		build_vision_stream_json "traefik:$PORT_LOCAL_TRAEFIK" "$WEBDOMAIN" "$X25519_PRIVATE_KEY" "$X25519_PUBLIC_KEY" "$(generate_short_ids_json 8 8)" "$(build_sockopt_json false AsIs off)" "" ""
	else
		build_xhttp_stream_json "$URI_VLESS_XHTTP" "$WEBDOMAIN"
	fi
}

build_inbound_components_json() {
	local kind=$1 desired=$2 current=${3:-}
	local settings stream sniffing allocate port remark protocol
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	remark=$(jq -r ".inbounds.$kind.remark" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	settings=$(build_vless_settings_json "$kind" "$current")
	stream=$(build_inbound_stream_json "$kind" "$current")
	sniffing=$(jq -nc '{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false}')
	allocate=$(jq -nc '{}')
	jq -nc \
		--argjson port "$port" \
		--arg remark "$remark" \
		--arg protocol "$protocol" \
		--argjson settings "$settings" \
		--argjson stream "$stream" \
		--argjson sniffing "$sniffing" \
		--argjson allocate "$allocate" '{
          up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
          listen:"", port:$port, protocol:$protocol, settings:$settings,
          streamSettings:$stream, sniffing:$sniffing, allocate:$allocate
        }'
}

inbound_components_payload() {
	local components=$1
	printf '%s\0' \
		--data-urlencode "up=0" \
		--data-urlencode "down=0" \
		--data-urlencode "total=0" \
		--data-urlencode "remark=$(jq -r '.remark' <<<"$components")" \
		--data-urlencode "enable=true" \
		--data-urlencode "expiryTime=0" \
		--data-urlencode "listen=" \
		--data-urlencode "port=$(jq -r '.port' <<<"$components")" \
		--data-urlencode "protocol=$(jq -r '.protocol' <<<"$components")" \
		--data-urlencode "settings=$(jq -c '.settings' <<<"$components")" \
		--data-urlencode "streamSettings=$(jq -c '.streamSettings' <<<"$components")" \
		--data-urlencode "sniffing=$(jq -c '.sniffing' <<<"$components")" \
		--data-urlencode "allocate=$(jq -c '.allocate' <<<"$components")"
}

current_inbound_components_json() {
	local inbound=$1
	jq -c '{
      up:(.up // 0),
      down:(.down // 0),
      total:(.total // 0),
      remark:(.remark // ""),
      enable:(.enable // true),
      expiryTime:(.expiryTime // 0),
      listen:(.listen // ""),
      port:(.port|tonumber),
      protocol:(.protocol // ""),
      settings:(.settings | fromjson? // . // {}),
      streamSettings:(.streamSettings | fromjson? // . // {}),
      sniffing:(.sniffing | fromjson? // . // {}),
      allocate:(.allocate | fromjson? // . // {})
    }' <<<"$inbound"
}

ensure_inbound() {
	local kind=$1 desired=$2 inbounds id port protocol remark inbound args desired_components current_components
	ENSURE_INBOUND_ID=
	inbounds=$(inbounds_json)
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	remark=$(jq -r ".inbounds.$kind.remark" <<<"$desired")
	id=$(find_inbound_by_port "$inbounds" "$port" "$protocol")
	inbound=$(jq -c --arg id "$id" '.[] | select((.id|tostring)==$id)' <<<"$inbounds" | head -n1)
	managed_conflict_check "$inbound" "$remark" "$port"

	if [[ -n "$id" ]]; then
		desired_components=$(build_inbound_components_json "$kind" "$desired" "$inbound")
		current_components=$(current_inbound_components_json "$inbound")
		if json_equal "$current_components" "$desired_components"; then
			log INFO "$kind inbound already exists id=$id port=$port."
		elif plan_or_apply "$kind inbound updated id=$id port=$port"; then
			mapfile -d '' -t args < <(inbound_components_payload "$desired_components")
			xui_update_inbound "$id" "${args[@]}" || die "Failed to update $kind inbound."
			http_success_json || die "$kind inbound update failed: $(http_body)"
			RESTART_XRAY_REQUIRED=1
		fi
		ENSURE_INBOUND_ID=$id
	else
		desired_components=$(build_inbound_components_json "$kind" "$desired")
		mapfile -d '' -t args < <(inbound_components_payload "$desired_components")
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: $kind inbound created port=$port"
			return 0
		fi
		record_change "APPLY: $kind inbound created port=$port"
		xui_add_inbound "${args[@]}" || die "Failed to add $kind inbound."
		http_success_json || die "$kind inbound add failed: $(http_body)"
		RESTART_XRAY_REQUIRED=1
		ENSURE_INBOUND_ID=$(jq -r '.obj.id // empty' "$HTTP_BODY_FILE")
	fi
}

client_settings_json() {
	local inbound=$1 client_id=$2 email=$3 sub_id=$4 flow=$5
	local existing
	existing=$(jq -c '.settings | fromjson? // {}' <<<"$inbound")
	jq -c --arg id "$client_id" --arg email "$email" --arg sid "$sub_id" --arg flow "$flow" '
      .clients = ((.clients // []) | map(select(.email != $email and .subId != $sid)) + [{
        id:$id, flow:$flow, email:$email, limitIp:0, totalGB:0, expiryTime:0,
        enable:true, tgId:"", subId:$sid, comment:"", reset:0
      }])
    ' <<<"$existing"
}

ensure_client() {
	local kind=$1 inbound_id=$2 desired=$3 inbounds inbound email sub_id flow existing_client client_id settings current_client current_flow
	[[ -n "$inbound_id" ]] || {
		log INFO "$kind client skipped in plan mode because inbound id is not available."
		return 0
	}
	inbounds=$(inbounds_json)
	inbound=$(jq -c --arg id "$inbound_id" '.[] | select((.id|tostring)==$id)' <<<"$inbounds" | head -n1)
	email=$(jq -r ".clients.$kind.email" <<<"$desired")
	sub_id=$(jq -r ".clients.$kind.subId" <<<"$desired")
	flow=$(jq -r ".clients.$kind.flow" <<<"$desired")
	existing_client=$(find_client_id "$inbound" "$email" "$sub_id")
	client_id=${existing_client:-$(new_uuid)}
	settings=$(client_settings_json "$inbound" "$client_id" "$email" "$sub_id" "$flow")
	if [[ -n "$existing_client" ]]; then
		current_client=$(jq -c --arg id "$client_id" '(.settings | fromjson? // {} | .clients // [])[] | select(.id == $id)' <<<"$inbound" | head -n1)
		current_flow=$(jq -r '.flow // ""' <<<"$current_client")
		if [[ "$current_flow" == "$flow" ]]; then
			log INFO "$kind client already exists email=$email."
			return 0
		fi
		if plan_or_apply "$kind client updated email=$email"; then
			xui_update_client "$client_id" --data-urlencode "id=$inbound_id" --data-urlencode "settings=$settings" || die "Failed to update $kind client."
			http_success_json || die "$kind client update failed: $(http_body)"
		fi
	else
		if plan_or_apply "$kind client created email=$email"; then
			xui_add_client --data-urlencode "id=$inbound_id" --data-urlencode "settings=$settings" || die "Failed to add $kind client."
			http_success_json || die "$kind client add failed: $(http_body)"
		fi
	fi
}

available_dns_servers() {
	local servers='[]'
	if command -v nc >/dev/null 2>&1 && nc -z -w2 adguard 53 2>/dev/null; then
		jq -nc '[{address:"adguard",port:53,skipFallback:false}]'
		return 0
	fi
	local candidates=(
		"https://dns10.quad9.net/dns-query"
		"https://dns.alidns.com/dns-query"
		"https://doh.sandbox.opendns.com/dns-query"
		"https://freedns.controld.com/p0"
		"https://doh.dns.sb/dns-query"
		"https://dns.google/dns-query"
		"https://dns.nextdns.io"
		"https://dns.quad9.net/dns-query"
		"https://dns11.quad9.net/dns-query"
		"https://dns.rabbitdns.org/dns-query"
		"https://basic.rethinkdns.com/"
		"https://wikimedia-dns.org/dns-query"
		"https://doh.libredns.gr/dns-query"
		"https://doh.libredns.gr/ads"
		"https://dns.twnic.tw/dns-query"
		"https://dns.switch.ch/dns-query"
		"tls://dns.alidns.com"
		"tls://sandbox.opendns.com"
		"tls://p0.freedns.controld.com"
		"tls://dot.sb"
		"tls://dns.google"
		"tls://dns.mullvad.net"
		"tls://dns.nextdns.io"
		"tls://dns.quad9.net"
		"tls://dns11.quad9.net"
		"tls://dot.libredns.gr"
	)
	local server
	for server in "${candidates[@]}"; do
		servers=$(jq -c --arg address "$server" '. + [{address:$address,skipFallback:false}]' <<<"$servers")
	done
	printf '%s' "$servers"
}

endpoint_available() {
	local host=$1 port=$2
	command -v nc >/dev/null 2>&1 || return 1
	nc -z -w2 "$host" "$port" >/dev/null 2>&1
}

apply_managed_xray() {
	local raw obj current updated dns_servers tmp_file warp_socks_available=false tor_available=false tor_endpoints='[]' warp_console_ob=
	if [[ "$XRAY_MANAGED_DNS" != "true" && "$XRAY_MANAGED_TOR" != "true" && "$XRAY_MANAGED_WARP" != "true" ]]; then
		cleanup_managed_xray_artifacts
		return 0
	fi

	xui_get_xray_settings || die "Failed to get Xray settings."
	http_success_json || die "Xray settings API failed: $(http_body)"
	raw=$(jq -r '.obj // empty' "$HTTP_BODY_FILE")
	[[ -n "$raw" ]] || die "Xray response obj is empty."
	current=$(jq -c . <<<"$raw")

	if [[ "$XRAY_MANAGED_WARP" == "true" && "$XRAY_MANAGED_WARP_CONSOLE" == "true" ]]; then
		warp_console_ob=$(ensure_warp_console_outbound "$current" || true)
	elif [[ "$XRAY_MANAGED_WARP" == "true" ]]; then
		log INFO "Console WARP outbound is disabled; managed WARP balancer will use external SOCKS outbounds only."
	fi
	if [[ "$XRAY_MANAGED_WARP" == "true" ]]; then
		if endpoint_available warp 1080; then
			warp_socks_available=true
		else
			log WARN "warp:1080 is unavailable; keeping warp-docker in WARP balancer desired state."
		fi
	fi
	updated=$(json_remove_managed_xray_artifacts "$current")
	if [[ "$XRAY_MANAGED_TOR" == "true" ]]; then
		tor_available=true
		tor_endpoints=$(jq -c --arg tag "tor-proxy" --arg host "$TOR_PROXY_HOST" --argjson port "$TOR_PROXY_PORT" '. + [{tag:$tag,host:$host,port:$port}]' <<<"$tor_endpoints")
		tor_endpoints=$(jq -c --arg tag "torproxy" --arg host "$TOR_PROXY_ALT_HOST" --argjson port "$TOR_PROXY_ALT_PORT" '. + [{tag:$tag,host:$host,port:$port}]' <<<"$tor_endpoints")
		if endpoint_available "$TOR_PROXY_HOST" "$TOR_PROXY_PORT"; then
			log DEBUG "$TOR_PROXY_HOST:$TOR_PROXY_PORT is available."
		else
			log WARN "$TOR_PROXY_HOST:$TOR_PROXY_PORT is unavailable; keeping it in TOR balancer desired state."
		fi
		if endpoint_available "$TOR_PROXY_ALT_HOST" "$TOR_PROXY_ALT_PORT"; then
			log DEBUG "$TOR_PROXY_ALT_HOST:$TOR_PROXY_ALT_PORT is available."
		else
			log WARN "$TOR_PROXY_ALT_HOST:$TOR_PROXY_ALT_PORT is unavailable; keeping it in TOR balancer desired state."
		fi
	fi
	dns_servers=$(available_dns_servers)
	updated=$(json_apply_managed_xray_state "$updated" "$dns_servers" "$XRAY_MANAGED_WARP" "$tor_available" "$XRAY_MANAGED_DNS" "$warp_socks_available" "$WEBDOMAIN" "$tor_endpoints" "$warp_console_ob")

	if json_equal "$current" "$updated"; then
		log INFO "Xray settings already match managed desired state."
		return 0
	fi

	if plan_or_apply "xray settings updated"; then
		obj=$(jq -c '.xraySetting | .xrayTemplateConfig = (.xrayTemplateConfig // {})' <<<"$updated")
		tmp_file="$TMP_ROOT/xraysetting.json"
		printf '%s' "$obj" >"$tmp_file"
		xui_update_xray_settings "$tmp_file" || die "Failed to update Xray settings."
		http_success_json || die "Xray update failed: $(http_body)"
		RESTART_PANEL_REQUIRED=1
	fi
}

cleanup_managed_xray_artifacts() {
	local raw current updated obj tmp_file
	xui_get_xray_settings || {
		log WARN "Managed Xray cleanup skipped: failed to read Xray settings."
		return 0
	}
	http_success_json || {
		log WARN "Managed Xray cleanup skipped: API returned failure."
		return 0
	}
	raw=$(jq -r '.obj // empty' "$HTTP_BODY_FILE")
	[[ -n "$raw" ]] || {
		log INFO "Managed Xray cleanup skipped: empty Xray settings."
		return 0
	}
	current=$(jq -c . <<<"$raw")
	updated=$(json_remove_managed_xray_artifacts "$current")
	if json_equal "$current" "$updated"; then
		log INFO "Managed Xray template update skipped; no old managed artifacts found."
		return 0
	fi
	if plan_or_apply "old managed xray artifacts removed"; then
		obj=$(jq -c '.xraySetting | .xrayTemplateConfig = (.xrayTemplateConfig // {})' <<<"$updated")
		tmp_file="$TMP_ROOT/xraysetting-cleanup.json"
		printf '%s' "$obj" >"$tmp_file"
		xui_update_xray_settings "$tmp_file" || die "Failed to cleanup managed Xray settings."
		http_success_json || die "Managed Xray cleanup failed: $(http_body)"
		RESTART_PANEL_REQUIRED=1
	fi
}

wait_tcp_port() {
	local host=$1 port=$2 timeout=${3:-30} elapsed=0 label
	label=${4:-"$host:$port"}
	while ((elapsed < timeout)); do
		if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
			exec 3<&-
			exec 3>&-
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	log WARN "Timed out waiting for $label after ${timeout}s."
	return 1
}

wait_managed_xray_ports() {
	local timeout=${XRAY_RESTART_PORT_TIMEOUT:-30} failed=0
	wait_tcp_port 127.0.0.1 "$PORT_LOCAL_VISION" "$timeout" "Vision inbound ${PORT_LOCAL_VISION}" || failed=1
	wait_tcp_port 127.0.0.1 "$PORT_LOCAL_XHTTP" "$timeout" "XHTTP inbound ${PORT_LOCAL_XHTTP}" || failed=1
	return "$failed"
}

restart_if_needed() {
	local restart_sent=0
	if [[ "$MODE" != "apply" ]]; then
		log INFO "Restart skipped in MODE=$MODE."
		return 0
	fi
	if ((RESTART_PANEL_REQUIRED == 1)); then
		xui_restart_panel || log WARN "Panel restart request failed: $(http_body)"
		restart_sent=1
	elif ((RESTART_XRAY_REQUIRED == 1)); then
		xui_restart_xray || log WARN "Xray restart request failed: $(http_body)"
		restart_sent=1
	fi
	if ((restart_sent == 1)); then
		sleep "${XRAY_RESTART_SETTLE_SECONDS:-5}"
		wait_managed_xray_ports || log WARN "One or more managed Xray inbounds are not listening after restart."
	fi
}

main() {
	local desired vision_id xhttp_id
	TMP_ROOT=$(mktemp -d)
	http_init "$TMP_ROOT"
	load_runtime_env "$SCRIPT_DIR"
	require_apply_mode
	check_dependencies
	log INFO "3x-ui managed runtime started MODE=$MODE"

	if [[ "$MODE" == "check" ]]; then
		log INFO "Dependency and environment check passed."
		return 0
	fi

	resolve_panel_base || die "Could not resolve and login to 3x-ui panel."
	desired=$(build_desired_state)
	ensure_panel_settings
	update_admin_credentials_if_needed
	resolve_panel_base || die "Could not login after panel settings update."
	ensure_custom_geo_resources
	update_builtin_geofiles_if_enabled

	ensure_inbound vision "$desired"
	vision_id=$ENSURE_INBOUND_ID
	ensure_inbound xhttp "$desired"
	xhttp_id=$ENSURE_INBOUND_ID
	ensure_client vision "$vision_id" "$desired"
	ensure_client xhttp "$xhttp_id" "$desired"
	apply_managed_xray
	restart_if_needed
	log INFO "3x-ui managed runtime complete: changes=$CHANGE_COUNT panel_restart=$RESTART_PANEL_REQUIRED xray_restart=$RESTART_XRAY_REQUIRED"
}

main "$@"
