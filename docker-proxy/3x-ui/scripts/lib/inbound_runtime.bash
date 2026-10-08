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

# Генерирует секрет для inbound-level клиентов без вывода значения в лог.
new_client_secret() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 16
	else
		head -c 16 /dev/urandom | od -An -vtx1 | tr -d ' \n'
	fi
}

# Нормализует VLESS UUID из канонической или 32-hex формы, которую 3x-ui может
# хранить в разных полях first-class client.
normalize_uuid() {
	local value=${1:-}
	value=${value,,}
	if [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
		printf '%s' "$value"
	elif [[ "$value" =~ ^[0-9a-f]{12}[1-8][0-9a-f]{3}[89ab][0-9a-f]{15}$ ]]; then
		printf '%s-%s-%s-%s-%s' "${value:0:8}" "${value:8:4}" "${value:12:4}" "${value:16:4}" "${value:20:12}"
	else
		return 1
	fi
}

# Извлекает VLESS UUID из объекта клиента API/БД, игнорируя числовой row id.
client_vless_uuid() {
	local client=$1 candidate normalized
	for field in uuid id auth password; do
		candidate=$(jq -r --arg field "$field" '.[$field] // empty' <<<"$client")
		normalized=$(normalize_uuid "$candidate" 2>/dev/null || true)
		if [[ -n "$normalized" ]]; then
			printf '%s' "$normalized"
			return 0
		fi
	done
	return 1
}

client_vless_uuid_without_auth() {
	local client=$1 candidate normalized
	for field in uuid id; do
		candidate=$(jq -r --arg field "$field" '.[$field] // empty' <<<"$client")
		normalized=$(normalize_uuid "$candidate" 2>/dev/null || true)
		if [[ -n "$normalized" ]]; then
			printf '%s' "$normalized"
			return 0
		fi
	done
	return 1
}

# Восстанавливает UUID VLESS из inbound settings, если глобальная запись клиента
# уже была перезаписана несовместимым протоколом при прошлой синхронизации.
inbound_vless_client_uuid() {
	local inbound_id=$1 email=$2 inbound settings normalized candidate
	[[ -n "$inbound_id" && -n "$email" ]] || return 1
	inbound=$(inbound_by_id_json "$inbound_id")
	settings=$(json_field_object "$inbound" settings)
	for field in uuid id auth password; do
		candidate=$(jq -r --arg email "$email" --arg field "$field" '
          (.clients // [])[]? | select(.email == $email) | .[$field] // empty
        ' <<<"$settings" | head -n1)
		normalized=$(normalize_uuid "$candidate" 2>/dev/null || true)
		if [[ -n "$normalized" ]]; then
			printf '%s' "$normalized"
			return 0
		fi
	done
	return 1
}

sqlite_string() {
	local value=${1:-}
	printf "'%s'" "${value//\'/\'\'}"
}

repair_shared_client_db() {
	local email=$1 client_id=$2 sub_id=$3 flow=$4 password=$5 auth=$6 db=${XUI_DB_PATH:-/etc/x-ui/x-ui.db} sql i
	[[ "$MODE" == "apply" ]] || return 0
	[[ -s "$db" ]] || return 0
	command -v sqlite3 >/dev/null 2>&1 || return 0
	sql="pragma busy_timeout=5000; update clients set uuid=$(sqlite_string "$client_id"), password=$(sqlite_string "$password"), auth=$(sqlite_string "$auth"), flow=$(sqlite_string "$flow"), sub_id=$(sqlite_string "$sub_id") where email=$(sqlite_string "$email");"
	for i in 1 2 3 4 5; do
		if sqlite3 "$db" "$sql" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
	done
	log WARN "Managed client DB repair skipped email=$email; sqlite update failed."
}

# 3x-ui 3.5 rejects inbound updates when stored settings still have string tgId
# (even if the request payload already uses numeric tgId). Normalize in SQLite first.
repair_inbound_client_tg_ids_db() {
	local db=${XUI_DB_PATH:-/etc/x-ui/x-ui.db} changed
	[[ "$MODE" == "apply" ]] || return 0
	[[ -s "$db" ]] || return 0
	command -v python3 >/dev/null 2>&1 || {
		log WARN "Inbound tgId repair skipped: python3 is unavailable."
		return 0
	}
	changed=$(
		XUI_DB_PATH="$db" python3 - <<'PY'
import json
import os
import sqlite3

db = os.environ.get("XUI_DB_PATH", "/etc/x-ui/x-ui.db")
con = sqlite3.connect(db)
cur = con.cursor()
changed = 0
for inbound_id, settings in cur.execute("select id, settings from inbounds"):
    if not settings:
        continue
    try:
        obj = json.loads(settings)
    except Exception:
        continue
    dirty = False
    for client in obj.get("clients") or []:
        tg = client.get("tgId", 0)
        if isinstance(tg, str):
            text = tg.strip()
            client["tgId"] = int(text) if text.lstrip("-").isdigit() else 0
            dirty = True
        elif tg is None:
            client["tgId"] = 0
            dirty = True
    if dirty:
        cur.execute(
            "update inbounds set settings=? where id=?",
            (json.dumps(obj, separators=(",", ":")), inbound_id),
        )
        changed += 1
con.commit()
con.close()
print(changed)
PY
	) || {
		log WARN "Inbound tgId repair skipped: sqlite/python update failed."
		return 0
	}
	if [[ "${changed:-0}" != "0" ]]; then
		log INFO "Normalized string tgId values in $changed inbound settings row(s)."
	fi
}

jq_join_csv() {
	jq -r 'join(",")'
}

# Создает локальный self-signed сертификат для TLS backend inbound, если оператор
# не смонтировал свой cert/key в контейнер 3x-ui.
ensure_xray_tls_certificate() {
	local cert_file=$1 key_file=$2 dir
	[[ -n "$cert_file" && -n "$key_file" ]] || die "XRAY TLS certificate paths are empty."
	if [[ -s "$cert_file" && -s "$key_file" ]]; then
		return 0
	fi
	if [[ "$cert_file" == /etc/traefik/pem/* || "$key_file" == /etc/traefik/pem/* ]]; then
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: Traefik PEM certificate required for Xray TLS backend"
			return 0
		fi
		die "Traefik PEM certificate files are missing: cert=$cert_file key=$key_file"
	fi
	if [[ "$MODE" == "plan" ]]; then
		record_change "PLAN: Xray TLS certificate generated at configured paths"
		return 0
	fi
	command -v openssl >/dev/null 2>&1 || die "openssl is required to generate Xray TLS certificate."
	dir=$(dirname "$cert_file")
	mkdir -p "$dir" "$(dirname "$key_file")"
	record_change "APPLY: Xray TLS certificate generated at configured paths"
	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$key_file" \
		-out "$cert_file" \
		-days "${XRAY_TLS_SELF_SIGNED_DAYS:-3650}" \
		-subj "/CN=${WEBDOMAIN:-localhost}" >/dev/null 2>&1 ||
		die "Failed to generate Xray TLS certificate."
	chmod 600 "$key_file"
	chmod 644 "$cert_file"
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
		sanitize_vision_stream_json "$(json_field_object "$current" streamSettings)"
		return 0
	fi

	if [[ "$kind" == "vision" ]]; then
		get_x25519_keys || die "Failed to get X25519 keys for Vision inbound."
		build_vision_stream_json "${REALITY_TARGET_HOST:-telemt}:${REALITY_TARGET_PORT:-${PORT_LOCAL_TELEMT_PROXY:-9443}}" "$WEBDOMAIN" "$X25519_PRIVATE_KEY" "$X25519_PUBLIC_KEY" "$(generate_short_ids_json 8 8)" "$(build_sockopt_json false AsIs off)" "" "" "${REALITY_TARGET_XVER:-1}"
	elif [[ "$kind" == "xhttp" ]]; then
		if [[ -n "$current" && "$current" != "null" ]]; then
			sanitize_xhttp_stream_json "$(json_field_object "$current" streamSettings)" "$URI_VLESS_XHTTP" "$WEBDOMAIN"
			return 0
		fi
		build_xhttp_stream_json "$URI_VLESS_XHTTP" "$WEBDOMAIN"
	elif [[ "$kind" == "grpc" ]]; then
		if [[ -n "$current" && "$current" != "null" ]]; then
			sanitize_grpc_stream_json "$(json_field_object "$current" streamSettings)" "${URI_VLESS_GRPC:-/grpc}" "$WEBDOMAIN" "${XRAY_TLS_CERT_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-cert.pem}" "${XRAY_TLS_KEY_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-key.pem}"
			return 0
		fi
		build_grpc_stream_json "${URI_VLESS_GRPC:-/grpc}" "$WEBDOMAIN" "${XRAY_TLS_CERT_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-cert.pem}" "${XRAY_TLS_KEY_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-key.pem}"
	elif [[ "$kind" == "hysteria2" ]]; then
		build_hysteria2_stream_json "$WEBDOMAIN" "${XRAY_TLS_CERT_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-cert.pem}" "${XRAY_TLS_KEY_FILE:-/etc/traefik/pem/${WEBDOMAIN:-localhost}-key.pem}" "${HYSTERIA2_STREAM_AUTH:-}"
	else
		die "Unsupported inbound kind: $kind"
	fi
}

# Формирует settings для Hysteria2, сохраняя существующий auth клиента.
build_hysteria2_settings_json() {
	local current=${1:-} desired=$2 preferred_auth=${3:-} existing='{}' clients='[]' email sub_id auth legacy_email legacy_hysteria_email client
	if [[ -n "$current" && "$current" != "null" ]]; then
		existing=$(json_field_object "$current" settings)
		clients=$(jq -c '.clients // []' <<<"$existing")
	fi
	email=$(jq -r '.clients.shared.email' <<<"$desired")
	sub_id=$(jq -r '.clients.shared.subId' <<<"$desired")
	legacy_email=${CLIENT_EMAIL_LEGACY:-autogen}
	legacy_hysteria_email="${CLIENT_EMAIL_HYSTERIA2:-${legacy_email}-hysteria2}"
	auth=$(jq -r --arg email "$email" '.[] | select(.email == $email) | .auth // empty' <<<"$clients" | head -n1)
	[[ -n "$auth" ]] || auth=$preferred_auth
	[[ -n "$auth" ]] || auth=$(new_client_secret)
	client=$(jq -nc --arg auth "$auth" --arg email "$email" --arg sid "$sub_id" '{
      auth:$auth, email:$email, limitIp:0, totalGB:0, expiryTime:0,
      enable:true, tgId:0, subId:$sid, group:"", comment:"", reset:0
    }')
	jq -nc --argjson clients "$clients" --argjson client "$client" --arg legacyEmail "$legacy_email" --arg legacyHysteria "$legacy_hysteria_email" '{
      version:2,
      clients:(
        [
          $clients[]
          | select(.email != $client.email and .email != $legacyEmail and .email != $legacyHysteria)
          | .tgId = (
              if (.tgId|type) == "number" then .tgId
              elif ((.tgId|tostring)|length) == 0 then 0
              else ((.tgId|tonumber?) // 0)
              end
            )
        ] + [$client]
      )
    }'
}

# Собирает все компоненты нового inbound для передачи в API панели.
build_inbound_components_json() {
	local kind=$1 desired=$2 current=${3:-}
	local settings stream sniffing allocate port remark protocol
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	remark=$(jq -r ".inbounds.$kind.remark" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	if [[ "$kind" == "hysteria2" ]]; then
		settings=$(build_hysteria2_settings_json "$current" "$desired")
		HYSTERIA2_STREAM_AUTH=$(jq -r '.clients[0].auth // ""' <<<"$settings")
	else
		settings=$(build_vless_settings_json "$kind" "$current")
	fi
	stream=$(build_inbound_stream_json "$kind" "$current")
	if [[ "$kind" == "hysteria2" ]]; then
		HYSTERIA2_STREAM_AUTH=
	fi
	if [[ "$kind" == "hysteria2" ]]; then
		sniffing=$(jq -nc '{enabled:false,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false}')
	else
		sniffing=$(jq -nc '{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false}')
	fi
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

# Возвращает JSON inbound payload с nested settings/streamSettings для API 3.7.
inbound_components_json() {
	local components=$1
	printf '%s' "$components"
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
	local kind=$1 desired=$2 inbounds id port protocol inbound desired_components expected_remarks
	ENSURE_INBOUND_ID=
	inbounds=$(inbounds_json)
	port=$(jq -r ".inbounds.$kind.port" <<<"$desired")
	protocol=$(jq -r ".inbounds.$kind.protocol" <<<"$desired")
	expected_remarks=$(managed_inbound_remarks_json "$kind" "$desired")
	id=$(find_inbound_by_port "$inbounds" "$port" "$protocol")
	if [[ -z "$id" && "$kind" == "hysteria2" ]]; then
		id=$(find_inbound_by_port "$inbounds" "$port" "hysteria2")
	fi
	inbound=$(jq -c --arg id "$id" '.[] | select((.id|tostring)==$id)' <<<"$inbounds" | head -n1)
	managed_conflict_check "$inbound" "$expected_remarks" "$port"

	if [[ -n "$id" ]]; then
		log INFO "$kind inbound already exists id=$id port=$port; preserving existing configuration."
		ENSURE_INBOUND_ID=$id
	else
		desired_components=$(build_inbound_components_json "$kind" "$desired")
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: $kind inbound created port=$port"
			return 0
		fi
		record_change "APPLY: $kind inbound created port=$port"
		xui_add_inbound "$(inbound_components_json "$desired_components")" || die "Failed to add $kind inbound."
		http_success_json || die "$kind inbound add failed: $(http_body)"
		RESTART_XRAY_REQUIRED=1
		ENSURE_INBOUND_ID=$(jq -r '.obj.id // empty' "$HTTP_BODY_FILE")
	fi
}

# Читает полный inbound по ID.
inbound_by_id_json() {
	local id=$1
	xui_get_inbound "$id" || die "Failed to get inbound id=$id."
	http_success_json || die "Inbound get failed id=$id: $(http_body)"
	jq -c '.obj // {}' "$HTTP_BODY_FILE"
}

# Обновляет inbound nested JSON через API 3.7.
update_inbound_components() {
	local id=$1 components=$2
	xui_update_inbound "$id" "$(inbound_components_json "$components")" || die "Failed to update inbound id=$id."
	http_success_json || die "Inbound update failed id=$id: $(http_body)"
	RESTART_XRAY_REQUIRED=1
}

# Создает либо синхронизирует одного общего клиента для всех управляемых inbound.
ensure_shared_client() {
	local vision_id=$1 xhttp_id=$2 grpc_id=$3 hysteria2_id=$4 desired=$5
	local clients email sub_id flow vision_flow xhttp_flow current client_id client_password client_auth client target_ids missing_ids attach_payload changed=0 created=0
	ENSURE_SHARED_CLIENT_ID=
	ENSURE_SHARED_CLIENT_PASSWORD=
	ENSURE_SHARED_CLIENT_AUTH=
	email=$(jq -r '.clients.shared.email' <<<"$desired")
	sub_id=$(jq -r '.clients.shared.subId' <<<"$desired")
	flow=$(jq -r '.clients.shared.flow' <<<"$desired")
	vision_flow=$(jq -r '.clients.shared.visionFlow' <<<"$desired")
	xhttp_flow=$(jq -r '.clients.shared.xhttpFlow' <<<"$desired")
	target_ids=$(jq -nc --arg vision "$vision_id" --arg xhttp "$xhttp_id" --arg grpc "$grpc_id" --arg hysteria2 "$hysteria2_id" '
      [$vision, $xhttp, $grpc, $hysteria2] | map(select(length > 0) | tonumber)
    ')
	clients=$(clients_json)
	current=$(jq -c --arg email "$email" '.[]? | select(.email == $email)' <<<"$clients" | head -n1)

	if [[ -z "$current" ]]; then
		# Новый API создает клиента сразу с двумя привязками одной мутацией.
		client_id=$(new_uuid)
		client_password=$(new_client_secret)
		client_auth=$(new_client_secret)
		client=$(vless_client_api_json "$client_id" "$email" "$sub_id" "$flow" "$client_password" "$client_auth")
		# shellcheck disable=SC2034 # entrypoint reads the selected shared client id after this function returns
		ENSURE_SHARED_CLIENT_ID=$client_id
		ENSURE_SHARED_CLIENT_PASSWORD=$client_password
		ENSURE_SHARED_CLIENT_AUTH=$client_auth
		if [[ "$MODE" == "plan" ]]; then
			record_change "PLAN: shared client created email=$email inbounds=$(jq_join_csv <<<"$target_ids")"
			return 0
		fi
		record_change "APPLY: shared client created email=$email inbounds=$(jq_join_csv <<<"$target_ids")"
		xui_add_client "$(vless_client_create_payload_json "$target_ids" "$client")" || die "Failed to add shared client."
		http_success_json || die "shared client add failed: $(api_error_summary)"
		repair_shared_client_db "$email" "$client_id" "$sub_id" "$flow" "$client_password" "$client_auth"
		RESTART_XRAY_REQUIRED=1
		current=$(jq -nc \
			--arg email "$email" \
			--arg sid "$sub_id" \
			--arg uuid "$client_id" \
			--arg password "$client_password" \
			--arg auth "$client_auth" \
			--arg flow "$flow" \
			--argjson inboundIds "$target_ids" '{
              email:$email, subId:$sid, sub_id:$sid, uuid:$uuid, id:$uuid,
              password:$password, auth:$auth, flow:$flow, inboundIds:$inboundIds
            }')
		created=1
	fi

	if ((created == 0)); then
		client_id=$(client_vless_uuid_without_auth "$current" || true)
		if [[ -z "$client_id" ]]; then
			client_id=$(inbound_vless_client_uuid "$vision_id" "$email" || inbound_vless_client_uuid "$xhttp_id" "$email" || true)
		fi
		if [[ -z "$client_id" ]]; then
			client_id=$(client_vless_uuid "$current" || true)
		fi
		if [[ -z "$client_id" ]]; then
			client_id=$(new_uuid)
			log WARN "Existing shared client email=$email has no valid VLESS UUID; generating a replacement."
		fi
		client_password=$(jq -r '.password // empty' <<<"$current")
		client_auth=$(jq -r '.auth // empty' <<<"$current")
		[[ -n "$client_password" ]] || client_password=$(new_client_secret)
		[[ -n "$client_auth" ]] || client_auth=$(new_client_secret)
		# shellcheck disable=SC2034 # entrypoint reads the selected shared client id after this function returns
		ENSURE_SHARED_CLIENT_ID=$client_id
		ENSURE_SHARED_CLIENT_PASSWORD=$client_password
		ENSURE_SHARED_CLIENT_AUTH=$client_auth
		client=$(vless_client_api_json "$client_id" "$email" "$sub_id" "$flow" "$client_password" "$client_auth")
		if ! jq -e --arg sid "$sub_id" --arg flow "$flow" --arg password "$client_password" --arg auth "$client_auth" '
          (.subId // "") == $sid and (.flow // "") == $flow and (.password // "") == $password and (.auth // "") == $auth
        ' <<<"$current" >/dev/null; then
			if plan_or_apply "shared client updated email=$email"; then
				xui_update_client "$email" "$client" || die "Failed to update shared client."
				http_success_json || die "shared client update failed: $(api_error_summary)"
				repair_shared_client_db "$email" "$client_id" "$sub_id" "$flow" "$client_password" "$client_auth"
				RESTART_XRAY_REQUIRED=1
			fi
			changed=1
		fi
		repair_shared_client_db "$email" "$client_id" "$sub_id" "$flow" "$client_password" "$client_auth"
	fi

	missing_ids=$(jq -c --argjson target "$target_ids" '$target - (.inboundIds // [])' <<<"$current")
	if [[ "$(jq 'length' <<<"$missing_ids")" != "0" ]]; then
		# Уже существующему клиенту добавляются только еще отсутствующие inbound.
		attach_payload=$(jq -nc --argjson inboundIds "$missing_ids" '{inboundIds:$inboundIds}')
		if plan_or_apply "shared client attached email=$email inbounds=$(jq_join_csv <<<"$missing_ids")"; then
			xui_attach_client "$email" "$attach_payload" || die "Failed to attach shared client."
			http_success_json || die "shared client attach failed: $(api_error_summary)"
			# shellcheck disable=SC2034 # флаг рестарта читается Xray-модулем/entrypoint
			RESTART_XRAY_REQUIRED=1
		fi
		changed=1
	fi

	if ((changed == 0)); then
		log INFO "shared client already attached email=$email inbounds=$(jq_join_csv <<<"$target_ids")."
	fi

	ensure_vless_inbound_client "$vision_id" "$client_id" "$desired" "$vision_flow" "Vision"
	ensure_vless_inbound_client "$xhttp_id" "$client_id" "$desired" "$xhttp_flow" "XHTTP"
	ensure_vless_stream "$vision_id" vision "Vision"
	ensure_vless_stream "$xhttp_id" xhttp "XHTTP"
}

repair_shared_client_after_inbound_sync() {
	local desired=$1 email sub_id flow
	[[ -n "${ENSURE_SHARED_CLIENT_ID:-}" ]] || return 0
	email=$(jq -r '.clients.shared.email' <<<"$desired")
	sub_id=$(jq -r '.clients.shared.subId' <<<"$desired")
	flow=$(jq -r '.clients.shared.flow' <<<"$desired")
	repair_shared_client_db "$email" "$ENSURE_SHARED_CLIENT_ID" "$sub_id" "$flow" "$ENSURE_SHARED_CLIENT_PASSWORD" "$ENSURE_SHARED_CLIENT_AUTH"
}

# Синхронизирует VLESS client object внутри конкретного inbound settings.
ensure_vless_inbound_client() {
	local inbound_id=$1 client_id=$2 desired=$3 flow=$4 label=$5 inbound current_settings desired_client desired_settings components email legacy_email legacy_hysteria_email
	[[ -n "$inbound_id" ]] || return 0
	[[ -n "$client_id" ]] || {
		log WARN "Skipping $label VLESS client sync because shared client id is unknown."
		return 0
	}
	inbound=$(inbound_by_id_json "$inbound_id")
	current_settings=$(json_field_object "$inbound" settings)
	email=$(jq -r '.clients.shared.email' <<<"$desired")
	legacy_email=${CLIENT_EMAIL_LEGACY:-autogen}
	legacy_hysteria_email=${CLIENT_EMAIL_HYSTERIA2:-${legacy_email}-hysteria2}
	desired_client=$(vless_client_api_json "$client_id" "$email" "$(jq -r '.clients.shared.subId' <<<"$desired")" "" "$ENSURE_SHARED_CLIENT_PASSWORD" "$ENSURE_SHARED_CLIENT_AUTH")
	desired_client=$(jq -c --arg flow "$flow" '.flow = $flow' <<<"$desired_client")
	desired_settings=$(jq -nc --argjson current "$current_settings" --argjson client "$desired_client" --arg legacy "$legacy_email" --arg legacyHysteria "$legacy_hysteria_email" '
      $current
      | .decryption = "none"
      | .encryption = "none"
      | .clients = (
          ((.clients // [])
            | map(select(.email != $client.email and .email != $legacy and .email != $legacyHysteria))
            | map(.tgId = (
                if (.tgId|type) == "number" then .tgId
                elif ((.tgId|tostring)|length) == 0 then 0
                else ((.tgId|tonumber?) // 0)
                end
              ))
          ) + [$client]
        )
    ')
	if jq -e --argjson desired "$desired_settings" '. == $desired' <<<"$current_settings" >/dev/null; then
		log INFO "$label VLESS inbound client already matches desired state."
		return 0
	fi
	components=$(current_inbound_components_json "$inbound" | jq -c --argjson settings "$desired_settings" '.settings = $settings')
	if plan_or_apply "$label VLESS inbound client synchronized"; then
		update_inbound_components "$inbound_id" "$components"
	fi
}

# Синхронизирует inbound-level VLESS клиента gRPC с пустым flow.
ensure_vless_stream() {
	local inbound_id=$1 kind=$2 label=$3 inbound desired_stream current_components desired_components
	[[ -n "$inbound_id" ]] || return 0
	inbound=$(inbound_by_id_json "$inbound_id")
	desired_stream=$(build_inbound_stream_json "$kind" "$inbound")
	current_components=$(current_inbound_components_json "$inbound")
	desired_components=$(jq -c --argjson stream "$desired_stream" '.streamSettings = $stream' <<<"$current_components")
	if jq -e --argjson desired "$desired_components" '. == $desired' <<<"$current_components" >/dev/null; then
		log INFO "$label stream already matches desired state."
		return 0
	fi
	if plan_or_apply "$label stream synchronized"; then
		update_inbound_components "$inbound_id" "$desired_components"
	fi
}

# Синхронизирует inbound-level VLESS клиента gRPC с пустым flow.
ensure_grpc_client() {
	local grpc_id=$1 client_id=$2 desired=$3 inbound desired_stream current_components desired_components
	ensure_vless_inbound_client "$grpc_id" "$client_id" "$desired" "" "gRPC"
	[[ -n "$grpc_id" ]] || return 0
	inbound=$(inbound_by_id_json "$grpc_id")
	desired_stream=$(build_inbound_stream_json grpc "$inbound")
	current_components=$(current_inbound_components_json "$inbound")
	desired_components=$(jq -c --argjson stream "$desired_stream" '.streamSettings = $stream' <<<"$current_components")
	if jq -e --argjson desired "$desired_components" '. == $desired' <<<"$current_components" >/dev/null; then
		log INFO "gRPC stream already matches desired state."
		return 0
	fi
	if plan_or_apply "gRPC stream synchronized"; then
		update_inbound_components "$grpc_id" "$desired_components"
	fi
}

# Синхронизирует Hysteria2 client auth внутри inbound settings.
ensure_hysteria2_client() {
	local hysteria2_id=$1 desired=$2 inbound desired_settings current_settings desired_stream current_components desired_components
	[[ -n "$hysteria2_id" ]] || return 0
	inbound=$(inbound_by_id_json "$hysteria2_id")
	current_settings=$(json_field_object "$inbound" settings)
	desired_settings=$(build_hysteria2_settings_json "$inbound" "$desired" "$ENSURE_SHARED_CLIENT_AUTH")
	HYSTERIA2_STREAM_AUTH=$(jq -r '.clients[0].auth // ""' <<<"$desired_settings")
	desired_stream=$(build_inbound_stream_json hysteria2 "$inbound")
	HYSTERIA2_STREAM_AUTH=
	current_components=$(current_inbound_components_json "$inbound")
	desired_components=$(jq -c \
		--arg protocol "$(jq -r '.inbounds.hysteria2.protocol' <<<"$desired")" \
		--argjson settings "$desired_settings" \
		--argjson stream "$desired_stream" '
        .protocol = $protocol | .settings = $settings | .streamSettings = $stream
      ' <<<"$current_components")
	if jq -e --argjson desired "$desired_components" '. == $desired' <<<"$current_components" >/dev/null; then
		log INFO "Hysteria2 inbound client already matches desired state."
		return 0
	fi
	if plan_or_apply "Hysteria2 inbound client synchronized"; then
		update_inbound_components "$hysteria2_id" "$desired_components"
	fi
}
