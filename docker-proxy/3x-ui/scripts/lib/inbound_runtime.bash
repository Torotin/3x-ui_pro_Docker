#!/usr/bin/env bash

# Определяет флаг страны по публичному IP для человекочитаемых имен inbound.
detect_country_flag() {
	log INFO "Detecting country flag by public IP."
	EMOJI_FLAG="⚠"

	local src jqpath mode resp value emoji
	local curl_opts=(-sS --fail --location --retry 1 --connect-timeout 2 --max-time 4 -H "Accept:application/json")

	# Источники проверяются по очереди; недоступный сервис не блокирует запуск.
	while IFS='|' read -r src jqpath mode || [[ -n "${src:-}" ]]; do
		[[ -n "$src" ]] || continue
		[[ -n "$mode" ]] || mode=emoji

		if ! resp=$(curl "${curl_opts[@]}" "$src" 2>/dev/null); then
			log WARN "$src: country flag request failed."
			continue
		fi

		if [[ "$mode" != "trace_loc" ]] && ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
			log WARN "$src: country flag response is not valid JSON."
			continue
		fi

		if [[ "$mode" == "trace_loc" ]]; then
			value=$resp
		else
			value=$(printf '%s' "$resp" | jq -r "$jqpath // empty" 2>/dev/null || true)
		fi
		emoji=$(country_flag_value "$mode" "$value" 2>/dev/null || true)

		if [[ -n "$emoji" ]]; then
			EMOJI_FLAG=$emoji
			export EMOJI_FLAG
			log INFO "Country flag ($src): $EMOJI_FLAG"
			return 0
		fi

		log WARN "$src: country flag value is empty."
	done < <(country_flag_sources)

	export EMOJI_FLAG
	log WARN "Country flag was not detected, using ⚠."
	return 1
}

# Получает массив входящих подключений из API панели.
inbounds_json() {
	xui_list_inbounds || die "Failed to list inbounds."
	http_success_json || die "Inbound list API failed: $(http_body)"
	jq -c '.obj // []' "$HTTP_BODY_FILE"
}

# Получает массив общих клиентских объектов из API панели 3.1.
clients_json() {
	xui_list_clients || die "Failed to list clients."
	http_success_json || die "Client list API failed: $(api_error_summary)"
	jq -c '.obj // []' "$HTTP_BODY_FILE"
}

# Находит идентификатор inbound по уникальной паре порта и протокола.
find_inbound_by_port() {
	local inbounds=$1 port=$2 protocol=$3
	jq -r --argjson port "$port" --arg protocol "$protocol" '
      .[] | select((.port|tonumber) == $port and .protocol == $protocol) | .id
    ' <<<"$inbounds" | head -n1
}

# Запрещает перезаписывать inbound на занятом порту, если он не управляется runtime.
managed_conflict_check() {
	local inbound=$1 expected_remarks_json=$2 port=$3
	[[ -n "$inbound" && "$inbound" != "null" ]] || return 0
	local remark
	remark=$(jq -r '.remark // ""' <<<"$inbound")
	if ! jq -ne --arg remark "$remark" --argjson expected "$expected_remarks_json" '
      $expected | any(. as $expectedRemark | $remark == $expectedRemark or ($remark | contains($expectedRemark)))
    ' >/dev/null; then
		die "Inbound port $port is occupied by unmanaged inbound remark='$remark'. Refusing to overwrite."
	fi
}

# Генерирует UUID клиента через ядро либо запасной генератор.
new_uuid() {
	if [[ -r /proc/sys/kernel/random/uuid ]]; then
		cat /proc/sys/kernel/random/uuid
	else
		jq -nr 'now|tostring|@base64' | sha256sum | cut -c1-32
	fi
}

# Генерирует набор случайных shortId для REALITY inbound.
generate_short_ids_json() {
	local count=${1:-8} max_bytes=${2:-8} ids='[]' raw len hex i
	for ((i = 0; i < count; i++)); do
		raw=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ' || printf '4')
		len=$((2 + raw % (max_bytes - 1)))
		if command -v openssl >/dev/null 2>&1; then
			hex=$(openssl rand -hex "$len" 2>/dev/null)
		else
			hex=$(head -c "$len" /dev/urandom | od -An -vtx1 | tr -d ' \n')
		fi
		ids=$(jq -c --arg id "$hex" '. + [$id]' <<<"$ids")
	done
	printf '%s' "$ids"
}

