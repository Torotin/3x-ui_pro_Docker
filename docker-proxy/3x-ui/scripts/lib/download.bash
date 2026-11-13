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
	if download_flag_enabled "${ENABLE_MIHOMO:-false}"; then
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

# Достаёт поле url ассета с заданным name из JSON релиза GitHub.
download_github_asset_url_from_json() {
	local json=$1 name=$2
	if command -v python3 >/dev/null 2>&1; then
		DOWNLOAD_ASSET_NAME="$name" python3 -c '
import json, os, sys
name = os.environ["DOWNLOAD_ASSET_NAME"]
try:
    assets = json.load(sys.stdin).get("assets") or []
except Exception:
    raise SystemExit(0)
for asset in assets:
    if asset.get("name") == name and asset.get("url"):
        print(asset["url"])
        break
' <<<"$json" 2>/dev/null || true
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg name "$name" '.assets[]? | select(.name == $name) | .url // empty' <<<"$json" 2>/dev/null | head -n1 || true
		return 0
	fi
	# Fallback: url часто идёт раньше name в объекте asset.
	printf '%s' "$json" | tr '{}' '\n' |
		awk -v name="$name" '
			$0 ~ ("\"name\"[[:space:]]*:[[:space:]]*\"" name "\"") {
				if (match($0, /"url"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) {
					print m[1]
					exit
				}
			}
		' 2>/dev/null || true
}

# Тянет JSON релиза GitHub через цепочку транспортов (на части хостов api.github.com недоступен direct).
download_github_release_json() {
	local api_url=$1 transport
	local -a transports=()
	mapfile -t transports < <(download_transport_candidates)
	for transport in "${transports[@]}"; do
		[[ -n "$transport" ]] || continue
		download_set_curl_transport_args "$transport" || continue
		if json="$(
			curl -fsSL --connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT:-5}" --max-time 30 \
				-H 'Accept: application/vnd.github+json' \
				-H 'User-Agent: 3x-ui-pro-docker-download' \
				"${DOWNLOAD_CURL_TRANSPORT_ARGS[@]}" \
				"$api_url" 2>/dev/null
		)" && [[ "$json" == \{* ]]; then
			printf '%s' "$json"
			return 0
		fi
	done
	return 1
}

# GitHub releases/download часто отдаёт 504; Assets API + octet-stream ходит на release-assets.githubusercontent.com.
# Возвращает api.github.com/.../releases/assets/<id> или пусто, если URL не github-release / resolve не удался.
download_github_asset_api_url() {
	local url=$1 owner repo tag name api_url json asset_url
	download_flag_enabled "${DOWNLOAD_GITHUB_ASSET_API:-true}" || return 0
	if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/latest/download/([^/?#]+)$ ]]; then
		owner=${BASH_REMATCH[1]}
		repo=${BASH_REMATCH[2]}
		name=${BASH_REMATCH[3]}
		api_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
	elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?#]+)$ ]]; then
		owner=${BASH_REMATCH[1]}
		repo=${BASH_REMATCH[2]}
		tag=${BASH_REMATCH[3]}
		name=${BASH_REMATCH[4]}
		api_url="https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}"
	else
		return 0
	fi
	json="$(download_github_release_json "$api_url" || true)"
	[[ -n "$json" ]] || return 0
	asset_url="$(download_github_asset_url_from_json "$json" "$name")"
	[[ -n "$asset_url" ]] || return 0
	printf '%s\n' "$asset_url"
}

# Зеркала вида https://ghfast.top/https://github.com/... (пустое DOWNLOAD_GITHUB_MIRRORS отключает).
download_github_mirror_urls() {
	local url=$1 mirror
	[[ "$url" == https://github.com/* ]] || return 0
	download_flag_enabled "${DOWNLOAD_GITHUB_MIRRORS_ENABLED:-true}" || return 0
	while IFS= read -r mirror; do
		[[ -n "$mirror" ]] || continue
		mirror=${mirror%/}
		printf '%s/%s\n' "$mirror" "$url"
	done < <(download_split_list "${DOWNLOAD_GITHUB_MIRRORS:-https://ghfast.top}")
}

# Печатает кандидатов URL: Assets API → зеркала GitHub → исходный URL → DOWNLOAD_URL_FALLBACKS.
download_url_candidates() {
	local url=$1 item asset_api
	local -A seen=()
	asset_api="$(download_github_asset_api_url "$url" || true)"
	if [[ -n "$asset_api" ]]; then
		printf '%s\n' "$asset_api"
		seen[$asset_api]=1
	fi
	while IFS= read -r item; do
		[[ -n "$item" && -z "${seen[$item]:-}" ]] || continue
		printf '%s\n' "$item"
		seen[$item]=1
	done < <(download_github_mirror_urls "$url")
	if [[ -z "${seen[$url]:-}" ]]; then
		printf '%s\n' "$url"
		seen[$url]=1
	fi
	while IFS= read -r item; do
		[[ -n "$item" && -z "${seen[$item]:-}" ]] || continue
		printf '%s\n' "$item"
		seen[$item]=1
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

# Доп. заголовки curl для конкретного URL (Assets API требует Accept: application/octet-stream).
download_curl_headers_for_url() {
	local url=$1
	if [[ "$url" =~ ^https://api\.github\.com/repos/[^/]+/[^/]+/releases/assets/[0-9]+/?$ ]]; then
		printf '%s\n' -H 'Accept: application/octet-stream' -H 'User-Agent: 3x-ui-pro-docker-download'
	fi
}

# Одна попытка curl без повторов: таймаут соединения короткий, чтобы быстро перейти к следующему транспорту.
download_via_transport() {
	local url=$1 dest=$2 transport=$3
	local -a args headers=()
	download_set_curl_transport_args "$transport" || return 1
	mapfile -t headers < <(download_curl_headers_for_url "$url" || true)
	args=(
		-fsSL
		--connect-timeout "${DOWNLOAD_CONNECT_TIMEOUT:-5}"
		--max-time "${DOWNLOAD_MAX_TIME:-120}"
		--speed-limit 1
		--speed-time "${DOWNLOAD_STALL_SECONDS:-15}"
		-o "$dest"
	)
	if ((${#headers[@]} > 0)); then
		args+=("${headers[@]}")
	fi
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
