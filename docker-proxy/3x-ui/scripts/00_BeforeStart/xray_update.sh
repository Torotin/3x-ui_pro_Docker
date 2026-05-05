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
: "${XRAY_VERSION:=latest}"
: "${XRAY_SHA256:=}"
XRAY_TMPDIR=

cleanup_xray_tmpdir() {
	[[ -n "${XRAY_TMPDIR:-}" ]] && rm -rf "$XRAY_TMPDIR"
	return 0
}
trap cleanup_xray_tmpdir EXIT

detect_xray_arch() {
	case "$(uname -m)" in
	x86_64)
		XRAY_ARCH=64
		XRAY_FNAME=amd64
		;;
	aarch64)
		XRAY_ARCH=arm64-v8a
		XRAY_FNAME=arm64
		;;
	armv7l)
		XRAY_ARCH=arm32-v7a
		XRAY_FNAME=arm
		;;
	*) die "Unsupported architecture: $(uname -m)" ;;
	esac
}

xray_download_url() {
	if [[ "$XRAY_VERSION" == "latest" ]]; then
		printf 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-%s.zip' "$XRAY_ARCH"
	else
		printf 'https://github.com/XTLS/Xray-core/releases/download/%s/Xray-linux-%s.zip' "$XRAY_VERSION" "$XRAY_ARCH"
	fi
}

main() {
	local tmp zip target backup url version_output
	detect_xray_arch
	url=$(xray_download_url)
	tmp=$(mktemp -d)
	XRAY_TMPDIR=$tmp
	zip="$tmp/xray.zip"
	target="$XUI_BIN_FOLDER/xray-linux-$XRAY_FNAME"
	backup="$target.bak"

	mkdir -p "$XUI_BIN_FOLDER"
	download_file_atomic "$url" "$zip" "$XRAY_SHA256"
	unzip -q "$zip" -d "$tmp"
	[[ -s "$tmp/xray" ]] || die "Archive did not contain xray binary."
	chmod +x "$tmp/xray"
	version_output=$("$tmp/xray" version 2>/dev/null | head -n1 || true)
	[[ -n "$version_output" ]] || die "Downloaded xray binary does not report a version."

	[[ -f "$target" ]] && cp -f "$target" "$backup"
	if ! mv -f "$tmp/xray" "$target"; then
		[[ -f "$backup" ]] && mv -f "$backup" "$target"
		die "Failed to install xray binary; previous binary restored."
	fi
	chmod +x "$target"
	log INFO "Xray installed at $target: $version_output"
	cleanup_xray_tmpdir
	XRAY_TMPDIR=
}

main "$@"
