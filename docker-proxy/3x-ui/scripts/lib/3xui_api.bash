#!/usr/bin/env bash

URL_BASE_RESOLVED=${URL_BASE_RESOLVED:-}
XUI_API_TOKEN_RESOLVED=${XUI_API_TOKEN_RESOLVED:-}

# Route migration (canonical first, legacy fallback on HTTP 404):
# | Function                     | Canonical (3.x docs)              | Legacy (pre-3.5 UI routes)   |
# |------------------------------|-----------------------------------|------------------------------|
# | xui_get_panel_settings       | POST /panel/api/setting/all       | POST /panel/setting/all      |
# | xui_update_panel_settings    | POST /panel/api/setting/update    | POST /panel/setting/update   |
# | xui_update_admin_credentials | POST /panel/api/setting/updateUser| POST /panel/setting/updateUser|
# | xui_restart_panel            | POST /panel/api/setting/restartPanel | POST /panel/setting/restartPanel |
# | xui_get_xray_settings        | POST /panel/api/xray/             | POST /panel/xray/            |
# | xui_update_xray_settings     | POST /panel/api/xray/update       | POST /panel/xray/update      |
# | xui_warp_config              | POST /panel/api/xray/warp/config  | POST /panel/xray/warp/config |
# | xui_warp_register            | POST /panel/api/xray/warp/reg     | POST /panel/xray/warp/reg    |
#
# See .project_context/01_project/3x-ui-api-route-migration.md.

# Собирает полный URL панели из уже найденной базы и относительного пути API.
xui_url() {
	local path=$1
	printf '%s%s' "${URL_BASE_RESOLVED%/}" "$path"
}

