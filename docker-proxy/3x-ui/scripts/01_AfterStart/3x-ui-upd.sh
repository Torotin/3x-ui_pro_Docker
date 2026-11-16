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
ENSURE_SHARED_CLIENT_ID=
# shellcheck disable=SC2034 # set by inbound runtime and read during per-inbound client synchronization
ENSURE_SHARED_CLIENT_PASSWORD=
# shellcheck disable=SC2034 # set by inbound runtime and read by Hysteria sync after shared client reconciliation
ENSURE_SHARED_CLIENT_AUTH=

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
# shellcheck source=../lib/parity_hooks.bash
. "$LIB_DIR/parity_hooks.bash"

# Удаляет временный каталог HTTP-ответов и подготовленных JSON при завершении.
cleanup() {
	[[ -n "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Сверяет bash build_desired_state с Python (только XUI_RUNTIME_ENGINE=dual).
assert_dual_desired_parity() {
	local desired_json=$1 py_root bash_json_file
	[[ "$XUI_RUNTIME_ENGINE" == "dual" ]] || return 0
	py_root=/mnt/sh/python
	if [[ ! -d "$py_root" ]]; then
		py_root="$SCRIPT_DIR/../python"
	fi
	export PYTHONPATH="$py_root${PYTHONPATH:+:$PYTHONPATH}"
	bash_json_file=$(mktemp "$TMP_ROOT/desired-bash.XXXXXX")
	printf '%s' "$desired_json" >"$bash_json_file"
	python3 -m xui_runtime.parity desired --bash-json-file "$bash_json_file" \
		|| die "Python desired-state parity failed"
}

# Запускает полный цикл панели и Xray в выбранном режиме.
main() {
	local desired vision_id xhttp_id grpc_id="" hysteria2_id="" amneziawg_id="" udp_backend nodes_file remarks_file
	TMP_ROOT=$(mktemp -d)
	http_init "$TMP_ROOT"
	load_runtime_env "$SCRIPT_DIR"
	XUI_RUNTIME_ENGINE=${XUI_RUNTIME_ENGINE:-bash}
	XUI_RUNTIME_ENGINE=${XUI_RUNTIME_ENGINE,,}
	export XUI_RUNTIME_ENGINE
	case "$XUI_RUNTIME_ENGINE" in
	bash | dual | python) ;;
	*) die "XUI_RUNTIME_ENGINE must be bash|dual|python" ;;
	esac
	require_apply_mode
	check_dependencies
	if [[ "$XUI_RUNTIME_ENGINE" == "python" ]]; then
		local python_root=/mnt/sh/python
		if [[ ! -d "$python_root" ]]; then
			python_root="$SCRIPT_DIR/../python"
		fi
		export PYTHONPATH="$python_root${PYTHONPATH:+:$PYTHONPATH}"
		exec python3 -m xui_runtime --mode "$MODE"
	fi
	# shellcheck source=../lib/sub_admin_routing.bash
	. "$LIB_DIR/sub_admin_routing.bash"
	# shellcheck source=../lib/sub_balancer.bash
	. "$LIB_DIR/sub_balancer.bash"
	# Soft builders for MODE=check (no desired/panel). Final Clash+observatory
	# passed into panel settings apply are rebuilt below once desired remarks exist.
	subClashEnableRouting=true
	_mihomo_routing=
	_mihomo_routing=$(mihomo_client_routing_file) || _mihomo_routing=
	if [[ -n "$_mihomo_routing" && -n "${WEBDOMAIN:-}" ]]; then
		subClashRules=$(build_mihomo_client_sub_clash_rules "$_mihomo_routing" "${WEBDOMAIN}" "${PUBLIC_IPV4:-}")
	else
		subClashRules=$(build_admin_sub_clash_rules "${WEBDOMAIN}" "${PUBLIC_IPV4:-}" "$(admin_sub_clash_default_mode)")
	fi
	export subClashEnableRouting subClashRules
	# JSON clients use subJsonRules; legacy subJsonRoutingRules must be cleared.
	subJsonRules=$(build_admin_sub_json_rules "${WEBDOMAIN}")
	subJsonDns=$(build_admin_sub_json_dns "${WEBDOMAIN}" "${PUBLIC_IPV4:-}")
	CLEAR_SUB_JSON_ROUTING_RULES=true
	if [[ -n "$subJsonRules" ]]; then
		export subJsonRules
	fi
	if [[ -n "$subJsonDns" ]]; then
		export subJsonDns
	fi
	export CLEAR_SUB_JSON_ROUTING_RULES
	if [[ -z "${PUBLIC_IPV4:-}" ]]; then
		log WARN "PUBLIC_IPV4 empty: admin Clash/JSON hosts maps omitted"
	fi
	log INFO "3x-ui managed runtime started MODE=$MODE engine=$XUI_RUNTIME_ENGINE"

	if [[ "$MODE" == "check" ]]; then
		log INFO "Dependency and environment check passed."
		# Same URL dump as apply: env + stable shared subId (no panel required).
		desired=$(build_desired_state)
		log_shared_autogen_subscription_urls "$desired"
		assert_dual_desired_parity "$desired"
		assert_dual_stream_builders_parity "$desired"
		assert_dual_sub_builders_parity
		return 0
	fi

	# Панель может сменить адрес или учетные данные, поэтому вход повторяется после настройки.
	resolve_panel_base || die "Could not resolve and login to 3x-ui panel."
	detect_country_flag || true
	desired=$(build_desired_state)
	assert_dual_desired_parity "$desired"
	assert_dual_stream_builders_parity "$desired"
	assert_dual_sub_builders_parity
	# AUTO/PROXY groups need node names; prefer desired inbound remarks (chicken-egg
	# vs live inbounds that may not exist yet).
	nodes_file=$(mktemp "$TMP_ROOT/clash-nodes.XXXXXX")
	remarks_file=$(mktemp "$TMP_ROOT/clash-remarks.XXXXXX")
	# Only remarks for kinds AfterStart will ensure (grpc/hysteria2 follow ENABLE_*).
	# Vision/Reality Clash nodes are published as remark-WEBDOMAIN-email (externalProxy).
	shared_email=$(jq -r '.clients.shared.email // empty' <<<"$desired")
	{
		vision_remark=$(jq -r '.inbounds.vision.remark // empty' <<<"$desired")
		clash_subscription_proxy_name_for_kind vision "$vision_remark" "${WEBDOMAIN:-}" "$shared_email"
		jq -r '.inbounds.xhttp.remark // empty' <<<"$desired"
		if [[ "${ENABLE_VLESS_GRPC:-false}" == "true" ]]; then
			jq -r '.inbounds.grpc.remark // empty' <<<"$desired"
		fi
		if [[ "${ENABLE_AMNEZIAWG:-false}" == "true" ]]; then
			jq -r '.inbounds.amneziawg.remark // empty' <<<"$desired"
		fi
		if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
			jq -r '.inbounds.hysteria2.remark // empty' <<<"$desired"
		fi
	} | grep -E . >"$remarks_file" || true
	_mihomo_routing=
	_mihomo_routing=$(mihomo_client_routing_file) || _mihomo_routing=
	if [[ -n "$_mihomo_routing" && -n "${WEBDOMAIN:-}" ]]; then
		# Mihomo overlay uses include-all PROXY/AUTO; node discovery not required.
		log INFO "Clash routing: mihomo client overlay $_mihomo_routing"
		subClashRules=$(build_mihomo_client_sub_clash_rules "$_mihomo_routing" "${WEBDOMAIN}" "${PUBLIC_IPV4:-}")
	else
		CLASH_PROXY_NODE_REMARKS_FILE=$remarks_file \
			discover_clash_proxy_node_names >"$nodes_file" || true
		if [[ ! -s "$nodes_file" ]]; then
			log WARN "Clash node names undiscoverable: omitting custom proxy-groups"
		fi
		subClashRules=$(build_admin_sub_clash_rules "${WEBDOMAIN}" "${PUBLIC_IPV4:-}" "$(admin_sub_clash_default_mode)" "$nodes_file")
	fi
	assert_dual_sub_builders_parity "$nodes_file"
	export subClashEnableRouting=true subClashRules
	subJsonObservatory=$(build_admin_sub_json_observatory)
	export subJsonObservatory
	# Managed outbounds (usque/tor/…) must exist before panelOutbound injection,
	# otherwise 3x-ui logs: panel egress: target tag [ usque ] not found.
	apply_managed_xray
	restart_xray_if_needed
	ensure_panel_settings
	update_admin_credentials_if_needed
	resolve_panel_base || die "Could not login after panel settings update."
	repair_inbound_client_tg_ids_db

	ensure_xray_tls_certificate "$(jq -r '.tls.certFile' <<<"$desired")" "$(jq -r '.tls.keyFile' <<<"$desired")"
	ensure_inbound vision "$desired"
	vision_id=$ENSURE_INBOUND_ID
	ensure_inbound xhttp "$desired"
	xhttp_id=$ENSURE_INBOUND_ID
	if [[ "${ENABLE_VLESS_GRPC:-false}" == "true" ]]; then
		ensure_inbound grpc "$desired"
		grpc_id=$ENSURE_INBOUND_ID
	fi
	udp_backend=${UDP443_BACKEND:-}
	if [[ -z "$udp_backend" ]]; then
		if [[ "${ENABLE_AMNEZIAWG:-false}" == "true" ]]; then
			udp_backend=amneziawg
		elif [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
			udp_backend=hysteria2
		else
			udp_backend=off
		fi
	fi
	case "$udp_backend" in
	amneziawg)
		delete_managed_inbound_kind hysteria2 "$desired"
		ensure_inbound amneziawg "$desired"
		amneziawg_id=$ENSURE_INBOUND_ID
		sync_amneziawg_profile "$amneziawg_id" "$desired"
		;;
	hysteria2)
		delete_managed_inbound_kind amneziawg "$desired"
		ensure_inbound hysteria2 "$desired"
		hysteria2_id=$ENSURE_INBOUND_ID
		;;
	off)
		delete_managed_inbound_kind amneziawg "$desired"
		delete_managed_inbound_kind hysteria2 "$desired"
		;;
	*)
		die "UDP443_BACKEND invalid: $udp_backend"
		;;
	esac
	if [[ "${ENABLE_TELEMT:-false}" == "true" ]]; then
		ensure_inbound mixed "$desired"
	fi
	# Shared client must receive every script-managed inbound (VLESS + active UDP443).
	ensure_shared_client "$vision_id" "$xhttp_id" "$grpc_id" "$hysteria2_id" "$amneziawg_id" "$desired"
	if [[ "${ENABLE_VLESS_GRPC:-false}" == "true" ]]; then
		ensure_grpc_client "$grpc_id" "$ENSURE_SHARED_CLIENT_ID" "$desired"
	fi
	if [[ "$udp_backend" == "hysteria2" && -n "$hysteria2_id" ]]; then
		ensure_hysteria2_client "$hysteria2_id" "$desired"
	fi
	repair_shared_client_after_inbound_sync "$desired" "$vision_id" "$xhttp_id" "$grpc_id"
	# Inbounds are created after the early outbound restart; restart again so
	# Vision/XHTTP/gRPC/Hysteria listeners exist, then wait for them.
	restart_xray_if_needed
	wait_managed_xray_ports || log WARN "One or more managed Xray inbounds are not listening after inbound sync."
	ensure_auto_sub_balancer "$vision_id" "$xhttp_id" "$grpc_id" "$hysteria2_id"
	update_builtin_geofiles_if_enabled
	restart_panel_if_needed
	log INFO "3x-ui managed runtime complete: changes=$CHANGE_COUNT panel_restart=$RESTART_PANEL_REQUIRED xray_restart=$RESTART_XRAY_REQUIRED"
	log_shared_autogen_subscription_urls "$desired"
}

main "$@"
