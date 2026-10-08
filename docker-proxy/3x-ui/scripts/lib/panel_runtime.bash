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
	merged=$(jq -c 'if ((.smtpPort|tostring|tonumber?) // 0) < 1 then .smtpPort = 587 else . end' <<<"$merged")
	if [[ -z "${panelOutbound:-}" ]]; then
		merged=$(jq -c 'if ((.panelOutbound // "") | length) == 0 then .panelOutbound = "usque" else . end' <<<"$merged")
	fi
	printf '%s' "$merged"
}

# Строит сравнимый JSON желаемых настроек панели из окружения и текущего состояния.
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
	if [[ -z "${panelOutbound:-}" ]]; then
		desired=$(jq -c 'if ((.panelOutbound // "") | length) == 0 then .panelOutbound = "usque" else . end' <<<"$desired")
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

# Запускает штатное обновление встроенных geo-файлов, если оно включено.
update_builtin_geofiles_if_enabled() {
	[[ "$GEOFILES_UPDATE_ON_START" == "true" ]] || {
		log INFO "Built-in geofile update skipped."
		return 0
	}
	if [[ "$MODE" == "plan" ]]; then
		log INFO "PLAN: built-in geofile update-all would be requested."
		return 0
	fi
	if xui_update_geofiles && http_success_json; then
		log INFO "Built-in geoip/geosite files refreshed through panel API."
	else
		log WARN "Built-in geofile update skipped: $(http_body)"
	fi
}
