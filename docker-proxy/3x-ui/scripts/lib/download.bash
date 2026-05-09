#!/usr/bin/env bash

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
		printf '%s  %s\n' "$checksum" "$tmp" | sha256sum -c - >/dev/null
	fi
	chmod --reference="$dest" "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$dest"
}

parse_download_entry() {
	local entry=$1
	DOWNLOAD_URL=${entry%%|*}
	local rest=${entry#*|}
	DOWNLOAD_NAME=
	DOWNLOAD_SHA256=
	if [[ "$rest" != "$entry" ]]; then
		DOWNLOAD_NAME=${rest%%|*}
		if [[ "$rest" == *"|"* ]]; then
			# shellcheck disable=SC2034 # exported parser result consumed by callers
			DOWNLOAD_SHA256=${rest#*|}
		fi
	fi
	if [[ -z "$DOWNLOAD_NAME" ]]; then
		DOWNLOAD_NAME=$(basename "${DOWNLOAD_URL%%\?*}")
	fi
}
