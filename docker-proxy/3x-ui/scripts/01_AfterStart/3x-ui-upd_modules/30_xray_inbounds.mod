#!/bin/bash
# -----------------------------
# API endpoints (resolved base)
# -----------------------------
# Базовый URL панели берётся из переменной окружения `URL_BASE_RESOLVED`.
# Ниже перечислены все используемые точки входа API панели 3x-ui.

# Получить пары шифрования VLESS (в т.ч. Post‑Quantum ML‑KEM‑768)
API_URL_GET_VLESS_ENC="${URL_BASE_RESOLVED}/panel/api/server/getNewVlessEnc"
# Получить новую пару ключей X25519 (Reality)
API_URL_GET_X25519="${URL_BASE_RESOLVED}/panel/api/server/getNewX25519Cert"
# Получить seed/verify для mldsa65 (Reality + PQ)
API_URL_GET_MLDSA65="${URL_BASE_RESOLVED}/panel/api/server/getNewmldsa65"

# Создать inbound (VLESS/XHTTP)
API_URL_INBOUND_ADD="${URL_BASE_RESOLVED}/panel/api/inbounds/add"
# Список inbound-ов
API_URL_INBOUND_LIST="${URL_BASE_RESOLVED}/panel/api/inbounds/list"
# Добавить клиента в inbound
API_URL_ADD_CLIENT="${URL_BASE_RESOLVED}/panel/api/inbounds/addClient"

panel_api_request() {
    # panel_api_request <METHOD> <URL> [curl args...]
    if [ "$#" -lt 2 ]; then
        if command -v log >/dev/null 2>&1; then
            log ERROR "panel_api_request: need METHOD and URL, got $#"
        else
            printf '%s\n' "panel_api_request: missing METHOD/URL (got $#)" >&2
        fi
        return 2
    fi
    method=$1; url=$2; shift 2
    http_request "$method" "$url" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        "$@"
}

refresh_api_urls() {
    # Recompute API URLs after resolve_and_login updates URL_BASE_RESOLVED
    [ -n "${URL_BASE_RESOLVED:-}" ] || return 0
    # Получить пары шифрования VLESS (в т.ч. Post‑Quantum ML‑KEM‑768)
    API_URL_GET_VLESS_ENC="${URL_BASE_RESOLVED}/panel/api/server/getNewVlessEnc"
    # Получить новую пару ключей X25519 (Reality)
    API_URL_GET_X25519="${URL_BASE_RESOLVED}/panel/api/server/getNewX25519Cert"
    # Получить seed/verify для mldsa65 (Reality + PQ)
    API_URL_GET_MLDSA65="${URL_BASE_RESOLVED}/panel/api/server/getNewmldsa65"

    # Создать inbound (VLESS/XHTTP)
    API_URL_INBOUND_ADD="${URL_BASE_RESOLVED}/panel/api/inbounds/add"
    # Список inbound-ов
    API_URL_INBOUND_LIST="${URL_BASE_RESOLVED}/panel/api/inbounds/list"
    # Добавить клиента в inbound
    API_URL_ADD_CLIENT="${URL_BASE_RESOLVED}/panel/api/inbounds/addClient"
}

