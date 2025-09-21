ensure_socks_outbound() {
    local host="$1"
    local port="$2"
    local tag="${3:-}"

    if [ -z "$host" ] || [ -z "$port" ]; then
        log ERROR "ensure_socks_outbound: требуется host и port"
        return 1
    fi

    local log_tag
    if [ -n "$tag" ]; then
        log_tag="Outbound '$tag'"
    else
        log_tag="Outbound socks://${host}:${port}"
    fi

    if ! nc -z -w2 "$host" "$port" 2>/dev/null; then
        log WARN "Адрес ${host}:${port} недоступен — ${log_tag} не добавляем."
        return 0
    fi

    local exists
    exists=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "${tag:-}" --arg host "$host" --argjson port "$port" '
        [.xraySetting.outbounds[]?
         | select(.protocol=="socks"
                  and any(.settings.servers[]?; .address==$host and ((.port|tonumber)==$port))
                  and (($tag == "") or (.tag? == $tag))
         )
        ] | length')

    if [ "${exists:-0}" -gt 0 ]; then
        log INFO "${log_tag} уже существует."
        return 0
    fi

    local new_outbound
    new_outbound=$(jq -nc --arg host "$host" --argjson port "$port" --arg tag "${tag:-}" '
        (if $tag != "" then {tag:$tag} else {} end) + {
            protocol:"socks",
            settings:{ servers:[{ address:$host, port:$port }] }
        }')

    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson ob "$new_outbound" '
        .xraySetting.outbounds = (.xraySetting.outbounds // []) |
        .xraySetting.outbounds += [$ob]')

    log INFO "${log_tag} -> ${host}:${port} добавлен."
}
update_xray_routing_warp() {
    # Объединённый функционал: регистрация WARP (при необходимости),
    # добавление outbounds (warp, warp-docker), добавление balancer и rule.

    TAG_WARP="warp"
    TAG_SOCKS="warp-docker"
    TAG_SOCKS_V5="warp_socks_v5"
    WARP="warp"
    WARP_PORT=1080
    WARP_V5="warp_socks_v5"
    WARP_PORT_V5=9091

    # 1) Убедимся, что outbound wireguard:warp существует. Если нет — регистрируем WARP и создаём outbound.
    exists_warp=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_WARP" '
        [.xraySetting.outbounds[]? | select(.tag==$tag and .protocol=="wireguard")] | length')

    if [ "${exists_warp:-0}" -eq 0 ]; then
        log INFO "Outbound '$TAG_WARP' отсутствует — запускаем регистрацию WARP и создаём wireguard outbound."

        # Регистрация WARP (получение WG_PRIVATE_KEY и WARP_CONFIG_JSON)
        ensure_warp_registered || {
            log ERROR "Регистрация WARP не удалась."
            return 1
        }

        # Построим outbound JSON на основе ответа регистрации
        v4=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.interface.addresses.v4 // .config.interface.addresses.v4 // empty')
        v6=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.interface.addresses.v6 // .config.interface.addresses.v6 // empty')
        peer_pub=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.peers[0].public_key // .config.peers[0].public_key // empty')
        if [ -z "$peer_pub" ]; then
            log ERROR "Не удалось получить public_key из регистрационного конфига WARP."
            return 1
        fi
        # Предпочитаем явный IPv4-эндпоинт, чтобы исключить проблемы с отсутствующим IPv6 в хосте
        ep_v4=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '(.peers[0].endpoint.v4 // .config.peers[0].endpoint.v4 // empty)')
        if [ -n "$ep_v4" ]; then
            endpoint="${ep_v4%:*}:2408"
        else
            endpoint=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '(.peers[0].endpoint.host // .config.peers[0].endpoint.host // empty)')
        fi
        [ -z "$endpoint" ] && endpoint="engage.cloudflareclient.com:2408"

        new_warp_ob=$(jq -nc \
          --arg sk "$WG_PRIVATE_KEY" \
          --arg v4 "$v4" \
          --arg v6 "$v6" \
          --arg pub "$peer_pub" \
          --arg ep "$endpoint" \
          --argjson reserved "${WG_RESERVED_JSON:-[10,14,188]}" '
          {
            tag: "warp",
            protocol: "wireguard",
            settings: {
              mtu: 1420,
              secretKey: $sk,
              address: ([ $v4, $v6 ]
                        | map(select(.!=null and .!=""))
                        | map(if (contains(":")) then (.+"/128") else (.+"/32") end)),
              numWorkers: 2,
              workers: 2,
              domainStrategy: "ForceIP",
              reserved: $reserved,
              peers: [
                {
                  publicKey: $pub,
                  public_key: $pub,
                  allowedIPs: ["0.0.0.0/0", "::/0"],
                  allowedIps: ["0.0.0.0/0", "::/0"],
                  endpoint: $ep,
                  keepAlive: 0
                }
              ],
              isClient: true,
              noKernelTun: false
            }
          }')

        XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson ob "$new_warp_ob" '
            .xraySetting.outbounds = (.xraySetting.outbounds // []) |
            .xraySetting.outbounds += [$ob]')
        log INFO "Outbound '$TAG_WARP' (wireguard) добавлен."
    else
        log INFO "Outbound '$TAG_WARP' уже существует."
    fi

    # 2) Проверяем socks-концы и добавляем outbounds
    ensure_socks_outbound "$WARP" "$WARP_PORT" "$TAG_SOCKS"
    ensure_socks_outbound "$WARP_V5" "$WARP_PORT_V5" "$TAG_SOCKS_V5"
    # 3) Добавляем routing.rule с balancerTag и 4) раздел балансировщика + 5) observatory
    desired_domains=$(
        jq -nc --arg webdomain "$WEBDOMAIN" '
            [
                "ext:geosite_RU.dat:category-gov-ru",
                "ext:geosite_RU.dat:yandex",
                "ext:geosite_RU.dat:steam",
                "ext:geosite_RU.dat:vk",
                "regexp:\\.ru",
                "regexp:\\.org",
                "regexp:\\.su",
                "regexp:\\.xn--d1acj3b$",
                "regexp:\\.xn--80adxhks$",
                "regexp:\\.xn--80asehdb$",
                "regexp:\\.xn--c1avg$",
                "regexp:\\.xn--80aswg$",
                "regexp:\\.p1ai$",
                "regexp:\\.xn--j1amh$",
                "regexp:\\.xn--90ae$",
                "regexp:\\.xn--90a3ac$",
                "regexp:\\.xn--l1acc$",
                "regexp:\\.xn--d1alf$",
                "regexp:\\.xn--90ais$"
            ]
            + (if ($webdomain // "") != "" then ["domain:" + $webdomain] else [] end)
        '
    )

    # Гарантируем наличие routing.rules
    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq '
        .xraySetting.routing = (.xraySetting.routing // {}) |
        .xraySetting.routing.rules = (.xraySetting.routing.rules // [])')

    # Добавим/обновим правило с balancerTag="warp-balancer"
    has_bal_rule=$(echo "$XRAY_SETTINGS_JSON" | jq 'any(.xraySetting.routing.rules[]?; .type=="field" and .balancerTag=="warp-balancer")')
    if [ "$has_bal_rule" = "true" ]; then
        XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson dom "$desired_domains" '
            .xraySetting.routing.rules |= map(
              if .type=="field" and .balancerTag=="warp-balancer" then
                .domain = (((.domain // []) + $dom) | unique)
              else . end)')
        log INFO "Routing-правило для balancerTag=warp-balancer обновлено."
    else
        new_rule=$(jq -nc --arg tag "warp-balancer" --argjson dom "$desired_domains" '{ type:"field", balancerTag:$tag, domain:$dom }')
        XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson rule "$new_rule" '.xraySetting.routing.rules += [$rule]')
        log INFO "Добавлено routing-правило с balancerTag=warp-balancer."
    fi

    # Добавим/обновим routing.balancers и observatory
    balancer_json=$(jq -nc '{ tag:"warp-balancer", selector:["warp-docker","warp_socks_v5"], fallbackTag:"warp", strategy:{type:"leastPing"} }')
    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson bal "$balancer_json" '
        .xraySetting.routing.balancers = (
          (.xraySetting.routing.balancers // [])
          | if any(.[]?; .tag=="warp-balancer") then
              map(if .tag=="warp-balancer" then $bal else . end)
            else . + [$bal] end
        )')

    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq '
        .xraySetting.observatory = (
          .xraySetting.observatory // {
            subjectSelector:["warp","warp-docker","warp_socks_v5"],
            probeURL:"http://www.google.com/gen_204",
            probeInterval:"10m",
            enableConcurrency:true
          }
        )')

    export XRAY_SETTINGS_JSON
}


# Гарантирует, что есть действующий WARP-конфиг и приватный ключ WG (через /panel/xray/warp/reg)
ensure_warp_registered() {
    if [ -n "$WG_PRIVATE_KEY" ] && [ -n "$WARP_CONFIG_JSON" ]; then
        return 0
    fi

    if [ -z "$URL_BASE_RESOLVED" ]; then
        log ERROR "URL_BASE_RESOLVED пуст. Требуется авторизация (resolve_and_login)."
        return 1
    fi

    # Генерация пары ключей через xray wg
    log INFO "Подготовка ключей WireGuard (xray wg) для WARP."
    arch=$(uname -m)
    case "$arch" in
        x86_64)  FNAME="amd64" ;;
        aarch64) FNAME="arm64" ;;
        armv7l)  FNAME="arm"   ;;
        *)       FNAME="amd64" ;;
    esac
    xray_dir="${XUI_BIN_FOLDER:-/app/bin}"
    xray_file="${xray_dir}/xray-linux-${FNAME}"
    if [ ! -x "$xray_file" ]; then
        if command -v xray >/dev/null 2>&1; then xray_file=$(command -v xray)
        elif [ -x "${xray_dir}/xray" ]; then xray_file="${xray_dir}/xray"
        else log ERROR "Не найден бинарник xray"; return 1; fi
    fi
    if ! output="$($xray_file wg 2>/dev/null)" || [ -z "$output" ]; then
        log ERROR "Не удалось выполнить '$xray_file wg' для генерации ключей."
        return 1
    fi
    WG_PRIVATE_KEY=$(echo "$output" | awk -F': ' '/PrivateKey/ {print $2}' | head -n1)
    WG_PUBLIC_KEY=$(echo  "$output" | awk -F': ' '/PublicKey/  {print $2}' | head -n1)
    WG_PASSWORD=$(echo     "$output" | awk -F': ' '/Password/   {print $2}' | head -n1)
    WG_HASH32=$(echo       "$output" | awk -F': ' '/Hash32/     {print $2}' | head -n1)
    [ -z "$WG_PUBLIC_KEY" ] && [ -n "$WG_PASSWORD" ] && WG_PUBLIC_KEY="$WG_PASSWORD"
    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WG_PUBLIC_KEY" ]; then
        log ERROR "Ключи WireGuard не получены: PrivateKey='${WG_PRIVATE_KEY:-}' PublicKey='${WG_PUBLIC_KEY:-}'"
        return 1
    fi
    # Вычислим reserved из первых 3 байт Hash32 (если доступно)
    WG_RESERVED_JSON=""
    if [ -n "$WG_HASH32" ]; then
        # Пытаемся декодировать base64: сначала через base64 -d, затем через openssl
        if decoded=$(printf '%s' "$WG_HASH32" | base64 -d 2>/dev/null | head -c 3); then
            :
        else
            decoded=$(printf '%s' "$WG_HASH32" | openssl base64 -d -A 2>/dev/null | head -c 3 || true)
        fi
        if [ -n "$decoded" ]; then
            # Преобразуем в десятичные байты
            read -r b1 b2 b3 <<EOF
$(printf '%s' "$decoded" | od -An -tu1 | tr -s ' ' | sed 's/^ //')
EOF
            if [ -n "$b1" ] && [ -n "$b2" ] && [ -n "$b3" ]; then
                WG_RESERVED_JSON="[$b1,$b2,$b3]"
            fi
        fi
    fi
    [ -z "$WG_RESERVED_JSON" ] && WG_RESERVED_JSON='[10,14,188]'

    export WG_PRIVATE_KEY WG_PUBLIC_KEY WG_HASH32 WG_RESERVED_JSON
    log INFO "Ключи WireGuard сгенерированы (public/private)."

    # Запрос регистрации
    url="${URL_BASE_RESOLVED}/panel/xray/warp/reg"
    http_request POST "$url" \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: https://$WEBDOMAIN" \
        -H "Referer: https://$URL_BASE_RESOLVED/panel/xray" \
        --data-urlencode "publicKey=$WG_PUBLIC_KEY" \
        --data-urlencode "privateKey=$WG_PRIVATE_KEY"

    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при регистрации WARP: $HTTP_BODY"
        return 1
    fi
    if ! printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        log ERROR "WARP регистрация вернула неуспех: $HTTP_BODY"
        return 1
    fi

    # Извлечём конфиг (вложенный JSON-строкой)
    WARP_OBJ=$(printf '%s' "$HTTP_BODY" | jq -r '.obj | fromjson? // empty' 2>/dev/null)
    [ -z "$WARP_OBJ" ] && { log ERROR "Ответ без корректного obj JSON"; return 1; }
    WARP_CONFIG_JSON=$(printf '%s' "$WARP_OBJ" | jq -c '.config // {}')
    export WARP_CONFIG_JSON
    log INFO "WARP зарегистрирован: device_id=$(printf '%s' "$WARP_OBJ" | jq -r '.id // .data.device_id // "?"')"
}


# Register WARP inbound via panel API using keys from `xray wg`
register_warp_inbound() {
    # Ensure we have session and base url
    if [ -z "$URL_BASE_RESOLVED" ]; then
        log ERROR "URL_BASE_RESOLVED пуст. Необходима предварительная авторизация (resolve_and_login)."
        return 1
    fi

    # Check current state BEFORE creating anything
    warp_config_status "before"

    cfg_success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false' 2>/dev/null)
    cfg_obj_parsed=$(printf '%s' "$HTTP_BODY" | jq -r 'try (.obj | fromjson) catch empty' 2>/dev/null)
    if [ "$cfg_success" = "true" ] && [ -n "$cfg_obj_parsed" ]; then
        WARP_OBJ="$cfg_obj_parsed"
        WARP_DEVICE_ID=$(printf '%s' "$WARP_OBJ" | jq -r '.id // empty' 2>/dev/null)
        export WARP_OBJ WARP_DEVICE_ID
        log INFO "WARP уже существует: device_id=${WARP_DEVICE_ID:-?}. Регистрация пропущена."
        return 0
    fi

    log INFO "Подготовка ключей WireGuard (xray wg) для WARP."

    # Detect arch and select xray binary filename
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            ARCH="64"
            FNAME="amd64"
            ;;
        aarch64)
            ARCH="arm64-v8a"
            FNAME="arm64"
            ;;
        armv7l)
            ARCH="arm32-v7a"
            FNAME="arm"
            ;;
        *)
            log INFO "Неизвестная архитектура: $arch"
            return 0
            ;;
    esac

    xray_dir="${XUI_BIN_FOLDER:-/app/bin}"
    xray_file="${xray_dir}/xray-linux-${FNAME}"

    if [ ! -x "$xray_file" ]; then
        if command -v xray >/dev/null 2>&1; then
            xray_file=$(command -v xray)
        elif [ -x "${xray_dir}/xray" ]; then
            xray_file="${xray_dir}/xray"
        else
            log ERROR "Не найден бинарник xray: ожидался ${xray_dir}/xray-linux-${FNAME}"
            return 1
        fi
    fi

    # Generate keys
    if ! output="$($xray_file wg 2>/dev/null)" || [ -z "$output" ]; then
        log ERROR "Не удалось выполнить '$xray_file wg' для генерации ключей."
        return 1
    fi

    WG_PRIVATE_KEY=$(echo "$output" | awk -F': ' '/PrivateKey/ {print $2}' | head -n1)
    WG_PUBLIC_KEY=$(echo  "$output" | awk -F': ' '/PublicKey/  {print $2}' | head -n1)
    WG_PASSWORD=$(echo     "$output" | awk -F': ' '/Password/   {print $2}' | head -n1)
    WG_HASH32=$(echo       "$output" | awk -F': ' '/Hash32/     {print $2}' | head -n1)

    # В Xray wg поле "Password" фактически содержит публичный ключ (PublicKey)
    if [ -z "$WG_PUBLIC_KEY" ] && [ -n "$WG_PASSWORD" ]; then
        WG_PUBLIC_KEY="$WG_PASSWORD"
    fi

    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WG_PUBLIC_KEY" ]; then
        log ERROR "Ключи WireGuard не получены: PrivateKey='${WG_PRIVATE_KEY:-}' PublicKey='${WG_PUBLIC_KEY:-}'"
        log DEBUG "xray wg output:\n$output"
        return 1
    fi

    export WG_PRIVATE_KEY WG_PUBLIC_KEY WG_PASSWORD WG_HASH32
    log INFO "Ключи WireGuard сгенерированы (public/private)."

    # Perform registration request
    url="${URL_BASE_RESOLVED}/panel/xray/warp/reg"
    log INFO "Отправка запроса регистрации WARP на $url"

    http_request POST "$url" \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: https://$WEBDOMAIN" \
        -H "Referer: https://$URL_BASE_RESOLVED/panel/xray" \
        --data-urlencode "publicKey=$WG_PUBLIC_KEY" \
        --data-urlencode "privateKey=$WG_PRIVATE_KEY"

    if printf '%s' "$HTTP_BODY" | jq -e . >/dev/null 2>&1; then
        local reg_obj_parsed reg_obj_raw
        reg_obj_parsed=$(printf '%s' "$HTTP_BODY" | jq -r 'try (.obj | fromjson) catch empty' 2>/dev/null)
        if [ -n "$reg_obj_parsed" ]; then
            log DEBUG "warp/reg.obj (parsed): $(printf '%s' "$reg_obj_parsed" | jq .)"
        else
            reg_obj_raw=$(printf '%s' "$HTTP_BODY" | jq -r '.obj // empty' 2>/dev/null)
            [ -n "$reg_obj_raw" ] && log DEBUG "warp/reg.obj (raw string): $reg_obj_raw"
        fi
    fi

    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при регистрации WARP: $HTTP_BODY"
        return 1
    fi

    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false' 2>/dev/null)
    if [ "$success" != "true" ]; then
        log ERROR "WARP регистрация вернула success=false: $HTTP_BODY"
        return 1
    fi

    # Parse 'obj' which is JSON string; convert to object
    WARP_OBJ=$(printf '%s' "$HTTP_BODY" | jq -r '.obj | fromjson? // empty' 2>/dev/null)
    if [ -z "$WARP_OBJ" ]; then
        log WARN "Ответ не содержит корректного obj JSON."
        return 0
    fi

    # Extract useful fields and export
    WARP_ACCESS_TOKEN=$(printf '%s' "$WARP_OBJ" | jq -r '.data.access_token // empty' 2>/dev/null)
    WARP_DEVICE_ID=$(printf    '%s' "$WARP_OBJ" | jq -r '.data.device_id    // empty' 2>/dev/null)
    WARP_LICENSE_KEY=$(printf  '%s' "$WARP_OBJ" | jq -r '.data.license_key  // empty' 2>/dev/null)
    WARP_CONFIG_JSON=$(printf  '%s' "$WARP_OBJ" | jq -c '(.config.config // .config // {})'    2>/dev/null)

    export WARP_ACCESS_TOKEN WARP_DEVICE_ID WARP_LICENSE_KEY WARP_CONFIG_JSON

    log INFO "WARP зарегистрирован: device_id=${WARP_DEVICE_ID:-?}, token=${WARP_ACCESS_TOKEN:-?}"

    # Запрос состояния ПОСЛЕ регистрации
    warp_config_status "after"

    # Обновим XRAY-конфиг: добавим inbound wireguard (tag=warp)
    ensure_warp_inbound_in_settings || return 1
    # Применим настройки XRAY сразу
    apply_xray_settings || true
}


# Query and log WARP config state (raw and parsed)
warp_config_status() {
    local stage="${1:-}"
    if [ -n "$stage" ]; then
        log DEBUG "Запрос состояния WARP (${stage})."
    else
        log DEBUG "Запрос состояния WARP."
    fi

    if [ -z "$URL_BASE_RESOLVED" ]; then
        log ERROR "URL_BASE_RESOLVED пуст. Невозможно запросить состояние WARP."
        return 1
    fi

    local url="${URL_BASE_RESOLVED}/panel/xray/warp/config"
    http_request POST "$url" \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: https://$WEBDOMAIN" \
        -H "Referer: https://$URL_BASE_RESOLVED/panel/xray"

    # Only keep parsed pretty of obj when available
    local obj_parsed
    obj_parsed=$(printf '%s' "$HTTP_BODY" | jq -r 'try (.obj | fromjson) catch empty' 2>/dev/null)
    if [ -n "$obj_parsed" ]; then
        log INFO "WARP config.obj (parsed pretty):\n$(printf '%s' "$obj_parsed" | jq .)"
    fi
}


# Ensure WireGuard inbound (tag: warp) exists in XRAY_SETTINGS_JSON using WARP_CONFIG_JSON and WG_PRIVATE_KEY
ensure_warp_inbound_in_settings() {
    # Требуются ключ и конфиг, полученные при регистрации WARP
    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WARP_CONFIG_JSON" ]; then
        log ERROR "ensure_warp_inbound_in_settings: отсутствуют WG_PRIVATE_KEY или WARP_CONFIG_JSON"
        return 1
    fi

    # Загрузим актуальные XRAY-настройки, если не загружены
    if [ -z "$XRAY_SETTINGS_JSON" ]; then
        update_xray_settings || return 1
    fi

    # Проверим, есть ли уже inbound wireguard с tag=warp
    exists_in=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "warp" '
        [.xraySetting.inbounds[]? | select(.tag == $tag and .protocol == "wireguard")] | length')
    if [ "${exists_in:-0}" -gt 0 ]; then
        log INFO "Inbound wireguard 'warp' уже существует — пропускаем добавление."
        return 0
    fi

    # Достаём параметры из ответа регистрации (поддержка обеих форм: config.config и config)
    v4=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.interface.addresses.v4 // .config.interface.addresses.v4 // empty')
    v6=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.interface.addresses.v6 // .config.interface.addresses.v6 // empty')
    peer_pub=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '.peers[0].public_key // .config.peers[0].public_key // empty')
    # endpoint=$(printf '%s' "$WARP_CONFIG_JSON" | jq -r '(.peers[0].endpoint.host // .config.peers[0].endpoint.host // empty)')
    [ -z "$endpoint" ] && endpoint="engage.cloudflareclient.com:2408"

    # Сформируем inbound JSON
    inbound_json=$(jq -nc \
        --arg sk "$WG_PRIVATE_KEY" \
        --arg v4 "$v4" \
        --arg v6 "$v6" \
        --arg pub "$peer_pub" \
        --arg ep "$endpoint" \
        --argjson reserved "${WG_RESERVED_JSON:-[10,14,188]}" '
      {
        tag: "warp",
        protocol: "wireguard",
        settings: {
          mtu: 1420,
          secretKey: $sk,
          address: ([ $v4, $v6 ]
                    | map(select(.!=null and .!=""))
                    | map(if (contains(":")) then (.+"/128") else (.+"/32") end)),
          workers: 2,
          domainStrategy: "ForceIP",
          reserved: $reserved,
          peers: [
            {
              publicKey: $pub,
              allowedIPs: ["0.0.0.0/0", "::/0"],
              endpoint: $ep,
              keepAlive: 0
            }
          ],
          noKernelTun: false
        }
      }')

    # Вставим inbound в XRAY_SETTINGS_JSON
    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson ib "$inbound_json" '
        .xraySetting.inbounds = (.xraySetting.inbounds // []) |
        .xraySetting.inbounds += [$ib]')

    log INFO "Добавлен inbound wireguard с tag=warp."
    export XRAY_SETTINGS_JSON
}
