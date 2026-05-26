#!/usr/bin/env bash

# Учитывает планируемое либо примененное изменение и выводит его в журнал.
record_change() {
	CHANGE_COUNT=$((CHANGE_COUNT + 1))
	log INFO "$*"
}

# Записывает намерение в режиме plan либо разрешает применение в режиме apply.
plan_or_apply() {
	local message=$1
	if [[ "$MODE" == "plan" ]]; then
		record_change "PLAN: $message"
		return 1
	fi
	record_change "APPLY: $message"
	return 0
}

# Преобразует тело последнего HTTP-ответа в компактный JSON.
body_json() {
	http_body | jq -c .
}

# Возвращает полезную часть obj из успешного ответа API панели.
api_obj_json() {
	jq -c '.obj // {}' "$HTTP_BODY_FILE"
}

# Формирует краткую диагностику ответа API для сообщений об ошибках.
api_error_summary() {
	local body
	body=$(http_body | tr '\n' ' ')
	printf 'HTTP %s: %s' "$HTTP_CODE" "$body"
}