create_inbound_tcp_reality() {
    refresh_api_urls
    use_pq=${USE_VLESS_PQ:-true}
    # Получаем X25519 ключи
    if [ "$use_pq" = "true" ]; then
        get_new_vless_enc || return 1
    else
        VLESS_DEC="none"
        VLESS_ENC="none"
        VLESS_LABEL=""
        log INFO "VLESS PQ disabled (USE_VLESS_PQ=$use_pq); decryption/encryption set to none."
    fi
    get_new_x25519_cert || return 1
    use_mldsa=${USE_MLDSA65:-false}
    if [ "$use_mldsa" = "true" ]; then
        get_new_mldsa65 || return 1
    else
        MLD_SA_SEED=""
        MLD_SA_VERIFY=""
        log INFO "mldsa65 disabled for Reality (USE_MLDSA65=$use_mldsa)"
    fi

    # fallbacks_json=$(
    #   jq -nc \
    #     --arg port_xhttp "$PORT_LOCAL_XHTTP" \
    #     --arg port_traefik "$PORT_LOCAL_TRAEFIK" '
    #     []
    #     '
    # )

    fallbacks_json=$(
      jq -nc \
        --arg port_traefik "$PORT_LOCAL_TRAEFIK" '
        [
          { alpn: "h1 h2 h3", path: "", dest: ("traefik:" + $port_traefik), xver: 2 }
        ]
        '
    )
    log DEBUG "Fallbacks JSON: $fallbacks_json"

    # Ensure valid JSON defaults for args passed via --argjson
    # short_ids: JSON array; sockopt_json: JSON object; external_proxy_json: JSON array
    if [ -z "${short_ids:-}" ]; then
        if command -v generate_short_ids >/dev/null 2>&1; then
            short_ids=$(generate_short_ids 8 8 2>/dev/null) || short_ids='["" ]'
        else
            short_ids='["" ]'
        fi
    fi
    if [ -z "${sockopt_json:-}" ]; then
        sockopt_json=$(generate_sockopt_json 2>/dev/null || printf '{}')
        [ -n "$sockopt_json" ] || sockopt_json='{}'
    fi
    if [ -z "${external_proxy_json:-}" ]; then
        if [ -n "${WEBDOMAIN:-}" ]; then
            external_proxy_json=$(jq -nc --arg dest "$WEBDOMAIN" --argjson port 443 '[{forceTls: "same", dest: $dest, port: $port, remark: ""}]')
        else
            external_proxy_json='[]'
        fi
    fi
    [ -n "${allocate_json:-}" ] || allocate_json='{"strategy":"always","refresh":5,"concurrency":3}'

    # Прокидываем выбранный auth (PQ/X25519) в настройки VLESS
    dec=${VLESS_DEC:-none}
    enc=${VLESS_ENC:-none}
    label=${VLESS_LABEL:-}
    # Override auth-free settings to match requested shape
    settings_json=$( \
      jq -nc \
        --arg dec "$dec" \
        --arg enc "$enc" \
        --arg label "$label" \
        --argjson fallbacks "$fallbacks_json" '
          (
            if ($dec=="none" and $enc=="none")
            then {clients: [], decryption: $dec, encryption: $enc, fallbacks: $fallbacks}
            else {clients: [], decryption: $dec, encryption: $enc}
            end
          ) as $base
          | if ($label|length)>0 then $base + {selectedAuth: $label} else $base end
        ' \
    )

    stream_json=$( \
      jq -nc \
        --arg target "traefik:$PORT_LOCAL_TRAEFIK" \
        --arg sni "$WEBDOMAIN" \
        --arg priv "$X25519_PRIVATE_KEY" \
        --arg pub "$X25519_PUBLIC_KEY" \
        --arg mldseed "${MLD_SA_SEED:-}" \
        --arg mldverify "${MLD_SA_VERIFY:-}" \
        --arg fingerprint "chrome" \
        --arg spider "/" \
        --argjson shortIds "$short_ids" \
        --argjson sockopt "$sockopt_json" \
        --argjson externalProxy "$external_proxy_json" '{
        network: "tcp",
        security: "reality",
        externalProxy: $externalProxy,
        realitySettings: {
          show: true,
          xver: 0,
          target: $target,
          serverNames: [$sni],
          privateKey: $priv,
          minClientVer: "",
          maxClientVer: "",
          maxTimediff: 0,
          shortIds: $shortIds,
          mldsa65Seed: $mldseed,
          settings: {
            publicKey: $pub,
            fingerprint: $fingerprint,
            serverName: "",
            spiderX: $spider,
            mldsa65Verify: $mldverify
          }
        },
        sockopt: $sockopt,
        tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
      }' \
    )

    sniffing_json=$(jq -nc '{
        enabled: true,
        destOverride: ["http","tls","quic","fakedns"],
        metadataOnly: false,
        routeOnly: false
    }')

    # Запрос к API
    panel_api_request POST "$API_URL_INBOUND_ADD" \
        --data-urlencode "up=0" \
        --data-urlencode "down=0" \
        --data-urlencode "total=0" \
        --data-urlencode "remark=${EMOJI_FLAG} vless-tcp-reality" \
        --data-urlencode "enable=true" \
        --data-urlencode "expiryTime=0" \
        --data-urlencode "listen=" \
        --data-urlencode "port=$PORT_LOCAL_VISION" \
        --data-urlencode "protocol=vless" \
        --data-urlencode "settings=$settings_json" \
        --data-urlencode "streamSettings=$stream_json" \
        --data-urlencode "sniffing=$sniffing_json" \
        --data-urlencode "allocate=$allocate_json"

    # Ответ
    if [ "$HTTP_CODE" -eq 200 ] && printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        inbound_id=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.id')
        log INFO "Inbound создан: ID=$inbound_id"
        printf '%s\n' "$inbound_id"
    else
        log ERROR "Ошибка создания inbound: HTTP $HTTP_CODE — $HTTP_BODY"
        return 1
    fi
}

create_xhttp_inbound() {
    refresh_api_urls
    port=${PORT_LOCAL_XHTTP}
    xhttp_path=${URI_VLESS_XHTTP}

    # Получаем рекомендованные параметры шифрования VLESS (PQ/X25519)
    use_pq=${USE_VLESS_PQ:-true}
    if [ "$use_pq" = "true" ]; then
        if ! get_new_vless_enc; then
            log ERROR "Не удалось получить параметры шифрования VLESS для XHTTP."
            return 1
        fi
    else
        VLESS_DEC="none"
        VLESS_ENC="none"
        VLESS_LABEL=""
        log INFO "VLESS PQ disabled for XHTTP (USE_VLESS_PQ=$use_pq); decryption/encryption set to none."
    fi
    vless_dec=${VLESS_DEC:-none}
    vless_enc=${VLESS_ENC:-none}
    vless_label=${VLESS_LABEL:-}

    settings_json=$(
      jq -nc \
        --arg dec "$vless_dec" \
        --arg enc "$vless_enc" \
        --arg label "$vless_label" '
        {
          clients: [],
          decryption: $dec,
          encryption: $enc
        }
        | if ($label|length)>0 then . + {selectedAuth:$label} else . end
      '
    )
    sockopt_json=$(generate_sockopt_json acceptProxyProtocol=false tcpFastOpen=true domainStrategy="UseIP" tproxy="tproxy")
    external_proxy_json=$(
      jq -nc --arg dest "$WEBDOMAIN" --argjson port 443 \
        '[{forceTls: "same", dest: $dest, port: $port, remark: ""}]'
    )
    stream_json=$(
      jq -nc --arg path "$xhttp_path" \
             --arg host "$WEBDOMAIN" \
             --argjson sockopt "$sockopt_json" \
             --argjson externalProxy "$external_proxy_json" '
      {
        network: "xhttp",
        security: "none",
        externalProxy: $externalProxy,
        sockopt: $sockopt,
        xhttpSettings: {
          path: $path,
          host: $host,
          headers: {
              "Server": "nginx",
              "Content-Type": "text/html; charset=UTF-8",
              "Cache-Control": "no-cache",
              "Connection": "keep-alive",
              "Access-Control-Allow-Origin": ("https://" + $host),
              "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
              "Access-Control-Allow-Headers": "Content-Type"
          },
          scMaxBufferedPosts: 50,
          scMaxEachPostBytes: "5000000",
          scStreamUpServerSecs: "5-20",  
          noSSEHeader: true,
          xPaddingBytes: "100-1000",
          mode: "packet-up"
        }
      }'
    )

    sniffing_json='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
    allocate_json='{"strategy":"always","refresh":5,"concurrency":3}'

    panel_api_request POST "$API_URL_INBOUND_ADD" \
        -b "$COOKIE_JAR" \
        --data-urlencode "up=0" \
        --data-urlencode "down=0" \
        --data-urlencode "total=0" \
        --data-urlencode "remark=${EMOJI_FLAG} vless-xhttp" \
        --data-urlencode "enable=true" \
        --data-urlencode "expiryTime=0" \
        --data-urlencode "listen=" \
        --data-urlencode "port=$port" \
        --data-urlencode "protocol=vless" \
        --data-urlencode "settings=$settings_json" \
        --data-urlencode "streamSettings=$stream_json" \
        --data-urlencode "sniffing=$sniffing_json" \
        --data-urlencode "allocate=$allocate_json"

    if [ "$HTTP_CODE" -eq 200 ] && printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        inbound_id=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.id')
        log INFO "XHTTP inbound создан: ID=$inbound_id"
        printf '%s\n' "$inbound_id"
    else
        log ERROR "Ошибка создания inbound XHTTP: $HTTP_BODY"
        return 1
    fi
}

generate_client_meta() {
    CLIENT_ID=$(cat /proc/sys/kernel/random/uuid)
    CLIENT_FLOW="xtls-rprx-vision"
    CLIENT_EMAIL="user_$(gen_rand_str 8)"
    CLIENT_SUBID=$(gen_rand_str 8)
    log INFO "generate_client_meta: id=$CLIENT_ID, flow=$CLIENT_FLOW, email=$CLIENT_EMAIL, subId=$CLIENT_SUBID"
}

add_client_to_inbound() {
    refresh_api_urls
    inbound_id="$1"
    subid="$2"
    flow="${3:-}"    # по умолчанию пустой или можно задать "xtls-rprx-vision"
    email="${4:-user_$(gen_rand_str 8)}"

    log INFO "Добавление клиента к inbound ID=$inbound_id с subId=$subid, flow='$flow', email='$email'..."

    # Генерируем UUID для id клиента
    if [ -r /proc/sys/kernel/random/uuid ]; then
        client_uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        client_uuid=$(gen_rand_str 36)
    fi

    # Получаем текущие настройки инбаунда, чтобы не терять PQ decryption/encryption/selectedAuth
    panel_api_request GET "$API_URL_INBOUND_LIST" \
        -H 'X-Requested-With: XMLHttpRequest'
    existing_settings=$(printf '%s' "$HTTP_BODY" | jq -c --arg id "$inbound_id" '
      .obj[] | select(.id == ($id|tonumber)) | .settings | fromjson
    ' 2>/dev/null)
    # Текущие PQ-параметры: берем из инбаунда или из окружения
    dec=$(printf '%s' "${existing_settings:-}" | jq -r '.decryption // empty' 2>/dev/null)
    enc=$(printf '%s' "${existing_settings:-}" | jq -r '.encryption // empty' 2>/dev/null)
    label=$(printf '%s' "${existing_settings:-}" | jq -r '.selectedAuth // empty' 2>/dev/null)
    # Если глобально PQ отключён — не подставляем selectedAuth
    if [ "${USE_VLESS_PQ:-true}" != "true" ]; then
        dec=${dec:-none}
        enc=${enc:-none}
        label=""
    fi
    [ -n "$dec" ] || dec=${VLESS_DEC:-none}
    [ -n "$enc" ] || enc=${VLESS_ENC:-none}
    [ -n "$label" ] || label=${VLESS_LABEL:-}
    # Базовые настройки для слияния
    if [ -z "$existing_settings" ]; then
        existing_settings='{}'
    fi
    # Собираем JSON для form-data, добавляя клиента и сохраняя PQ-поля
    settings_json=$(printf '%s' "$existing_settings" | jq -c \
      --arg id    "$client_uuid" \
      --arg flow  "$flow" \
      --arg email "$email" \
      --arg sid   "$subid" \
      --arg dec   "$dec" \
      --arg enc   "$enc" \
      --arg label "$label" '
      .clients = ((.clients // []) + [
        {
          id:         $id,
          flow:       $flow,
          email:      $email,
          limitIp:    0,
          totalGB:    0,
          expiryTime: 0,
          enable:     true,
          tgId:       "",
          subId:      $sid,
          comment:    "",
          reset:      0
        }
      ]) |
      .decryption = ($dec // "none") |
      .encryption = ($enc // "none") |
      (if ($label|length)>0 then .selectedAuth = $label else . end)
    ')

    # Отправляем запрос с таймаутами
    panel_api_request POST "$API_URL_ADD_CLIENT" \
        --data-urlencode "id=$inbound_id" \
        --data-urlencode "settings=$settings_json"

    if [ "$HTTP_CODE" -ne 200 ]; then
        log ERROR "Не удалось добавить клиента (HTTP $HTTP_CODE): $HTTP_BODY"
        return 1
    fi

    # Проверяем success
    if printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        log INFO "Клиент успешно добавлен: id=$client_uuid, email=$email, subId=$subid, flow=$flow."
        return 0
    else
        log ERROR "addClient success=false: $HTTP_BODY"
        return 1
    fi
}

# generate_sockopt_json [key1=val1 ...]
generate_sockopt_json() {
    # Фолбэк по умолчанию для каждого параметра:
    V6Only="${V6Only:-false}"
    acceptProxyProtocol="${acceptProxyProtocol:-false}"
    dialerProxy="${dialerProxy:-}"
    domainStrategy="${domainStrategy:-AsIs}"
    interface="${interface:-}"
    mark="${mark:-0}"
    penetrate="${penetrate:-true}"
    tcpFastOpen="${tcpFastOpen:-true}"
    tcpKeepAliveIdle="${tcpKeepAliveIdle:-300}"
    tcpKeepAliveInterval="${tcpKeepAliveInterval:-0}"
    tcpMaxSeg="${tcpMaxSeg:-1440}"
    tcpMptcp="${tcpMptcp:-false}"
    tcpUserTimeout="${tcpUserTimeout:-10000}"
    tcpWindowClamp="${tcpWindowClamp:-600}"
    tcpcongestion="${tcpcongestion:-bbr}"
    tproxy="${tproxy:-off}"

    # Переопределяем значениями из key=val, если есть (позиционные параметры)
    for arg in "$@"; do
        key=$(printf '%s' "$arg" | cut -d= -f1)
        val=$(printf '%s' "$arg" | cut -d= -f2-)
        eval "$key=\"\$val\""
    done

    # Выводим валидный JSON через jq
    jq -nc --argjson V6Only "$V6Only" \
           --argjson acceptProxyProtocol "$acceptProxyProtocol" \
           --arg dialerProxy "$dialerProxy" \
           --arg domainStrategy "$domainStrategy" \
           --arg interface "$interface" \
           --argjson mark "$mark" \
           --argjson penetrate "$penetrate" \
           --argjson tcpFastOpen "$tcpFastOpen" \
           --argjson tcpKeepAliveIdle "$tcpKeepAliveIdle" \
           --argjson tcpKeepAliveInterval "$tcpKeepAliveInterval" \
           --argjson tcpMaxSeg "$tcpMaxSeg" \
           --argjson tcpMptcp "$tcpMptcp" \
           --argjson tcpUserTimeout "$tcpUserTimeout" \
           --argjson tcpWindowClamp "$tcpWindowClamp" \
           --arg tcpcongestion "$tcpcongestion" \
           --arg tproxy "$tproxy" '
    {
      V6Only: $V6Only,
      acceptProxyProtocol: $acceptProxyProtocol,
      dialerProxy: $dialerProxy,
      domainStrategy: $domainStrategy,
      interface: $interface,
      mark: $mark,
      penetrate: $penetrate,
      tcpFastOpen: $tcpFastOpen,
      tcpKeepAliveIdle: $tcpKeepAliveIdle,
      tcpKeepAliveInterval: $tcpKeepAliveInterval,
      tcpMaxSeg: $tcpMaxSeg,
      tcpMptcp: $tcpMptcp,
      tcpUserTimeout: $tcpUserTimeout,
      tcpWindowClamp: $tcpWindowClamp,
      tcpcongestion: $tcpcongestion,
      tproxy: $tproxy
    }'
}

get_new_x25519_cert() {
    refresh_api_urls
    log INFO "Получение ключей X25519 для Reality (GET)."
    # using unified API URL and method via panel_api_request
    panel_api_request GET "$API_URL_GET_X25519"
    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при получении X25519: $HTTP_BODY"
        return 1
    fi
    if ! printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        log ERROR "Ответ success=false на X25519: $HTTP_BODY"
        return 1
    fi
    X25519_PRIVATE_KEY=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.privateKey // empty' 2>/dev/null)
    X25519_PUBLIC_KEY=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.publicKey // empty' 2>/dev/null)
    if [ -z "$X25519_PRIVATE_KEY" ] || [ -z "$X25519_PUBLIC_KEY" ]; then
        log ERROR "В ответе отсутствует privateKey или publicKey: $HTTP_BODY"
        return 1
    fi
    log INFO "Получены X25519 privateKey и publicKey."
}

get_new_vless_enc() {
    refresh_api_urls
    log INFO "Запрос параметров шифрования VLESS (PQ/X25519) — GET."
    # using unified API URL and method via panel_api_request
    panel_api_request GET "$API_URL_GET_VLESS_ENC"
    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при getNewVlessEnc: $HTTP_BODY"
        return 1
    fi
    if ! printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        log ERROR "getNewVlessEnc success=false: $HTTP_BODY"
        return 1
    fi
    local pick label_prefer
    # По умолчанию пытаемся взять именно ML-KEM-768 (Post-Quantum),
    # но позволяем переопределить через VLESS_AUTH_LABEL.
    label_prefer=${VLESS_AUTH_LABEL:-"ML-KEM-768, Post-Quantum"}
    # Выбор auth:
    # 1) Точный label (по умолчанию ML-KEM-768, Post-Quantum)
    # 2) Если VLESS_PREFER_PQ=true — берем любое Post-Quantum (label содержит post-quantum/ml-kem)
    # 3) По умолчанию X25519, not Post-Quantum
    pick=$(printf '%s' "$HTTP_BODY" | jq -c --arg label "$label_prefer" '
      if ($label|length)>0 then
        .obj.auths[] | select(.label==$label)
      else empty end
    ' 2>/dev/null | head -n1)
    if [ -z "$pick" ] && [ "${VLESS_PREFER_PQ:-true}" = "true" ]; then
        pick=$(printf '%s' "$HTTP_BODY" | jq -c '
          .obj.auths[]
          | select(
              (.label // "" | ascii_downcase | contains("post-quantum"))
              or (.label // "" | ascii_downcase | contains("ml-kem"))
            )
        ' 2>/dev/null | head -n1)
    fi
    if [ -z "$pick" ]; then
        pick=$(printf '%s' "$HTTP_BODY" | jq -c '.obj.auths[] | select(.label=="X25519, not Post-Quantum")' 2>/dev/null | head -n1)
    fi
    if [ -z "$pick" ]; then
        pick=$(printf '%s' "$HTTP_BODY" | jq -c '.obj.auths[0] // empty' 2>/dev/null)
    fi
    VLESS_DEC=$(printf '%s' "$pick" | jq -r '.decryption // empty')
    VLESS_ENC=$(printf '%s' "$pick" | jq -r '.encryption // empty')
    VLESS_LABEL=$(printf '%s' "$pick" | jq -r '.label // empty')
    if [ -z "$VLESS_DEC" ] || [ -z "$VLESS_ENC" ]; then
        log ERROR "Не удалось получить encryption/decryption из getNewVlessEnc."
        return 1
    fi
    [ -z "$VLESS_LABEL" ] && VLESS_LABEL="X25519, not Post-Quantum"
    log DEBUG "get_new_vless_enc: label='$VLESS_LABEL'"
    log DEBUG "get_new_vless_enc: decryption='${VLESS_DEC:0:48}...' encryption='${VLESS_ENC:0:48}...'"
    log INFO "Выбран auth: $VLESS_LABEL"
}

get_new_mldsa65() {
    refresh_api_urls
    log INFO "Запрос mldsa65 seed/verify — GET."
    # using unified API URL and method via panel_api_request
    panel_api_request GET "$API_URL_GET_MLDSA65"
    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при getNewmldsa65: $HTTP_BODY"
        return 1
    fi
    if ! printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        log ERROR "getNewmldsa65 success=false: $HTTP_BODY"
        return 1
    fi
    MLD_SA_SEED=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.seed // empty' 2>/dev/null)
    MLD_SA_VERIFY=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.verify // empty' 2>/dev/null)
    if [ -z "$MLD_SA_SEED" ] || [ -z "$MLD_SA_VERIFY" ]; then
        log ERROR "Не удалось получить mldsa65 seed/verify"
        return 1
    fi
    log DEBUG "get_new_mldsa65: seed='${MLD_SA_SEED:0:48}...' verify='${MLD_SA_VERIFY:0:48}...'"
    log INFO "Получены mldsa65 seed/verify."
}

check_inbound_exists() {
    port="$1"
    log INFO "Проверка существующего inbound на порту $port..."
    panel_api_request GET "$API_URL_INBOUND_LIST" \
        -H 'X-Requested-With: XMLHttpRequest'
    if [ "$HTTP_CODE" -ne 200 ]; then
        log WARN "Не удалось получить список inbound (HTTP $HTTP_CODE)."
        printf ''
        return 0
    fi
    existing=$(printf '%s' "$HTTP_BODY" | \
        jq -r --arg p "$port" '
          .obj[]
          | select(.port == ($p|tonumber))
          | .id
          | tostring
        ' 2>/dev/null | head -n1)
    if [ -n "$existing" ]; then
        log INFO "Найден существующий inbound: ID=$existing"
        printf '%s' "$existing"
    else
        log INFO "Inbound на порту $port не найден."
        printf ''
    fi
}
