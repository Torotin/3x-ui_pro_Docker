#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
	exec /usr/bin/env bash "$0" "$@"
fi
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR=${LIB_DIR:-"$SCRIPT_DIR/../lib"}
if [[ ! -f "$LIB_DIR/log.bash" && -f /mnt/sh/lib/log.bash ]]; then
	LIB_DIR=/mnt/sh/lib
fi

# shellcheck source=../lib/log.bash
. "$LIB_DIR/log.bash"
# shellcheck source=../lib/download.bash
. "$LIB_DIR/download.bash"

: "${XUI_BIN_FOLDER:=/app/bin}"
: "${URL_LIST_FILE:=}"
: "${DOWNLOAD_GEO_DIRECT:=false}"

URL_LIST_DEFAULT='https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geosite.dat|geosite_refilter.dat
https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat|geosite_v2fly.dat
https://github.com/jameszeroX/zkeen-domains/releases/latest/download/zkeen.dat|geosite_zkeen.dat
https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat|geoip_zkeenip.dat
https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat|geoip_v2fly.dat
https://github.com/1andrevich/Re-filter-lists/releases/latest/download/geoip.dat|geoip_refilter.dat
https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat|adlist.dat'

main() {

	local entry dest source_file
	if [[ "$DOWNLOAD_GEO_DIRECT" != "true" ]]; then
		log INFO "Direct dat-file download is disabled; custom geo files are managed through the 3x-ui API after startup."
		return 0
	fi

	mkdir -p "$XUI_BIN_FOLDER"
	log INFO "Downloading data files into $XUI_BIN_FOLDER"

	if [[ -n "$URL_LIST_FILE" && -r "$URL_LIST_FILE" ]]; then
		source_file=$URL_LIST_FILE
	else
		source_file=$(mktemp)
		printf '%s\n' "$URL_LIST_DEFAULT" >"$source_file"
		trap 'rm -f "$source_file"' RETURN
	fi

	while IFS= read -r entry || [[ -n "$entry" ]]; do
		entry=${entry#"${entry%%[![:space:]]*}"}
		entry=${entry%"${entry##*[![:space:]]}"}
		[[ -n "$entry" && "${entry:0:1}" != "#" ]] || continue
		parse_download_entry "$entry"
		dest="$XUI_BIN_FOLDER/$DOWNLOAD_NAME"
		download_file_atomic "$DOWNLOAD_URL" "$dest" "$DOWNLOAD_SHA256"
	done <"$source_file"

	log INFO "Data files are up to date."

}

main "$@"
