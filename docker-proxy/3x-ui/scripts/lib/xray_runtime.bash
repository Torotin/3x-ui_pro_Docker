#!/usr/bin/env bash

# Находит исполняемый файл Xray с учетом архитектуры и переопределений окружения.
find_xray_bin() {
	local candidate arch_name
	case "$(uname -m)" in
	x86_64) arch_name=amd64 ;;
	aarch64) arch_name=arm64 ;;
	armv7l) arch_name=arm ;;
	*) arch_name=amd64 ;;
	esac
	for candidate in \
		"${XRAY_BIN_PATH:-}" \
		"${XUI_BIN_FOLDER:-/app/bin}/xray-linux-$arch_name" \
		"${XUI_BIN_FOLDER:-/app/bin}/xray" \
		"$(command -v xray 2>/dev/null || true)"; do
		[[ -n "$candidate" && -x "$candidate" ]] && {
			printf '%s' "$candidate"
			return 0
		}
	done
	return 1
}

# Генерирует WireGuard-ключи и reserved-байты для регистрации WARP.
generate_wg_keys() {
	local xray_bin output hash decoded b1 b2 b3
	xray_bin=$(find_xray_bin) || die "Failed to find xray binary for WARP registration."
	output=$("$xray_bin" wg 2>/dev/null) || die "Failed to run xray wg for WARP registration."
	WG_PRIVATE_KEY=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$output" | head -n1)
	WG_PUBLIC_KEY=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$output" | head -n1)
	[[ -n "$WG_PUBLIC_KEY" ]] || WG_PUBLIC_KEY=$(awk -F': ' '/Password/ {print $2}' <<<"$output" | head -n1)
	hash=$(awk -F': ' '/Hash32/ {print $2}' <<<"$output" | head -n1)
	WG_RESERVED_JSON='[10,14,188]'
	if [[ -n "$hash" ]]; then
		# Новые версии Xray возвращают reserved-байты в Hash32; иначе остается значение по умолчанию.
		decoded=$(printf '%s' "$hash" | base64 -d 2>/dev/null | head -c 3 || true)
		if [[ -n "$decoded" ]]; then
			read -r b1 b2 b3 < <(printf '%s' "$decoded" | od -An -tu1 | tr -s ' ' | sed 's/^ //')
			if [[ -n "${b1:-}" && -n "${b2:-}" && -n "${b3:-}" ]]; then
				WG_RESERVED_JSON="[$b1,$b2,$b3]"
			fi
		fi
	fi
	[[ -n "$WG_PRIVATE_KEY" && -n "$WG_PUBLIC_KEY" ]] || die "xray wg did not return WARP keys."
}

# Извлекает объект WARP из ответа, поддерживая строковое и объектное представление.
extract_warp_obj() {
	local file=$1
	jq -cr 'try (.obj | fromjson) catch (.obj // empty)' "$file"
}

# Нормализует вложенность конфигурации WARP, различающуюся между версиями API.
warp_config_json_from_obj() {
	local obj=$1
	jq -c '.config.config // .config // {}' <<<"$obj"
}

# Получает или регистрирует console WARP outbound и возвращает готовый JSON Xray.
ensure_warp_console_outbound() {
	local current=$1 existing obj config outbound private_key
	existing=$(jq -c '.xraySetting.outbounds[]? | select(.tag=="warp" and .protocol=="wireguard")' <<<"$current" | head -n1)
	if [[ -n "$existing" ]]; then
		# Для существующего outbound обновляется endpoint, но сохраняется его приватный ключ.
		xui_warp_config || true
		if http_success_json; then
			obj=$(extract_warp_obj "$HTTP_BODY_FILE")
			if [[ -n "$obj" && "$obj" != "null" ]]; then
				config=$(warp_config_json_from_obj "$obj")
				private_key=$(jq -r '.settings.secretKey // empty' <<<"$existing")
				if [[ -n "$private_key" ]] && outbound=$(warp_outbound_from_config "$config" "$private_key"); then
					printf '%s' "$outbound"
					return 0
				fi
			fi
		fi
		normalize_warp_outbound_endpoint "$existing"
		return 0
	fi
	if [[ "$WARP_REUSE_PANEL_CONFIG" == "true" ]]; then
		# Сохраненная конфигурация панели используется до создания новой регистрации.
		xui_warp_config || true
		if http_success_json; then
			obj=$(extract_warp_obj "$HTTP_BODY_FILE")
			if [[ -n "$obj" && "$obj" != "null" ]]; then
				config=$(warp_config_json_from_obj "$obj")
				private_key=$(jq -r '.interface.private_key // .config.interface.private_key // .privateKey // empty' <<<"$config")
				if [[ -n "$private_key" ]] && outbound=$(warp_outbound_from_config "$config" "$private_key"); then
					printf '%s' "$outbound"
					return 0
				fi
			fi
		fi
	fi
	if [[ "$MODE" == "plan" ]]; then
		log INFO "PLAN: WARP console registration would be requested."
		return 1
	fi
	generate_wg_keys
	xui_warp_register "$WG_PUBLIC_KEY" "$WG_PRIVATE_KEY" || die "Failed to register WARP through panel API."
	http_success_json || die "WARP registration API failed: $(http_body)"
	obj=$(extract_warp_obj "$HTTP_BODY_FILE")
	[[ -n "$obj" && "$obj" != "null" ]] || die "WARP registration response has no obj."
	config=$(warp_config_json_from_obj "$obj")
	outbound=$(warp_outbound_from_config "$config" "$WG_PRIVATE_KEY" "$WG_RESERVED_JSON") || die "Failed to build WARP outbound from registration response."
	log INFO "WARP registered through panel API."
	printf '%s' "$outbound"
}

