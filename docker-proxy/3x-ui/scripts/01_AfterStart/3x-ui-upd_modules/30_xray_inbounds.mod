
get_new_x25519_cert() {
    log INFO "Получение сертификатов X25519."
    url="$URL_BASE_RESOLVED/server/getNewX25519Cert"

    # Отправляем POST-запрос и сохраняем ответ в HTTP_BODY/HTTP_CODE
    http_request POST "$url" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/x-www-form-urlencoded'

    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "HTTP $HTTP_CODE при получении X25519: $HTTP_BODY"
        return 1
    fi

    # Проверяем поле success
    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false' 2>/dev/null)
    if [ "$success" != "true" ]; then
        log ERROR "Сервер вернул success=false при X25519: $HTTP_BODY"
        return 1
    fi

    # Извлекаем ключи
    X25519_PRIVATE_KEY=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.privateKey // empty' 2>/dev/null)
    X25519_PUBLIC_KEY=$(printf '%s' "$HTTP_BODY" | jq -r '.obj.publicKey // empty' 2>/dev/null)

    if [ -z "$X25519_PRIVATE_KEY" ] || [ -z "$X25519_PUBLIC_KEY" ]; then
        log ERROR "В ответе отсутствуют privateKey или publicKey: $HTTP_BODY"
        return 1
    fi

    log INFO "Получены X25519 privateKey и publicKey."
    return 0
}

create_inbound_tcp_reality() {
    # Получаем X25519 ключи
    get_new_x25519_cert || exit 1

    fallbacks_json=$(
    jq -nc \
        --arg port_xhttp "$PORT_LOCAL_XHTTP" \
        --arg path_xhttp "$path_xhttp" \
        --arg port_traefik "$PORT_LOCAL_TRAEFIK" '
        [
            {
              alpn: "h1 h2 h3",
              path: "",
              dest: ("traefik:" + $port_traefik),
              xver: 2
            },
            {
              name: "",
              alpn: "h2 h3",
              dest: ("127.0.0.1:" + $port_xhttp),
              path: "",
              xver: 2
            }
        ]
        ' 
    )

    # JSON конфиг: settings (без клиентов)
    settings_json=$(
        jq -nc --argjson fallbacks "$fallbacks_json" '{
            clients: [],
            decryption: "none",
            fallbacks: $fallbacks
        }'
    )

    # sockopt, externalProxy
    sockopt_json=$(generate_sockopt_json acceptProxyProtocol=false tcpFastOpen=true domainStrategy="UseIP" tproxy="tproxy")
    external_proxy_json=$(jq -nc --arg dest "$WEBDOMAIN" --argjson port 443 '[
        { forceTls: "same", dest: $dest, port: $port, remark: "" }
    ]')

    # ShortIDs (в Reality — обязательны)
    short_ids=$(generate_short_ids 8 6 | tr -d '[:space:]')

    # streamSettings
    stream_json=$(
      jq -nc \
        --arg dest "traefik:$PORT_LOCAL_TRAEFIK" \
        --arg priv "$X25519_PRIVATE_KEY" \
        --arg pub "$X25519_PUBLIC_KEY" \
        --arg sni "$WEBDOMAIN" \
        --arg fingerprint "chrome" \
        --arg spider "/" \
        --argjson shortIds "$short_ids" \
        --argjson sockopt "$sockopt_json" \
        --argjson externalProxy "$external_proxy_json" '
      {
        network: "tcp",
        security: "reality",
        externalProxy: $externalProxy,
        realitySettings: {
          show: true,
          xver: 0,
          dest: $dest,
          serverNames: [$sni],
          privateKey: $priv,
          minClient: "",
          maxClient: "",
          maxTimediff: 0,
          shortIds: $shortIds,
          settings: {
            publicKey: $pub,
            fingerprint: $fingerprint,
            serverName: "",
            spiderX: $spider
          }
        },
        sockopt: $sockopt,
        tcpSettings: {
          acceptProxyProtocol: false,
          header: { type: "none" }
        }
      }'
    )

    # sniffing / allocate
    sniffing_json=$(jq -nc '{
        enabled: true,
        destOverride: ["http","tls","quic"],
        metadataOnly: false,
        routeOnly: false
    }')
    allocate_json=$(jq -nc '{
        strategy: "always",
        refresh: 5,
        concurrency: 3
    }')

    # Запрос к API
    http_request POST "$URL_BASE_RESOLVED/panel/inbound/add" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
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
        exit 1
    fi
}

