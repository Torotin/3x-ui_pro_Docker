#!/usr/bin/env bash

HTTP_CODE=000
HTTP_BODY_FILE=
HTTP_ERROR=
HTTP_LAST_URL=
COOKIE_JAR=${COOKIE_JAR:-}
HTTP_CONNECT_TIMEOUT=${HTTP_CONNECT_TIMEOUT:-2}
HTTP_MAX_TIME=${HTTP_MAX_TIME:-8}
HTTP_ATTEMPTS=${HTTP_ATTEMPTS:-4}
HTTP_LOG_FAILURES=${HTTP_LOG_FAILURES:-1}

# Инициализирует каталог HTTP-сессии и отдельное хранилище cookie панели.
http_init() {
	local tmp_root=$1
	COOKIE_JAR=${COOKIE_JAR:-"$tmp_root/cookies.txt"}
	TMP_ROOT=${TMP_ROOT:-$tmp_root}
	: >"$COOKIE_JAR"
}

# Создает временный HTTP-файл внутри сессии, если каталог уже подготовлен.
http_mktemp() {
	local name=${1:-http}
	if [[ -n "${TMP_ROOT:-}" ]]; then
		mkdir -p "$TMP_ROOT"
		mktemp "$TMP_ROOT/${name}.XXXXXX"
	else
		mktemp
	fi
}

# Выполняет HTTP-запрос с повторными попытками и сохраняет тело для вызывающего кода.
http_request() {
	local method=$1 url=$2
	shift 2
	local attempts=$HTTP_ATTEMPTS delay=1 body err ret
	# shellcheck disable=SC2034 # состояние диагностики используется вызывающим кодом
	HTTP_LAST_URL=$url
	HTTP_CODE=000
	HTTP_ERROR=
	HTTP_BODY_FILE=

	# Каждая попытка получает отдельные файлы ответа и stderr для точной диагностики.
	while ((attempts > 0)); do
		body=$(http_mktemp http-body)
		err=$(http_mktemp http-error)
		HTTP_CODE=$(
			curl -k -sS \
				--connect-timeout "$HTTP_CONNECT_TIMEOUT" \
				--max-time "$HTTP_MAX_TIME" \
				-X "$method" \
				--cookie "$COOKIE_JAR" \
				--cookie-jar "$COOKIE_JAR" \
				-w '%{http_code}' \
				-o "$body" \
				"$@" "$url" 2>"$err"
		)
		ret=$?
		HTTP_BODY_FILE=$body
		HTTP_ERROR=$(tr '\n' ' ' <"$err")
		rm -f "$err"

		if [[ $ret -eq 0 && -n "$HTTP_CODE" ]]; then
			return 0
		fi

		rm -f "$body"
		attempts=$((attempts - 1))
		if ((attempts > 0)); then
			log DEBUG "curl failed for $method $url ret=$ret attempts_left=$attempts error=$HTTP_ERROR"
			sleep "$delay"
			delay=$((delay * 2))
		fi
	done

	if [[ "${HTTP_LOG_FAILURES:-1}" == "1" ]]; then
		log ERROR "curl failed for $method $url after $HTTP_ATTEMPTS attempts: $HTTP_ERROR"
	else
		log DEBUG "curl failed for $method $url after $HTTP_ATTEMPTS attempts: $HTTP_ERROR"
	fi
	return 1
}

# Возвращает тело последнего HTTP-ответа, если запрос успел создать файл.
http_body() {
	[[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] || return 0
	cat "$HTTP_BODY_FILE"
}

# Проверяет успешный JSON-ответ панели: HTTP 200 и логический флаг success.
http_success_json() {
	[[ "$HTTP_CODE" == "200" ]] || return 1
	jq -e '.success == true' "$HTTP_BODY_FILE" >/dev/null 2>&1
}
