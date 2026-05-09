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

http_init() {
	local tmp_root=$1
	COOKIE_JAR=${COOKIE_JAR:-"$tmp_root/cookies.txt"}
	: >"$COOKIE_JAR"
}

http_request() {
	local method=$1 url=$2
	shift 2
	local attempts=$HTTP_ATTEMPTS delay=1 body err ret
	# shellcheck disable=SC2034 # public diagnostic state for callers
	HTTP_LAST_URL=$url
	HTTP_CODE=000
	HTTP_ERROR=
	HTTP_BODY_FILE=

	while ((attempts > 0)); do
		body=$(mktemp)
		err=$(mktemp)
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

http_body() {
	[[ -n "${HTTP_BODY_FILE:-}" && -f "$HTTP_BODY_FILE" ]] || return 0
	cat "$HTTP_BODY_FILE"
}

http_success_json() {
	[[ "$HTTP_CODE" == "200" ]] || return 1
	jq -e '.success == true' "$HTTP_BODY_FILE" >/dev/null 2>&1
}
