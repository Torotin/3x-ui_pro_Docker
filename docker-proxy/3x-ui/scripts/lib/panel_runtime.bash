#!/usr/bin/env bash

# Готовит form-urlencoded параметры панели из env или сохраненных значений.
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

# Получает массив пользовательских geo-ресурсов из ответа панели.
custom_geo_list_json() {
	xui_custom_geo_list || die "Failed to list custom geo resources."
	http_success_json || die "Custom geo list API failed: $(http_body)"
	jq -c '.obj // []' "$HTTP_BODY_FILE"
}

# Синхронизирует список пользовательских geo-файлов через API панели.
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
	# Каждый ресурс сопоставляется по типу и alias, поэтому изменение URL обновляется на месте.
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
		if xui_custom_geo_update_all && http_success_json; then
			log INFO "Custom geo resources refreshed through panel API."
		else
			log WARN "Custom geo update-all skipped: $(http_body)"
		fi
	elif [[ "$MODE" == "plan" && "$CUSTOM_GEO_UPDATE_ALL_ON_START" == "true" ]]; then
		log INFO "PLAN: custom geo update-all would be requested."
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