# Выбирает параметры VLESS-аутентификации, предпочитая post-quantum вариант панели.
get_vless_auth() {
	if [[ "$USE_VLESS_PQ" != "true" ]]; then
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_DEC=none
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_ENC=none
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_LABEL=
		return 0
	fi
	xui_get_vless_enc || return 1
	if http_success_json; then
		local picked
		picked=$(jq -c '.obj.auths[]? | select((.label // "" | ascii_downcase | contains("post-quantum")) or (.label // "" | ascii_downcase | contains("ml-kem"))) // empty' "$HTTP_BODY_FILE" | head -n1)
		[[ -n "$picked" ]] || picked=$(jq -c '.obj.auths[0] // empty' "$HTTP_BODY_FILE")
		VLESS_DEC=$(jq -r '.decryption // "none"' <<<"$picked")
		VLESS_ENC=$(jq -r '.encryption // "none"' <<<"$picked")
		VLESS_LABEL=$(jq -r '.label // ""' <<<"$picked")
	else
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_DEC=none
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_ENC=none
		# shellcheck disable=SC2034 # используется в build_vless_settings_json из desired_state.bash
		VLESS_LABEL=
		log WARN "VLESS auth API failed; falling back to none."
	fi
}

# Запрашивает у панели пару ключей X25519 для нового REALITY inbound.
get_x25519_keys() {
	xui_get_x25519 || return 1
	http_success_json || return 1
	X25519_PRIVATE_KEY=$(jq -r '.obj.privateKey // empty' "$HTTP_BODY_FILE")
	X25519_PUBLIC_KEY=$(jq -r '.obj.publicKey // empty' "$HTTP_BODY_FILE")
	[[ -n "$X25519_PRIVATE_KEY" && -n "$X25519_PUBLIC_KEY" ]]
}

# Строит streamSettings нового inbound, сохраняя существующий Vision stream.
build_inbound_stream_json() {
	local kind=$1 current=${2:-}
	if [[ -n "$current" && "$current" != "null" && "$kind" == "vision" ]]; then
		# Существующие ключи REALITY нельзя регенерировать при повторной сверке состояния.
		json_field_object "$current" streamSettings
		return 0
	fi

	if [[ "$kind" == "vision" ]]; then
		get_x25519_keys || die "Failed to get X25519 keys for Vision inbound."
		build_vision_stream_json "${REALITY_TARGET_HOST:-telemt}:${REALITY_TARGET_PORT:-${PORT_LOCAL_TELEMT_PROXY:-9443}}" "$WEBDOMAIN" "$X25519_PRIVATE_KEY" "$X25519_PUBLIC_KEY" "$(generate_short_ids_json 8 8)" "$(build_sockopt_json false AsIs off)" "" "" "${REALITY_TARGET_XVER:-1}"
	else
		build_xhttp_stream_json "$URI_VLESS_XHTTP" "$WEBDOMAIN"
	fi
}

# Собирает все компоненты нового inbound для передачи в API панели.
build_inbound_components_json() {
	local kind=$1 desired=$2 current=${3:-}
	local settings stream sniffing allocate port remark protocol
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	remark=$(jq -r ".inbounds.$kind.remark" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	settings=$(build_vless_settings_json "$kind" "$current")
	stream=$(build_inbound_stream_json "$kind" "$current")
	sniffing=$(jq -nc '{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false}')
	allocate=$(jq -nc '{}')
	jq -nc \
		--argjson port "$port" \
		--arg remark "$remark" \
		--arg protocol "$protocol" \
		--argjson settings "$settings" \
		--argjson stream "$stream" \
		--argjson sniffing "$sniffing" \
		--argjson allocate "$allocate" '{
          up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
          listen:"", port:$port, protocol:$protocol, settings:$settings,
          streamSettings:$stream, sniffing:$sniffing, allocate:$allocate
        }'
}

# Преобразует JSON-компоненты inbound в параметры form-urlencoded API.
inbound_components_payload() {
	local components=$1
	printf '%s\0' \
		--data-urlencode "up=0" \
		--data-urlencode "down=0" \
		--data-urlencode "total=0" \
		--data-urlencode "remark=$(jq -r '.remark' <<<"$components")" \
		--data-urlencode "enable=true" \
		--data-urlencode "expiryTime=0" \
		--data-urlencode "listen=" \
		--data-urlencode "port=$(jq -r '.port' <<<"$components")" \
		--data-urlencode "protocol=$(jq -r '.protocol' <<<"$components")" \
		--data-urlencode "settings=$(jq -c '.settings' <<<"$components")" \
		--data-urlencode "streamSettings=$(jq -c '.streamSettings' <<<"$components")" \
		--data-urlencode "sniffing=$(jq -c '.sniffing' <<<"$components")" \
		--data-urlencode "allocate=$(jq -c '.allocate' <<<"$components")"
}

