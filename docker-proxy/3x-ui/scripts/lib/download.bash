#!/usr/bin/env bash

# Кеш победившего транспорта живет внутри контейнера и ускоряет повторные загрузки.
: "${DOWNLOAD_TRANSPORT_CACHE:=/tmp/3xui-download.transport}"
: "${DOWNLOAD_CONNECT_TIMEOUT:=5}"
: "${DOWNLOAD_MAX_TIME:=120}"
: "${DOWNLOAD_STALL_SECONDS:=15}"

DOWNLOAD_CURL_TRANSPORT_ARGS=()

# Считает флаг включенным, если значение не является явным отрицанием.
download_flag_enabled() {
	case "${1:-true}" in
	0 | false | no | n | off | disabled)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

# Разбивает список транспортов или URL по запятой, точке с запятой и пробелам.
download_split_list() {
	local raw=${1:-} item
	raw=${raw//;/ }
	raw=${raw//,/ }
	# shellcheck disable=SC2086 # список намеренно разделяется IFS
	for item in $raw; do
		[[ -n "$item" ]] || continue
		printf '%s\n' "$item"
	done
}

# Собирает цепочку транспортов: явный DOWNLOAD_TRANSPORTS либо direct → usque → mihomo → tor.
download_default_transports() {
	printf '%s\n' direct
	printf 'socks5h://%s:%s\n' "${USQUE_HOST:-usque}" "${USQUE_PORT:-1080}"
	if download_flag_enabled "${ENABLE_MIHOMO:-true}"; then
		printf 'http://%s:%s\n' "${MIHOMO_PROXY_HOST:-mihomo}" "${MIHOMO_PROXY_PORT:-7890}"
	fi
	if download_flag_enabled "${XRAY_MANAGED_TOR:-true}"; then
		printf 'socks5h://%s:%s\n' "${TOR_PROXY_HOST:-tor-proxy}" "${TOR_PROXY_PORT:-1080}"
	fi
}

# Печатает транспорты в порядке попыток, ставя закешированный успешный первым.
download_transport_candidates() {
	local -a all=()
	local cached='' item seen_cache=0
	if [[ -n "${DOWNLOAD_TRANSPORTS:-}" ]]; then
		mapfile -t all < <(download_split_list "$DOWNLOAD_TRANSPORTS")
	else
		mapfile -t all < <(download_default_transports)
	fi
	if [[ -s "${DOWNLOAD_TRANSPORT_CACHE:-}" ]]; then
		cached=$(tr -d '\r\n' <"$DOWNLOAD_TRANSPORT_CACHE")
	fi
	if [[ -n "$cached" ]]; then
		for item in "${all[@]}"; do
			if [[ "$item" == "$cached" ]]; then
				printf '%s\n' "$cached"
				seen_cache=1
				break
			fi
		done
	fi
	for item in "${all[@]}"; do
		[[ -n "$item" ]] || continue
		if ((seen_cache)) && [[ "$item" == "$cached" ]]; then
			continue
		fi
		printf '%s\n' "$item"
	done
}

# Печатает исходный URL и необязательные DOWNLOAD_URL_FALLBACKS.
download_url_candidates() {
	local url=$1 item
	printf '%s\n' "$url"
	while IFS= read -r item; do
		[[ -n "$item" && "$item" != "$url" ]] || continue
		printf '%s\n' "$item"
	done < <(download_split_list "${DOWNLOAD_URL_FALLBACKS:-}")
}

# Заполняет аргументы curl: direct игнорирует env-прокси, остальное идет в -x.
download_set_curl_transport_args() {
	local transport=$1
	DOWNLOAD_CURL_TRANSPORT_ARGS=()
	case "$transport" in
	direct | none | off)
		DOWNLOAD_CURL_TRANSPORT_ARGS=(--noproxy '*')
		;;
	socks5h://* | socks5://* | socks4a://* | socks4://* | http://* | https://*)
		DOWNLOAD_CURL_TRANSPORT_ARGS=(-x "$transport")
		;;
	*)
		return 1
		;;
	esac
}

