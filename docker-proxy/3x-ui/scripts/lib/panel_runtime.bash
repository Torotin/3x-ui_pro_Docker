#!/usr/bin/env bash

# Строит полный объект AllSetting для POST /panel/api/setting/update (3.7 JSON).
# 3x-ui 3.5+ validates the complete settings blob; partial updates fail validation.
# Overlay env onto AllSetting while preserving JSON types required by 3.7 (webPort int, flags bool).
panel_settings_json() {
	local current=$1 var env_val merged
	merged=$current
	while IFS= read -r var; do
		env_val=${!var-}
		[[ -n "$env_val" ]] || continue
		# Skip keys AllSetting exposes as null (retired on newer panels); overlay never persists.
		if jq -e --arg key "$var" '.[$key] == null' <<<"$merged" >/dev/null; then
			continue
		fi
		merged=$(jq -c --arg key "$var" --arg value "$env_val" '
          .[$key] = (
            if (.[$key] | type) == "number" then ($value | tonumber)
            elif (.[$key] | type) == "boolean" then (
              ($value | ascii_downcase) as $v
              | ($v == "true" or $v == "1" or $v == "yes" or $v == "on")
            )
            else $value
            end
          )
        ' <<<"$merged")
	done < <(desired_panel_keys)
	# 3x-ui 3.7+ rejects smtpPort/ldapPort < 1 (zod min). Keep schema-valid placeholders when unused.
	merged=$(jq -c '
		if ((.smtpPort|tostring|tonumber?) // 0) < 1 then .smtpPort = 587 else . end
		| if ((.ldapPort|tostring|tonumber?) // 0) < 1 then .ldapPort = 389 else . end
	' <<<"$merged")
	if [[ -z "${panelOutbound:-}" ]]; then
		# Prefer direct: RU/local subscription hosts are reachable without WARP,
		# while panelOutbound=usque breaks outbound-sub refresh / geofile egress bridge races.
		# Empty env must force direct even when DB still has usque.
		merged=$(jq -c '.panelOutbound = "direct"' <<<"$merged")
	fi
	printf '%s' "$merged"
}

clear_sub_json_routing_rules_requested() {
	[[ "${CLEAR_SUB_JSON_ROUTING_RULES:-false}" == "true" ]]
}

# Строит сравнимый JSON желаемых настроек панели из окружения и текущего состояния.
panel_desired_json() {
	local current=$1 var env_val value desired='{}'
	while IFS= read -r var; do
		env_val=${!var-}
		current_null=$(jq -r --arg key "$var" 'if .[$key] == null then "1" else "0" end' <<<"$current")
		if [[ -n "$env_val" && "$current_null" != "1" ]]; then
			# Strip a single trailing newline so Clash/YAML builders match AllSetting.
			value=${env_val%$'\n'}
		else
			value=$(jq -r --arg key "$var" 'if .[$key] == null then "" else .[$key] end' <<<"$current")
		fi
		desired=$(jq -c --arg key "$var" --arg value "$value" '.[$key] = $value' <<<"$desired")
	done < <(desired_panel_keys)
	# Keep desired comparable to normalized AllSetting (env may still carry ldapPort=0 placeholders).
	desired=$(jq -c '
		if ((.ldapPort|tostring|tonumber?) // 0) < 1 then .ldapPort = "389" else . end
	' <<<"$desired")
	if [[ -z "${panelOutbound:-}" ]]; then
		desired=$(jq -c '.panelOutbound = "direct"' <<<"$desired")
	fi
	if clear_sub_json_routing_rules_requested; then
		desired=$(jq -c '.subJsonRoutingRules = ""' <<<"$desired")
	fi
	printf '%s' "$desired"
}

# Выделяет из ответа панели только ключи, которыми управляет этот runtime.
panel_current_managed_json() {
	local current=$1 var value projected='{}'
	while IFS= read -r var; do
		value=$(jq -r --arg key "$var" 'if .[$key] == null then "" else (.[$key]|tostring) end' <<<"$current")
		projected=$(jq -c --arg key "$var" --arg value "$value" '.[$key] = $value' <<<"$projected")
	done < <(desired_panel_keys)
	printf '%s' "$projected"
}

# Сверяет управляемые настройки панели и применяет только фактическое расхождение.
ensure_panel_settings() {
	local current current_projected desired body
	xui_get_panel_settings || die "Failed to read panel settings."
	http_success_json || die "Panel settings API failed: $(http_body)"
	current=$(api_obj_json)
	desired=$(panel_desired_json "$current")
	current_projected=$(panel_current_managed_json "$current")
	if json_equal "$current_projected" "$desired"; then
		log INFO "Panel settings already match desired state."
		return 0
	fi
	body=$(panel_settings_json "$current")
	if clear_sub_json_routing_rules_requested; then
		body=$(jq -c '.subJsonRoutingRules = ""' <<<"$body")
	fi

	if plan_or_apply "panel settings updated"; then
		xui_update_panel_settings "$body" || die "Failed to update panel settings."
		http_success_json || die "Panel settings update failed: $(http_body)"
		# shellcheck disable=SC2034 # флаг рестарта читается entrypoint/Xray-модулем
		RESTART_PANEL_REQUIRED=1
	fi
}

# При необходимости заменяет учетные данные администратора и обновляет сессию.
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

# Ждёт loopback panel-egress SOCKS, если он есть в running config.
wait_panel_egress_ready() {
	local cfg=${XRAY_RUNNING_CONFIG:-/app/bin/config.json}
	local timeout=${GEOFILES_EGRESS_WAIT_SECONDS:-20}
	local deadline host port
	deadline=$((SECONDS + timeout))
	while ((SECONDS <= deadline)); do
		if [[ ! -f "$cfg" ]]; then
			sleep 1
			continue
		fi
		host=$(jq -r '
			.inbounds[]?
			| select((.tag // "") == "panel-egress")
			| (.listen // "127.0.0.1")
			| if . == null or . == "" then "127.0.0.1"
			  elif type == "string" then (sub("^\""; "") | sub("\"$"; ""))
			  else tostring end
		' "$cfg" 2>/dev/null | head -n1 || true)
		port=$(jq -r '
			.inbounds[]?
			| select((.tag // "") == "panel-egress")
			| .port // empty
		' "$cfg" 2>/dev/null | head -n1 || true)
		if [[ -z "$port" ]]; then
			# No bridge → panel falls back to direct; safe to proceed.
			return 0
		fi
		host=${host:-127.0.0.1}
		if tcp_endpoint_available "$host" "$port" 1; then
			return 0
		fi
		sleep 1
	done
	log WARN "panel-egress not accepting connections before geofile update; continuing."
	return 1
}

# Запускает штатное обновление встроенных geo-файлов, если оно включено.
update_builtin_geofiles_if_enabled() {
	local attempts attempt
	[[ "$GEOFILES_UPDATE_ON_START" == "true" ]] || {
		log INFO "Built-in geofile update skipped."
		return 0
	}
	if [[ "$MODE" == "plan" ]]; then
		log INFO "PLAN: built-in geofile update-all would be requested."
		return 0
	fi
	wait_panel_egress_ready || true
	attempts=${GEOFILES_UPDATE_ATTEMPTS:-3}
	((attempts < 1)) && attempts=1
	for ((attempt = 1; attempt <= attempts; attempt++)); do
		if xui_update_geofiles && http_success_json; then
			log INFO "Built-in geoip/geosite files refreshed through panel API."
			return 0
		fi
		if ((attempt < attempts)); then
			log WARN "Built-in geofile update attempt $attempt/$attempts failed; retrying."
			sleep "${GEOFILES_UPDATE_RETRY_SECONDS:-5}"
			wait_panel_egress_ready || true
		fi
	done
	log WARN "Built-in geofile update skipped: $(http_body)"
}