# Нормализует сохраненный inbound в JSON для сравнения с желаемой структурой.
current_inbound_components_json() {
	local inbound=$1
	jq -c '{
      up:(.up // 0),
      down:(.down // 0),
      total:(.total // 0),
      remark:(.remark // ""),
      enable:(.enable // true),
      expiryTime:(.expiryTime // 0),
      listen:(.listen // ""),
      port:(.port|tonumber),
      protocol:(.protocol // ""),
      settings:(.settings | fromjson? // . // {}),
      streamSettings:(.streamSettings | fromjson? // . // {}),
      sniffing:(.sniffing | fromjson? // . // {}),
      allocate:(.allocate | fromjson? // . // {})
    }' <<<"$inbound"
}

# Создает отсутствующий управляемый inbound и сохраняет его идентификатор.
ensure_inbound() {
	local kind=$1 desired=$2 inbounds id port protocol inbound args desired_components expected_remarks
	ENSURE_INBOUND_ID=
	inbounds=$(inbounds_json)
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	expected_remarks=$(managed_inbound_remarks_json "$kind" "$desired")
	id=$(find_inbound_by_port "$inbounds" "$port" "$protocol")
	inbound=$(jq -c --arg id "$id" '.[] | select((.id|tostring)==$id)' <<<"$inbounds" | head -n1)
	managed_conflict_check "$inbound" "$expected_remarks" "$port"

	if [[ -n "$id" ]]; then
		# Существующий управляемый inbound сохраняется, чтобы не менять действующие ключи и клиентов.
		log INFO "$kind inbound already exists id=$id port=$port; preserving existing configuration."
		ENSURE_INBOUND_ID=$id
	else
		desired_components=$(build_inbound_components_json "$kind" "$desired")
		mapfile -d '' -t args < <(inbound_components_payload "$desired_components")
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: $kind inbound created port=$port"
			return 0
		fi
		record_change "APPLY: $kind inbound created port=$port"
		xui_add_inbound "${args[@]}" || die "Failed to add $kind inbound."
		http_success_json || die "$kind inbound add failed: $(http_body)"
		RESTART_XRAY_REQUIRED=1
		# shellcheck disable=SC2034 # идентификатор читается entrypoint после вызова функции
		ENSURE_INBOUND_ID=$(jq -r '.obj.id // empty' "$HTTP_BODY_FILE")
	fi
}

# Создает либо синхронизирует одного общего клиента для Vision и XHTTP inbound.
ensure_shared_client() {
	local vision_id=$1 xhttp_id=$2 desired=$3 clients email sub_id flow current client_id client target_ids missing_ids attach_payload changed=0
	email=$(jq -r '.clients.shared.email' <<<"$desired")
	sub_id=$(jq -r '.clients.shared.subId' <<<"$desired")
	flow=$(jq -r '.clients.shared.flow' <<<"$desired")
	target_ids=$(jq -nc --argjson vision "$vision_id" --argjson xhttp "$xhttp_id" '[$vision, $xhttp]')
	clients=$(clients_json)
	current=$(jq -c --arg email "$email" '.[]? | select(.email == $email)' <<<"$clients" | head -n1)

	if [[ -z "$current" ]]; then
		# Новый API создает клиента сразу с двумя привязками одной мутацией.
		client_id=$(new_uuid)
		client=$(vless_client_api_json "$client_id" "$email" "$sub_id" "$flow")
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: shared client created email=$email inbounds=$vision_id,$xhttp_id"
			return 0
		fi
		record_change "APPLY: shared client created email=$email inbounds=$vision_id,$xhttp_id"
		xui_add_client "$(vless_client_create_payload_json "$target_ids" "$client")" || die "Failed to add shared client."
		http_success_json || die "shared client add failed: $(api_error_summary)"
		RESTART_XRAY_REQUIRED=1
		return 0
	fi

	client_id=$(jq -r '.uuid // .id // empty' <<<"$current")
	[[ -n "$client_id" ]] || die "Existing shared client email=$email has no VLESS identifier."
	client=$(vless_client_api_json "$client_id" "$email" "$sub_id" "$flow")
	if ! jq -e --arg sid "$sub_id" --arg flow "$flow" '(.subId // "") == $sid and (.flow // "") == $flow' <<<"$current" >/dev/null; then
		if plan_or_apply "shared client updated email=$email"; then
			xui_update_client "$email" "$client" || die "Failed to update shared client."
			http_success_json || die "shared client update failed: $(api_error_summary)"
			RESTART_XRAY_REQUIRED=1
		fi
		changed=1
	fi

	missing_ids=$(jq -c --argjson target "$target_ids" '$target - (.inboundIds // [])' <<<"$current")
	if [[ "$(jq 'length' <<<"$missing_ids")" != "0" ]]; then
		# Уже существующему клиенту добавляются только еще отсутствующие inbound.
		attach_payload=$(jq -nc --argjson inboundIds "$missing_ids" '{inboundIds:$inboundIds}')
		if plan_or_apply "shared client attached email=$email inbounds=$(jq -r 'join(\",\")' <<<"$missing_ids")"; then
			xui_attach_client "$email" "$attach_payload" || die "Failed to attach shared client."
			http_success_json || die "shared client attach failed: $(api_error_summary)"
			# shellcheck disable=SC2034 # флаг рестарта читается Xray-модулем/entrypoint
			RESTART_XRAY_REQUIRED=1
		fi
		changed=1
	fi

	if ((changed == 0)); then
		log INFO "shared client already attached email=$email inbounds=$vision_id,$xhttp_id."
	fi
}