# Одна попытка curl без повторов: таймаут соединения короткий, чтобы быстро перейти к следующему транспорту.
download_via_transport() {
	local url=$1 dest=$2 transport=$3
	local -a args
	download_set_curl_transport_args "$transport" || return 1
	args=(
		-fsSL
		--connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT:-5}"
		--max-time "${DOWNLOAD_MAX_TIME:-120}"
		--speed-limit 1
		--speed-time "${DOWNLOAD_STALL_SECONDS:-15}"
		-o "$dest"
	)
	args+=("${DOWNLOAD_CURL_TRANSPORT_ARGS[@]}" "$url")
	curl "${args[@]}" || return $?
}

# Запоминает транспорт, которым удалось скачать файл.
download_remember_transport() {
	local transport=$1 cache=${DOWNLOAD_TRANSPORT_CACHE:-}
	[[ -n "$cache" && "$transport" != "direct" && "$transport" != "none" && "$transport" != "off" ]] || return 0
	printf '%s\n' "$transport" >"$cache" || true
}

# Скачивает файл во временный путь и заменяет назначение только после проверки.
# Возвращает 1, если все транспорты и URL-кандидаты исчерпаны; вызывающий решает, фатальна ли ошибка.
download_file_atomic() {
	local url=$1 dest=$2 checksum=${3:-}
	local tmp candidate_url transport rc
	local -a urls=() transports=()
	tmp=$(mktemp "${dest}.tmp.XXXXXX") || return 1
	rm -f "$tmp"

	mapfile -t urls < <(download_url_candidates "$url")
	mapfile -t transports < <(download_transport_candidates)
	((${#urls[@]} > 0 && ${#transports[@]} > 0)) || {
		log ERROR "No download URL or transport candidates for $url"
		return 1
	}

	for candidate_url in "${urls[@]}"; do
		[[ -n "$candidate_url" ]] || continue
		for transport in "${transports[@]}"; do
			[[ -n "$transport" ]] || continue
			if ! download_set_curl_transport_args "$transport"; then
				log WARN "Skipping unknown download transport: $transport"
				continue
			fi
			rm -f "$tmp"
			log INFO "Downloading $candidate_url -> $dest via $transport"
			rc=0
			download_via_transport "$candidate_url" "$tmp" "$transport" || rc=$?
			if ((rc != 0)); then
				log WARN "Download via $transport failed (curl $rc)"
				rm -f "$tmp"
				continue
			fi
			if [[ ! -s "$tmp" ]]; then
				log WARN "Downloaded file is empty via $transport: $candidate_url"
				rm -f "$tmp"
				continue
			fi
			if [[ -n "$checksum" ]]; then
				# Контрольная сумма проверяется до перемещения, чтобы не повредить рабочий файл.
				if ! printf '%s  %s\n' "$checksum" "$tmp" | sha256sum -c - >/dev/null; then
					log WARN "Checksum mismatch via $transport: $candidate_url"
					rm -f "$tmp"
					continue
				fi
			fi
			chmod --reference="$dest" "$tmp" 2>/dev/null || true
			mv -f "$tmp" "$dest" || {
				rm -f "$tmp"
				log ERROR "Failed to move downloaded file to $dest"
				return 1
			}
			download_remember_transport "$transport"
			return 0
		done
	done

	rm -f "$tmp"
	log ERROR "All download transports failed for $url"
	return 1
}

# Разбирает строку URL|имя|sha256 в переменные, используемые загрузчиком.
parse_download_entry() {
	local entry=$1
	DOWNLOAD_URL=${entry%%|*}
	local rest=${entry#*|}
	DOWNLOAD_NAME=
	DOWNLOAD_SHA256=
	if [[ "$rest" != "$entry" ]]; then
		DOWNLOAD_NAME=${rest%%|*}
		if [[ "$rest" == *"|"* ]]; then
			# shellcheck disable=SC2034 # результат разбора используется вызывающим кодом
			DOWNLOAD_SHA256=${rest#*|}
		fi
	fi
	if [[ -z "$DOWNLOAD_NAME" ]]; then
		DOWNLOAD_NAME=$(basename "${DOWNLOAD_URL%%\?*}")
	fi
}
