#!/usr/bin/env bash

URL_BASE_RESOLVED=${URL_BASE_RESOLVED:-}

xui_url() {
	local path=$1
	printf '%s%s' "${URL_BASE_RESOLVED%/}" "$path"
}

xui_api_get() {
	local path=$1
	http_request GET "$(xui_url "$path")" -H 'Accept: application/json'
}

xui_api_post() {
	local path=$1
	shift
	http_request POST "$(xui_url "$path")" \
		-H 'Accept: application/json' \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		"$@"
}

xui_api_post_long() {
	local old_max_time=$HTTP_MAX_TIME ret errexit_was_on=0
	case $- in
	*e*) errexit_was_on=1 ;;
	esac
	HTTP_MAX_TIME=${HTTP_LONG_MAX_TIME:-180}
	set +e
	xui_api_post "$@"
	ret=$?
	((errexit_was_on == 1)) && set -e
	HTTP_MAX_TIME=$old_max_time
	return "$ret"
}

xui_login() {
	local base=$1 username=$2 password=$3
	URL_BASE_RESOLVED=${base%/}
	http_request POST "$(xui_url "/login")" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		--data-urlencode "username=$username" \
		--data-urlencode "password=$password"
	http_success_json
}

resolve_panel_base() {
	local bp bases=() base user pass old_attempts old_connect_timeout old_max_time old_log_failures
	bp=$(normalize_base_path "${webBasePath:-}")

	if [[ -n "${URL_BASE_RESOLVED:-}" ]]; then
		bases+=("${URL_BASE_RESOLVED%/}")
	fi
	if [[ -n "${webPort:-}" ]]; then
		bases+=(
			"https://127.0.0.1:$webPort$bp"
			"http://127.0.0.1:$webPort$bp"
			"https://localhost:$webPort$bp"
			"http://localhost:$webPort$bp"
			"https://127.0.0.1:$webPort"
			"http://127.0.0.1:$webPort"
			"https://localhost:$webPort"
			"http://localhost:$webPort"
		)
	fi
	if [[ -n "$WEBDOMAIN" ]]; then
		bases+=("https://$WEBDOMAIN$bp" "http://$WEBDOMAIN$bp")
	fi
	if [[ -n "${webPort:-}" && "$webPort" != "2053" && -n "$WEBDOMAIN" ]]; then
		bases+=("https://$WEBDOMAIN:$webPort$bp" "http://$WEBDOMAIN:$webPort$bp")
	fi
	bases+=(
		"https://127.0.0.1:2053$bp"
		"http://127.0.0.1:2053$bp"
		"https://localhost:2053$bp"
		"http://localhost:2053$bp"
		"https://127.0.0.1:2053"
		"http://127.0.0.1:2053"
		"https://localhost:2053"
		"http://localhost:2053"
	)

	old_attempts=$HTTP_ATTEMPTS
	old_connect_timeout=$HTTP_CONNECT_TIMEOUT
	old_max_time=$HTTP_MAX_TIME
	old_log_failures=$HTTP_LOG_FAILURES
	HTTP_ATTEMPTS=1
	HTTP_CONNECT_TIMEOUT=1
	HTTP_MAX_TIME=3
	HTTP_LOG_FAILURES=0

	for base in "${bases[@]}"; do
		[[ -n "$base" ]] || continue
		for user in "$USERNAME" "${NEW_ADMIN_USERNAME:-}"; do
			[[ -n "$user" ]] || continue
			if [[ "$user" == "$USERNAME" ]]; then
				pass=$PASSWORD
			else
				pass=$NEW_ADMIN_PASSWORD
			fi
			[[ -n "$pass" ]] || continue
			log DEBUG "Trying panel login base=$base username=$user"
			if xui_login "$base" "$user" "$pass"; then
				USERNAME=$user
				PASSWORD=$pass
				HTTP_ATTEMPTS=$old_attempts
				HTTP_CONNECT_TIMEOUT=$old_connect_timeout
				HTTP_MAX_TIME=$old_max_time
				HTTP_LOG_FAILURES=$old_log_failures
				log INFO "Panel login succeeded at $URL_BASE_RESOLVED"
				return 0
			fi
		done
	done
	HTTP_ATTEMPTS=$old_attempts
	HTTP_CONNECT_TIMEOUT=$old_connect_timeout
	HTTP_MAX_TIME=$old_max_time
	HTTP_LOG_FAILURES=$old_log_failures
	return 1
}

xui_get_panel_settings() {
	xui_api_post '/panel/setting/all'
}

xui_update_panel_settings() {
	local args=("$@")
	xui_api_post '/panel/setting/update' "${args[@]}"
}

xui_update_admin_credentials() {
	[[ -n "${NEW_ADMIN_USERNAME:-}" && -n "${NEW_ADMIN_PASSWORD:-}" ]] || return 0
	xui_api_post '/panel/setting/updateUser' \
		--data-urlencode "oldUsername=$USERNAME" \
		--data-urlencode "oldPassword=$PASSWORD" \
		--data-urlencode "newUsername=$NEW_ADMIN_USERNAME" \
		--data-urlencode "newPassword=$NEW_ADMIN_PASSWORD"
}

xui_list_inbounds() {
	xui_api_get '/panel/api/inbounds/list'
}

xui_get_inbound() {
	local id=$1
	xui_api_get "/panel/api/inbounds/get/$id"
}

xui_add_inbound() {
	xui_api_post '/panel/api/inbounds/add' "$@"
}

xui_update_inbound() {
	local id=$1
	shift
	xui_api_post "/panel/api/inbounds/update/$id" "$@"
}

xui_add_client() {
	xui_api_post '/panel/api/inbounds/addClient' "$@"
}

xui_update_client() {
	local client_id=$1
	shift
	xui_api_post "/panel/api/inbounds/updateClient/$client_id" "$@"
}

xui_get_xray_settings() {
	xui_api_post '/panel/xray/'
}

xui_update_xray_settings() {
	local file=$1
	xui_api_post '/panel/xray/update' --data-urlencode "xraySetting@$file"
}

xui_restart_panel() {
	xui_api_post '/panel/setting/restartPanel'
}

xui_restart_xray() {
	xui_api_post '/server/restartXrayService'
}

xui_custom_geo_list() {
	xui_api_get '/panel/api/custom-geo/list'
}

xui_custom_geo_add() {
	local type=$1 alias=$2 url=$3
	xui_api_post_long '/panel/api/custom-geo/add' \
		--data-urlencode "type=$type" \
		--data-urlencode "alias=$alias" \
		--data-urlencode "url=$url"
}

xui_custom_geo_update() {
	local id=$1 type=$2 alias=$3 url=$4
	xui_api_post_long "/panel/api/custom-geo/update/$id" \
		--data-urlencode "type=$type" \
		--data-urlencode "alias=$alias" \
		--data-urlencode "url=$url"
}

xui_custom_geo_update_all() {
	xui_api_post_long '/panel/api/custom-geo/update-all'
}

xui_update_geofiles() {
	xui_api_post_long '/panel/api/server/updateGeofile'
}

xui_warp_config() {
	xui_api_post '/panel/xray/warp/config'
}

xui_warp_register() {
	local public_key=$1 private_key=$2
	xui_api_post_long '/panel/xray/warp/reg' \
		--data-urlencode "publicKey=$public_key" \
		--data-urlencode "privateKey=$private_key"
}

xui_get_x25519() {
	xui_api_get '/panel/api/server/getNewX25519Cert'
}

xui_get_vless_enc() {
	xui_api_get '/panel/api/server/getNewVlessEnc'
}