create_xhttp_inbound() {
    port=${PORT_LOCAL_XHTTP}
    xhttp_path=${URI_VLESS_XHTTP}

    settings_json=$(jq -nc '{
        clients: [],
        decryption: "none",
        fallbacks: []
    }')
    sockopt_json=$(generate_sockopt_json acceptProxyProtocol=false tcpFastOpen=true domainStrategy="UseIP" tproxy="tproxy")
    external_proxy_json=$(
      jq -nc --arg dest "$WEBDOMAIN" --argjson port 443 \
        '[{forceTls: "same", dest: $dest, port: $port, remark: ""}]'
    )
    stream_json=$(
        jq -nc --arg path "$xhttp_path" \
               --argjson sockopt "$sockopt_json" \
               --argjson externalProxy "$external_proxy_json" '
        {
          network: "xhttp",
          security: "none",
          externalProxy: $externalProxy,
          sockopt: $sockopt,
          xhttpSettings: {
            path: $path,
            host: "",
            headers: {},
            scMaxBufferedPosts: 30,
            scMaxEachPostBytes: "1000000",
            scStreamUpServerSecs: "20-80",
            noSSEHeader: false,
            xPaddingBytes: "100-1000",
            mode: "packet-up"
          }
        }'
    )
    sniffing_json='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
    allocate_json='{"strategy":"always","refresh":5,"concurrency":3}'

    http_request POST "${URL_BASE_RESOLVED}/panel/inbound/add" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
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

make_json() {
    template=$1; shift
    log INFO "make_json: шаблон='$template'"

    # Сохраняем параметры и обнуляем $@
    kvs="$*"
    set --

    for kv in $kvs; do
        key=${kv%%=*}
        val=${kv#*=}
        # Все значения передаём как строки
        esc=$(printf '%s' "$val" | sed "s/'/'\"'\"'/g")
        set -- "$@" --arg "$key" "$esc"
    done

    case "$template" in
        inbound_settings)
            filter='{
              clients:[{
                id:$id,flow:$flow,email:$email,limitIp:0,
                totalGB:0,expiryTime:0,enable:true,
                tgId:"",subId:$subId,comment:"",reset:0
              }],
              decryption:"none",fallbacks:[]
            }'
            ;;
        inbound_stream)
            filter='{
              network:"tcp",security:"reality",externalProxy:[],
              realitySettings:{
                show:false,xver:0,dest:$dest|fromjson,
                serverNames:[$(printf "%s" $dest|fromjson|split(":")[0])],
                privateKey:$priv, minClient:"", maxClient:"",
                maxTimediff:0,
                shortIds:($shortIds|fromjson),
                settings:{
                  publicKey:$pub, fingerprint:$fingerprint,
                  serverName:"", spiderX:$spider
                }
              },
              tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}
            }'
            ;;
        sniffing)
            filter='{
              enabled:(if ($enabled|type)=="string" then ($enabled|test("true")) else $enabled end),
              destOverride:($destOverride|fromjson),
              metadataOnly:(if ($metadataOnly|type)=="string" then ($metadataOnly|test("true")) else $metadataOnly end),
              routeOnly:(if ($routeOnly|type)=="string" then ($routeOnly|test("true")) else $routeOnly end)
            }'
            ;;
        allocate)
            filter='{strategy:$strategy,refresh:( $refresh|tonumber ),concurrency:( $concurrency|tonumber )}'
            ;;
        *)
            log ERROR "make_json: неизвестный шаблон '$template'"
            return 1
            ;;
    esac

    log DEBUG "make_json: jq -nc $* '$filter'"
    jq -nc "$@" "$filter" || {
        log ERROR "make_json: jq вернул ошибку при шаблоне '$template'"
        return 1
    }
}

check_inbound_exists() {
    port="$1"
    log INFO "Проверка существующего inbound на порту $port..."

    # Отправляем запрос на список inbound-ов
    http_request POST "${URL_BASE_RESOLVED}/panel/inbound/list" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode ""   # POST с пустым телом

    if [ "$HTTP_CODE" -ne 200 ]; then
        log WARN "Не удалось получить список inbound (HTTP $HTTP_CODE)."
        printf ''  # ничего не возвращаем
        return 0
    fi

    # Ищем в JSON obj[] элемент с порт==$port
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

add_client_to_inbound() {
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

    # Собираем JSON для form-data, используя параметры flow и email
    settings_json=$(jq -nc \
      --arg id    "$client_uuid" \
      --arg flow  "$flow" \
      --arg email "$email" \
      --arg sid   "$subid" '
      {
        clients: [
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
        ],
        decryption: "none"
      }'
    )

    # Отправляем запрос с таймаутами
    http_request POST "${URL_BASE_RESOLVED}/panel/api/inbounds/addClient" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
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