# Выбирает локальный AdGuard либо запасной список защищенных DNS-резолверов.
available_dns_servers() {
	local servers='[]'
	if command -v nc >/dev/null 2>&1 && nc -z -w2 adguard 53 2>/dev/null; then
		jq -nc '[{address:"adguard",port:53,skipFallback:false}]'
		return 0
	fi
	local candidates=(
		"https://dns10.quad9.net/dns-query"
		"https://dns.alidns.com/dns-query"
		"https://doh.sandbox.opendns.com/dns-query"
		"https://freedns.controld.com/p0"
		"https://doh.dns.sb/dns-query"
		"https://dns.google/dns-query"
		"https://dns.nextdns.io"
		"https://dns.quad9.net/dns-query"
		"https://dns11.quad9.net/dns-query"
		"https://dns.rabbitdns.org/dns-query"
		"https://basic.rethinkdns.com/"
		"https://wikimedia-dns.org/dns-query"
		"https://doh.libredns.gr/dns-query"
		"https://doh.libredns.gr/ads"
		"https://dns.twnic.tw/dns-query"
		"https://dns.switch.ch/dns-query"
		"tls://dns.alidns.com"
		"tls://sandbox.opendns.com"
		"tls://p0.freedns.controld.com"
		"tls://dot.sb"
		"tls://dns.google"
		"tls://dns.mullvad.net"
		"tls://dns.nextdns.io"
		"tls://dns.quad9.net"
		"tls://dns11.quad9.net"
		"tls://dot.libredns.gr"
	)
	local server
	for server in "${candidates[@]}"; do
		servers=$(jq -c --arg address "$server" '. + [{address:$address,skipFallback:false}]' <<<"$servers")
	done
	printf '%s' "$servers"
}

# Сверяет и применяет управляемый шаблон Xray с доступными DNS, WARP и TOR.
apply_managed_xray() {
	local raw obj current updated dns_servers tmp_file warp_endpoints='[]' tor_available=false tor_endpoints='[]' warp_console_ob=
	if [[ "$XRAY_MANAGED_DNS" != "true" && "$XRAY_MANAGED_TOR" != "true" && "$XRAY_MANAGED_WARP" != "true" ]]; then
		cleanup_managed_xray_artifacts
		return 0
	fi

	xui_get_xray_settings || die "Failed to get Xray settings."
	http_success_json || die "Xray settings API failed: $(http_body)"
	raw=$(jq -r '.obj // empty' "$HTTP_BODY_FILE")
	[[ -n "$raw" ]] || die "Xray response obj is empty."
	current=$(jq -c . <<<"$raw")

	if [[ "$XRAY_MANAGED_WARP" == "true" && "$XRAY_MANAGED_WARP_CONSOLE" == "true" ]]; then
		warp_console_ob=$(ensure_warp_console_outbound "$current" || true)
	elif [[ "$XRAY_MANAGED_WARP" == "true" ]]; then
		log INFO "Console WARP outbound is disabled; managed WARP balancer will use external SOCKS outbounds only."
	fi
	if [[ "$XRAY_MANAGED_WARP" == "true" ]]; then
		if warp_proxy_available "$USQUE_HOST" "$USQUE_PORT"; then
			warp_endpoints=$(jq -c --arg tag "usque" --arg host "$USQUE_HOST" --argjson port "$USQUE_PORT" '. + [{tag:$tag,host:$host,port:$port}]' <<<"$warp_endpoints")
		else
			log INFO "$USQUE_HOST:$USQUE_PORT did not confirm warp=on; excluding usque from Xray managed state."
		fi
	fi
	# Старые артефакты сначала удаляются, затем состояние собирается только из доступных endpoint.
	updated=$(json_remove_managed_xray_artifacts "$current")
	if [[ "$XRAY_MANAGED_TOR" == "true" ]]; then
		if tor_proxy_available "$TOR_PROXY_HOST" "$TOR_PROXY_PORT"; then
			tor_available=true
			tor_endpoints=$(jq -c --arg tag "tor-proxy" --arg host "$TOR_PROXY_HOST" --argjson port "$TOR_PROXY_PORT" '. + [{tag:$tag,host:$host,port:$port}]' <<<"$tor_endpoints")
		else
			log INFO "$TOR_PROXY_HOST:$TOR_PROXY_PORT did not confirm IsTor=true; excluding tor-proxy from Xray managed state."
		fi
	fi
	dns_servers=$(available_dns_servers)
	updated=$(json_apply_managed_xray_state "$updated" "$dns_servers" "$XRAY_MANAGED_WARP" "$tor_available" "$XRAY_MANAGED_DNS" "$warp_endpoints" "$WEBDOMAIN" "$tor_endpoints" "$warp_console_ob")

	if json_equal "$current" "$updated"; then
		log INFO "Xray settings already match managed desired state."
		return 0
	fi

	if plan_or_apply "xray settings updated"; then
		# Панель принимает именно содержимое xraySetting, а не внешний объект ответа API.
		obj=$(jq -c '.xraySetting | .xrayTemplateConfig = (.xrayTemplateConfig // {})' <<<"$updated")
		tmp_file="$TMP_ROOT/xraysetting.json"
		printf '%s' "$obj" >"$tmp_file"
		xui_update_xray_settings "$tmp_file" || die "Failed to update Xray settings."
		http_success_json || die "Xray update failed: $(http_body)"
		RESTART_PANEL_REQUIRED=1
		RESTART_XRAY_REQUIRED=1
	fi
}