# Добавляет Bearer-токен только для маршрутов нового API панели, если он доступен.
xui_api_auth_args() {
	local path=$1 token
	[[ "$path" == /panel/api/* ]] || return 0
	token=$(xui_api_token)
	[[ -n "$token" ]] || return 0
	printf '%s\0%s\0' -H "Authorization: Bearer $token"
}

# Возвращает Bearer-токен API из окружения (3.7 scoped tokens via XUI_API_TOKEN only).
xui_api_token() {
	if [[ -n "${XUI_API_TOKEN:-}" ]]; then
		printf '%s' "$XUI_API_TOKEN"
		return 0
	fi
	if [[ -n "${XUI_API_TOKEN_RESOLVED:-}" ]]; then
		printf '%s' "$XUI_API_TOKEN_RESOLVED"
		return 0
	fi
	return 0
}

# Отправляет GET-запрос API с подходящей Bearer-аутентификацией.
xui_api_get() {
	local path=$1 auth_args=()
	mapfile -d '' -t auth_args < <(xui_api_auth_args "$path")
	http_request GET "$(xui_url "$path")" "${auth_args[@]}" -H 'Accept: application/json'
}

# Отправляет form-urlencoded POST с Bearer и CSRF-заголовками при их наличии.
xui_api_post() {
	local path=$1 auth_args=() csrf_args=()
	shift
	mapfile -d '' -t auth_args < <(xui_api_auth_args "$path")
	mapfile -d '' -t csrf_args < <(xui_csrf_args)
	http_request POST "$(xui_url "$path")" \
		"${auth_args[@]}" \
		"${csrf_args[@]}" \
		-H 'Accept: application/json' \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H 'X-Requested-With: XMLHttpRequest' \
		"$@"
}

# Повторяет POST по legacy-маршруту, если canonical /panel/api/* вернул HTTP 404.
xui_api_post_dual_path() {
	local cache_var=$1 canonical=$2 legacy=$3 resolved
	shift 3
	resolved=${!cache_var:-}
	if [[ -n "$resolved" ]]; then
		xui_api_post "$resolved" "$@"
		return
	fi
	xui_api_post "$canonical" "$@"
	if [[ "$HTTP_CODE" != "404" ]]; then
		printf -v "$cache_var" '%s' "$canonical"
		return
	fi
	log DEBUG "Panel API route fallback: $canonical -> $legacy"
	xui_api_post "$legacy" "$@"
	if [[ "$HTTP_CODE" != "404" ]]; then
		printf -v "$cache_var" '%s' "$legacy"
	fi
}

# То же, что xui_api_post_dual_path, но с увеличенным HTTP_MAX_TIME.
xui_api_post_dual_path_long() {
	local cache_var=$1 canonical=$2 legacy=$3 resolved old_max_time ret errexit_was_on=0
	shift 3
	resolved=${!cache_var:-}
	case $- in
	*e*) errexit_was_on=1 ;;
	esac
	old_max_time=$HTTP_MAX_TIME
	HTTP_MAX_TIME=${HTTP_LONG_MAX_TIME:-180}
	set +e
	if [[ -n "$resolved" ]]; then
		xui_api_post "$resolved" "$@"
		ret=$?
	else
		xui_api_post "$canonical" "$@"
		if [[ "$HTTP_CODE" == "404" ]]; then
			log DEBUG "Panel API route fallback: $canonical -> $legacy"
			xui_api_post "$legacy" "$@"
			[[ "$HTTP_CODE" != "404" ]] && printf -v "$cache_var" '%s' "$legacy"
		else
			printf -v "$cache_var" '%s' "$canonical"
		fi
		ret=$?
	fi
	((errexit_was_on == 1)) && set -e
	HTTP_MAX_TIME=$old_max_time
	return "$ret"
}

# Кодирует email для использования в path-компоненте URL API клиентов.
xui_client_email_path() {
	local email=$1
	jq -nr --arg email "$email" '$email|@uri'
}

# Повторяет JSON POST по legacy-маршруту, если canonical /panel/api/* вернул HTTP 404.
xui_api_post_json_dual_path() {
	local cache_var=$1 canonical=$2 legacy=$3 body=$4 resolved
	resolved=${!cache_var:-}
	if [[ -n "$resolved" ]]; then
		xui_api_post_json "$resolved" "$body"
		return
	fi
	xui_api_post_json "$canonical" "$body"
	if [[ "$HTTP_CODE" != "404" ]]; then
		printf -v "$cache_var" '%s' "$canonical"
		return
	fi
	log DEBUG "Panel API route fallback: $canonical -> $legacy"
	xui_api_post_json "$legacy" "$body"
	if [[ "$HTTP_CODE" != "404" ]]; then
		printf -v "$cache_var" '%s' "$legacy"
	fi
}

# Отправляет JSON POST для API 3x-ui 3.1+, работающего с объектами клиентов и настроек.
xui_api_post_json() {
	local path=$1 body=$2 auth_args=() csrf_args=()
	mapfile -d '' -t auth_args < <(xui_api_auth_args "$path")
	mapfile -d '' -t csrf_args < <(xui_csrf_args)
	http_request POST "$(xui_url "$path")" \
		"${auth_args[@]}" \
		"${csrf_args[@]}" \
		-H 'Accept: application/json' \
		-H 'Content-Type: application/json' \
		-H 'X-Requested-With: XMLHttpRequest' \
		--data-binary "$body"
}

# Увеличивает лимит времени для долгого POST и затем восстанавливает настройки HTTP.
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

# Выполняет долгую создающую операцию одной попыткой, исключая повторное создание.
xui_api_post_once_long() {
	local old_max_time=$HTTP_MAX_TIME old_attempts=$HTTP_ATTEMPTS ret errexit_was_on=0
	case $- in
	*e*) errexit_was_on=1 ;;
	esac
	HTTP_MAX_TIME=${HTTP_LONG_MAX_TIME:-180}
	HTTP_ATTEMPTS=1
	set +e
	xui_api_post "$@"
	ret=$?
	((errexit_was_on == 1)) && set -e
	HTTP_MAX_TIME=$old_max_time
	HTTP_ATTEMPTS=$old_attempts
	return "$ret"
}

# Выполняет долгий JSON POST один раз, чтобы мутация не продублировалась при таймауте.
xui_api_post_json_once_long() {
	local old_max_time=$HTTP_MAX_TIME old_attempts=$HTTP_ATTEMPTS ret errexit_was_on=0
	case $- in
	*e*) errexit_was_on=1 ;;
	esac
	HTTP_MAX_TIME=${HTTP_LONG_MAX_TIME:-180}
	HTTP_ATTEMPTS=1
	set +e
	xui_api_post_json "$@"
	ret=$?
	((errexit_was_on == 1)) && set -e
	HTTP_MAX_TIME=$old_max_time
	HTTP_ATTEMPTS=$old_attempts
	return "$ret"
}

# Формирует CSRF-заголовок, когда панель вернула действительный токен сессии.
xui_csrf_args() {
	local csrf
	csrf=$(xui_csrf_token)
	[[ -n "$csrf" ]] || return 0
	printf '%s\0%s\0' -H "X-CSRF-Token: $csrf"
}

# Запрашивает CSRF-токен текущей сессии и спокойно обрабатывает его отсутствие.
xui_csrf_token() {
	http_request GET "$(xui_url "/csrf-token")" \
		-H 'Accept: application/json' \
		-H 'X-Requested-With: XMLHttpRequest' || return 0
	[[ "$HTTP_CODE" == "200" ]] || return 0
	jq -r 'if .success == true and (.obj | type == "string") then .obj else "" end' "$HTTP_BODY_FILE" 2>/dev/null
}

# Авторизуется на указанной базе панели и закрепляет ее для последующих запросов.
xui_login() {
	local base=$1 username=$2 password=$3 csrf csrf_args=() body
	URL_BASE_RESOLVED=${base%/}
	csrf=$(xui_csrf_token)
	[[ -n "$csrf" ]] && csrf_args=(-H "X-CSRF-Token: $csrf")
	if [[ -n "${TWO_FACTOR_CODE:-}" ]]; then
		body=$(jq -nc --arg username "$username" --arg password "$password" --arg twoFactorCode "$TWO_FACTOR_CODE" \
			'{username:$username,password:$password,twoFactorCode:$twoFactorCode}')
	else
		body=$(jq -nc --arg username "$username" --arg password "$password" '{username:$username,password:$password}')
	fi
	http_request POST "$(xui_url "/login")" \
		-H 'Accept: application/json' \
		-H 'Content-Type: application/json' \
		-H 'X-Requested-With: XMLHttpRequest' \
		"${csrf_args[@]}" \
		--data-binary "$body"
	http_success_json
}

# Находит доступный адрес панели и рабочую пару учетных данных после возможной миграции.
resolve_panel_base() {
	local bp bases=() credentials=() credential base user pass old_attempts old_connect_timeout old_max_time old_log_failures
	bp=$(normalize_base_path "${webBasePath:-}")
	credentials+=("$USERNAME"$'\t'"$PASSWORD")
	if [[ -n "${NEW_ADMIN_USERNAME:-}" && -n "${NEW_ADMIN_PASSWORD:-}" ]]; then
		credentials+=("$NEW_ADMIN_USERNAME"$'\t'"$NEW_ADMIN_PASSWORD")
	fi

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

	# Поиск endpoint выполняется быстро и без ошибок в журнале для нерабочих кандидатов.
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
		for credential in "${credentials[@]}"; do
			user=${credential%%$'\t'*}
			pass=${credential#*$'\t'}
			[[ -n "$user" ]] || continue
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

# Получает полный набор настроек панели через session/CSRF маршрут.
xui_get_panel_settings() {
	xui_api_post_dual_path XUI_ROUTE_setting_all \
		'/panel/api/setting/all' '/panel/setting/all'
}

# Отправляет полный объект AllSetting JSON на canonical/legacy маршрут update.
xui_update_panel_settings() {
	local body=$1
	xui_api_post_json_dual_path XUI_ROUTE_setting_update \
		'/panel/api/setting/update' '/panel/setting/update' "$body"
}

# Заменяет учетные данные администратора, если заданы обе новые величины.
xui_update_admin_credentials() {
	local body
	[[ -n "${NEW_ADMIN_USERNAME:-}" && -n "${NEW_ADMIN_PASSWORD:-}" ]] || return 0
	body=$(jq -nc \
		--arg oldUsername "$USERNAME" \
		--arg oldPassword "$PASSWORD" \
		--arg newUsername "$NEW_ADMIN_USERNAME" \
		--arg newPassword "$NEW_ADMIN_PASSWORD" \
		'{oldUsername:$oldUsername,oldPassword:$oldPassword,newUsername:$newUsername,newPassword:$newPassword}')
	xui_api_post_json_dual_path XUI_ROUTE_setting_update_user \
		'/panel/api/setting/updateUser' '/panel/setting/updateUser' "$body"
}

# Возвращает список inbound через Bearer-совместимый API панели.
xui_list_inbounds() {
	xui_api_get '/panel/api/inbounds/list'
}

# Получает один inbound по его идентификатору.
xui_get_inbound() {
	local id=$1
	xui_api_get "/panel/api/inbounds/get/$id"
}

# Создает inbound с nested JSON и без повторения мутации при таймауте.
xui_add_inbound() {
	local body=$1
	xui_api_post_json_once_long '/panel/api/inbounds/add' "$body"
}

# Обновляет существующий inbound nested JSON по его идентификатору.
xui_update_inbound() {
	local id=$1 body=$2
	xui_api_post_json "/panel/api/inbounds/update/$id" "$body"
}

# Создает объект клиента и сразу привязывает его к указанным inbound.
xui_add_client() {
	local payload=$1
	xui_api_post_json_once_long '/panel/api/clients/add' "$payload"
}

# Возвращает полный объект клиента по email (first-class clients API 3.x).
xui_get_client() {
	local email=$1 path
	path=$(xui_client_email_path "$email")
	xui_api_get "/panel/api/clients/get/$path"
}

# Обновляет клиента replace-контрактом: overlay managed полей поверх текущего GET.
xui_update_client() {
	local email=$1 payload=$2 path current merged managed_keys
	path=$(xui_client_email_path "$email")
	xui_get_client "$email" || return 1
	http_success_json || return 1
	current=$(jq -c '.obj // {}' "$HTTP_BODY_FILE")
	managed_keys='["id","uuid","password","auth","flow","email","subId","enable","security","comment","limitIp","totalGB","expiryTime","reset","tgId","group"]'
	merged=$(jq -c --argjson payload "$payload" --argjson keys "$managed_keys" '
      reduce $keys[] as $k (.;
        if ($payload | has($k)) then .[$k] = $payload[$k] else . end
      )
    ' <<<"$current")
	xui_api_post_json "/panel/api/clients/update/$path" "$merged"
}

# Возвращает список объектов клиентов нового API панели.
xui_list_clients() {
	xui_api_get '/panel/api/clients/list'
}

# Добавляет существующему клиенту недостающие привязки к inbound.
xui_attach_client() {
	local email=$1 payload=$2 path
	path=$(xui_client_email_path "$email")
	xui_api_post_json_once_long "/panel/api/clients/$path/attach" "$payload"
}

# Читает шаблон настроек Xray через маршрут панели с сессионной защитой.
xui_get_xray_settings() {
	xui_api_post_dual_path XUI_ROUTE_xray_read \
		'/panel/api/xray/' '/panel/xray/'
}

# Записывает подготовленный файл шаблона Xray через API панели.
xui_update_xray_settings() {
	local file=$1
	xui_api_post_dual_path XUI_ROUTE_xray_update \
		'/panel/api/xray/update' '/panel/xray/update' \
		--data-urlencode "xraySetting@$file"
}

# Запрашивает перезапуск панели после изменения ее настроек.
xui_restart_panel() {
	xui_api_post_dual_path XUI_ROUTE_setting_restart_panel \
		'/panel/api/setting/restartPanel' '/panel/setting/restartPanel'
}

# Запрашивает перезапуск службы Xray после изменения runtime-конфигурации.
xui_restart_xray() {
	xui_api_post '/panel/api/server/restartXrayService'
}

# Запускает обновление встроенных geoip/geosite файлов панели.
xui_update_geofiles() {
	xui_api_post_long '/panel/api/server/updateGeofile'
}

# Получает сохраненную в панели конфигурацию WARP.
xui_warp_config() {
	xui_api_post_dual_path XUI_ROUTE_xray_warp_config \
		'/panel/api/xray/warp/config' '/panel/xray/warp/config'
}

# Регистрирует новую пару WireGuard-ключей в WARP через API панели.
xui_warp_register() {
	local public_key=$1 private_key=$2
	xui_api_post_dual_path_long XUI_ROUTE_xray_warp_reg \
		'/panel/api/xray/warp/reg' '/panel/xray/warp/reg' \
		--data-urlencode "publicKey=$public_key" \
		--data-urlencode "privateKey=$private_key"
}

# Запрашивает новую пару X25519 для входящего соединения REALITY.
xui_get_x25519() {
	xui_api_get '/panel/api/server/getNewX25519Cert'
}

# Запрашивает доступные параметры шифрования VLESS у панели.
xui_get_vless_enc() {
	xui_api_get '/panel/api/server/getNewVlessEnc'
}
