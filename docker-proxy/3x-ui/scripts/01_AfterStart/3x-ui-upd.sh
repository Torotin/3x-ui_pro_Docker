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
TMP_ROOT=
CHANGE_COUNT=0
RESTART_PANEL_REQUIRED=0
RESTART_XRAY_REQUIRED=0
ENSURE_INBOUND_ID=

# shellcheck source=../lib/log.bash
. "$LIB_DIR/log.bash"
# shellcheck source=../lib/env.bash
. "$LIB_DIR/env.bash"
# shellcheck source=../lib/http.bash
. "$LIB_DIR/http.bash"
# shellcheck source=../lib/3xui_api.bash
. "$LIB_DIR/3xui_api.bash"
# shellcheck source=../lib/json_state.bash
. "$LIB_DIR/json_state.bash"
# shellcheck source=../lib/desired_state.bash
. "$LIB_DIR/desired_state.bash"
# shellcheck source=../lib/runtime_common.bash
. "$LIB_DIR/runtime_common.bash"
# shellcheck source=../lib/panel_runtime.bash
. "$LIB_DIR/panel_runtime.bash"
# shellcheck source=../lib/inbound_runtime.bash
. "$LIB_DIR/inbound_runtime.bash"
# shellcheck source=../lib/xray_runtime.bash
. "$LIB_DIR/xray_runtime.bash"

# Удаляет временный каталог HTTP-ответов и подготовленных JSON при завершении.
cleanup() {
	[[ -n "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Запускает полный цикл панели и Xray в выбранном режиме.
main() {
	local desired vision_id xhttp_id
	TMP_ROOT=$(mktemp -d)
	http_init "$TMP_ROOT"
	load_runtime_env "$SCRIPT_DIR"
	require_apply_mode
	check_dependencies
	log INFO "3x-ui managed runtime started MODE=$MODE"

	if [[ "$MODE" == "check" ]]; then
		log INFO "Dependency and environment check passed."
		return 0
	fi

	# Панель может сменить адрес или учетные данные, поэтому вход повторяется после настройки.
	resolve_panel_base || die "Could not resolve and login to 3x-ui panel."
	detect_country_flag || true
	desired=$(build_desired_state)
	ensure_panel_settings
	update_admin_credentials_if_needed
	resolve_panel_base || die "Could not login after panel settings update."
	ensure_custom_geo_resources
	update_builtin_geofiles_if_enabled

	ensure_inbound vision "$desired"
	vision_id=$ENSURE_INBOUND_ID
	ensure_inbound xhttp "$desired"
	xhttp_id=$ENSURE_INBOUND_ID
	ensure_shared_client "$vision_id" "$xhttp_id" "$desired"
	apply_managed_xray
	restart_if_needed
	log INFO "3x-ui managed runtime complete: changes=$CHANGE_COUNT panel_restart=$RESTART_PANEL_REQUIRED xray_restart=$RESTART_XRAY_REQUIRED"
}

main "$@"
