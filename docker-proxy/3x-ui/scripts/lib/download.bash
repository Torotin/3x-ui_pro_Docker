#!/usr/bin/env bash

# Скачивает файл во временный путь и заменяет назначение только после проверки.
download_file_atomic() {
	local url=$1 dest=$2 checksum=${3:-}
	local tmp
	tmp=$(mktemp "${dest}.tmp.XXXXXX")
	rm -f "$tmp"

	log INFO "Downloading $url -> $dest"
	curl -fSL --retry 3 --connect-timeout 5 --max-time 120 -o "$tmp" "$url"
	[[ -s "$tmp" ]] || {
		rm -f "$tmp"
		die "Downloaded file is empty: $url"
	}
	if [[ -n "$checksum" ]]; then
		# Контрольная сумма проверяется до перемещения, чтобы не повредить рабочий файл.
		printf '%s  %s\n' "$checksum" "$tmp" | sha256sum -c - >/dev/null
	fi
	chmod --reference="$dest" "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$dest"
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