# Удаляет ранее управляемые Xray-артефакты, если интеграции полностью выключены.
cleanup_managed_xray_artifacts() {
	local raw current updated obj tmp_file
	xui_get_xray_settings || {
		log WARN "Managed Xray cleanup skipped: failed to read Xray settings."
		return 0
	}
	http_success_json || {
		log WARN "Managed Xray cleanup skipped: API returned failure."
		return 0
	}
	raw=$(jq -r '.obj // empty' "$HTTP_BODY_FILE")
	[[ -n "$raw" ]] || {
		log INFO "Managed Xray cleanup skipped: empty Xray settings."
		return 0
	}
	current=$(jq -c . <<<"$raw")
	updated=$(json_remove_managed_xray_artifacts "$current")
	if json_equal "$current" "$updated"; then
		log INFO "Managed Xray template update skipped; no old managed artifacts found."
		return 0
	fi
	if plan_or_apply "old managed xray artifacts removed"; then
		obj=$(jq -c '.xraySetting | .xrayTemplateConfig = (.xrayTemplateConfig // {})' <<<"$updated")
		tmp_file="$TMP_ROOT/xraysetting-cleanup.json"
		printf '%s' "$obj" >"$tmp_file"
		xui_update_xray_settings "$tmp_file" || die "Failed to cleanup managed Xray settings."
		http_success_json || die "Managed Xray cleanup failed: $(http_body)"
		RESTART_PANEL_REQUIRED=1
	fi
}

# Ожидает появления TCP listener после перезапуска управляемого Xray.
wait_tcp_port() {
	local host=$1 port=$2 timeout=${3:-30} elapsed=0 label
	label=${4:-"$host:$port"}
	while ((elapsed < timeout)); do
		if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
			exec 3<&-
			exec 3>&-
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	log WARN "Timed out waiting for $label after ${timeout}s."
	return 1
}

# Проверяет, что оба создаваемых inbound снова слушают после рестарта.
wait_managed_xray_ports() {
	local timeout=${XRAY_RESTART_PORT_TIMEOUT:-30} failed=0
	wait_tcp_port 127.0.0.1 "$PORT_LOCAL_VISION" "$timeout" "Vision inbound ${PORT_LOCAL_VISION}" || failed=1
	wait_tcp_port 127.0.0.1 "$PORT_LOCAL_XHTTP" "$timeout" "XHTTP inbound ${PORT_LOCAL_XHTTP}" || failed=1
	return "$failed"
}

# Выполняет требуемые рестарты и проверяет возврат управляемых портов.
restart_if_needed() {
	local restart_sent=0
	if [[ "$MODE" != "apply" ]]; then
		log INFO "Restart skipped in MODE=$MODE."
		return 0
	fi
	# Xray перезапускается первым, пока текущий endpoint панели еще доступен.
	if ((RESTART_XRAY_REQUIRED == 1)); then
		xui_restart_xray || log WARN "Xray restart request failed: $(http_body)"
		restart_sent=1
	fi
	if ((RESTART_PANEL_REQUIRED == 1)); then
		xui_restart_panel || log WARN "Panel restart request failed: $(http_body)"
		restart_sent=1
	fi
	if ((restart_sent == 1)); then
		sleep "${XRAY_RESTART_SETTLE_SECONDS:-5}"
		wait_managed_xray_ports || log WARN "One or more managed Xray inbounds are not listening after restart."
	fi
}
