#!/bin/sh
# set -euo pipefail


# Файл для хранения cookies
COOKIE_JAR="cookies.txt"
# Статус последней попытки логина: 0=успех, !=0 — ошибка
GLOBAL_LOGIN_STATUS=0
# Уровень логирования по умолчанию
LOGLEVEL=${LOGLEVEL:-INFO}

log() {
    level=$1; shift
    level=$(printf '%s' "$level" | tr -d '[:space:]')
    [ -z "$level" ] && level=INFO
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        ERROR) current=1 ;; WARN*) current=2 ;; INFO) current=3 ;; DEBUG) current=4 ;; *) current=3 ;; 
    esac
    case "$LOGLEVEL" in
        ERROR) active=1 ;; WARN*) active=2 ;; INFO) active=3 ;; DEBUG) active=4 ;; *) active=3 ;; 
    esac
    [ "$current" -gt "$active" ] && return
    case "$level" in
        INFO)   color='\033[1;34m' ;; WARN*)  color='\033[1;33m' ;; ERROR) color='\033[1;31m' ;; DEBUG) color='\033[1;36m' ;; *) color='\033[0m' ;; 
    esac
    reset='\033[0m'
    printf '%s %b%s%b - %s\n' \
        "$timestamp" "$color" "$level" "$reset" "$*" >&2
}

# Определение флага страны по IP
detect_country_flag() {
    log INFO "Этап: Определение флага страны по IP."
    # Запрашиваем сервис геолокации
    resp=$(curl -sS --retry 1 --fail https://ipwho.is/) || {
        log WARN "Не удалось выполнить запрос к ipwho.is, используем ⚠."
        EMOJI_FLAG="⚠"
        return
    }
    # Парсим emoji-флаг
    emoji=$(printf '%s' "$resp" | jq -r '.flag.emoji // empty')
    if [ -z "$emoji" ]; then
        log WARN "Флаг страны не определён, используем ⚠."
        EMOJI_FLAG="⚠"
    else
        log INFO "Флаг страны: $emoji"
        EMOJI_FLAG="$emoji"
    fi
}

gen_rand_str() {
    length="${1:-8}"
    # urandom может не быть, но на Alpine всегда есть
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_short_ids() {
    # $1 — count, $2 — max_size (default: 8, 8)
    count="${1:-8}"
    max_size="${2:-8}"
    i=1
    result=""
    while [ "$i" -le "$count" ]; do
        # Рандомная длина от 2 до max_size
        if command -v od >/dev/null 2>&1; then
            len=$(od -An -N1 -tu1 < /dev/urandom | tr -d ' ' || echo 2)
            # len ∈ [0..255], приводим к [2..max_size]
            len=$((2 + len % (max_size - 1)))
        else
            len=6 # fallback если нет od
        fi

        # Генерируем hex строки выбранной длины
        if command -v openssl >/dev/null 2>&1; then
            hex="$(openssl rand -hex "$len" 2>/dev/null)"
        elif command -v xxd >/dev/null 2>&1; then
            hex="$(head -c "$len" /dev/urandom | xxd -p -c 256)"
        else
            hex="$(head -c "$len" /dev/urandom | od -An -vtx1 | tr -d ' \n')"
        fi

        if [ -n "$result" ]; then
            result="${result},\"$hex\""
        else
            result="\"$hex\""
        fi
        i=$((i + 1))
    done
    echo "[$result]"
}

get_new_x25519_cert() {
    log INFO "Этап: Получение сертификатов X25519."
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

check_and_install_utils() {
    log INFO "Этап 1: Проверка и установка утилит."

    # Список утилит:команда=пакет
    UTILS=" curl=curl
            jq=jq
            timeout=busybox
            openssl=openssl
            xxd=xxd"

    for item in $UTILS; do
        cmd=${item%%=*}
        pkg=${item#*=}
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log INFO "Утилита '$cmd' не найдена. Устанавливаю пакет '$pkg'."
            if ! apk add --no-cache "$pkg"; then
                log ERROR "Не удалось установить пакет '$pkg'!"
                exit 1
            fi
        fi
    done
}

http_request() {
    # http_request <METHOD> <URL> [curl args...]
    method=$1; url=$2; shift 2
    attempts=4
    delay=2

    while [ "$attempts" -gt 0 ]; do
        tmp=$(mktemp) || exit 1
        HTTP_CODE=$(
            curl -k -sS \
                 --connect-timeout 2 \
                 --max-time 5 \
                 -X "$method" \
                 --cookie "$COOKIE_JAR" \
                 --cookie-jar "$COOKIE_JAR" \
                 -w '%{http_code}' \
                 -o "$tmp" \
                 "$@" "$url"
        )
        ret=$?
        HTTP_BODY=$(cat "$tmp" 2>/dev/null || printf '')
        rm -f "$tmp"

        if [ $ret -eq 0 ] && [ -n "$HTTP_CODE" ]; then
            # Успешный вызов curl и получен код
            return 0
        fi

        attempts=$((attempts - 1))
        if [ "$attempts" -gt 0 ]; then
            log WARN "curl ошибся при $method $url (код $ret), попыток осталось $attempts. Ждём $delay с..."
            sleep "$delay"
            delay=$((delay * 2))
        else
            log ERROR "curl окончательно не удался при $method $url после 3 попыток."
        fi
    done
}

update_panel_settings() {
    log INFO "Этап 5: Обновление настроек панели."
    # Проверяем наличие базового URL и cookies
    if [ -z "${URL_BASE_RESOLVED:-}" ] || [ ! -f "$COOKIE_JAR" ]; then
        log ERROR "Нет URL или cookies"
        exit 1
    fi

    url="$URL_BASE_RESOLVED/panel/setting/update"
    # Собираем параметры --data-urlencode в позиционные параметры через set --
    set --
    for var in webListen webDomain webPort webCertFile webKeyFile webBasePath \
               sessionMaxAge pageSize expireDiff trafficDiff remarkModel datepicker \
               tgBotEnable tgBotToken tgBotProxy tgBotAPIServer tgBotChatId \
               tgRunTime tgBotBackup tgBotLoginNotify tgCpu tgLang \
               twoFactorEnable twoFactorToken xrayTemplateConfig subEnable \
               subTitle subListen subPort subPath subJsonPath subDomain \
               externalTrafficInformEnable externalTrafficInformURI subCertFile \
               subKeyFile subUpdates subEncrypt subShowInfo subURI \
               subJsonURI subJsonFragment subJsonNoises subJsonMux subJsonRules \
               timeLocation; do
        # Получаем значение переменной
        val=$(eval "printf '%s' \"\${$var:-}\"")
        if [ -n "$val" ]; then
            set -- "$@" "--data-urlencode" "$var=$val"
        fi
    done

    # Выполняем запрос с накопленными параметрами
    http_request POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -b "$COOKIE_JAR" \
        "$@"

    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "Не удалось обновить настройки: HTTP $HTTP_CODE"
        exit 1
    fi

    # Проверяем поле success в ответе
    if printf '%s' "$HTTP_BODY" | jq -e -r '.success // false' >/dev/null 2>&1; then
        log INFO "Настройки панели успешно обновлены."
    else
        log ERROR "Сервер вернул success=false при обновлении настроек"
        exit 1
    fi
}

init_env_vars() {
    log INFO "Этап 2: Инициализация переменных окружения."

    # Если есть файл .env — загружаем из него
    if [ -f ".env" ]; then
        log INFO "Найден файл .env — загружаем переменные окружения."
        . ./.env
    else
        log INFO "Файл .env не найден — используем значения по умолчанию."
        
        : "${USERNAME:=admin}"
        : "${PASSWORD:=admin}"
        : "${NEW_ADMIN_USERNAME:=}"
        : "${NEW_ADMIN_PASSWORD:=}"
        : "${CLIENT_COUNT:=1}"
        : "${URL_BASE_RESOLVED:=}"
        : "${webDomain:=}"
        : "${webListen:=}"
        : "${webPort:=2053}"
        : "${webCertFile:=}"
        : "${webKeyFile:=}"
        : "${webBasePath:=}"
        : "${sessionMaxAge:=}"
        : "${pageSize:=}"
        : "${expireDiff:=}"
        : "${trafficDiff:=}"
        : "${remarkModel:=}"
        : "${datepicker:=}"
        : "${tgBotEnable:=}"
        : "${tgBotToken:=}"
        : "${tgBotProxy:=}"
        : "${tgBotAPIServer:=}"
        : "${tgBotChatId:=}"
        : "${tgRunTime:=}"
        : "${tgBotBackup:=}"
        : "${tgBotLoginNotify:=}"
        : "${tgCpu:=}"
        : "${tgLang:=}"
        : "${twoFactorEnable:=}"
        : "${twoFactorToken:=}"
        : "${xrayTemplateConfig:=}"
        : "${subEnable:=}"
        : "${subTitle:=}"
        : "${subListen:=}"
        : "${subPort:=}"
        : "${subPath:=}"
        : "${subJsonPath:=}"
        : "${subDomain:=}"
        : "${externalTrafficInformEnable:=}"
        : "${externalTrafficInformURI:=}"
        : "${subCertFile:=}"
        : "${subKeyFile:=}"
        : "${subUpdates:=}"
        : "${subEncrypt:=}"
        : "${subShowInfo:=}"
        : "${subURI:=}"
        : "${subJsonURI:=}"
        : "${subJsonFragment:=}"
        : "${subJsonNoises:=}"
        : "${subJsonMux:=}"
        : "${subJsonRules:=}"
        : "${timeLocation:=}"
    fi
}

resolve_and_login() {
    log INFO "Этап 3+4: Поиск URL панели и авторизация (по приоритету)."

    # $1 = базовый адрес (например, http://localhost:2053)
    try_url() {
        base="$1"
        login_url="${base%/}/login"
        for user_pass in "$USERNAME:$PASSWORD" "${NEW_ADMIN_USERNAME:-}:$NEW_ADMIN_PASSWORD"; do
            user=${user_pass%%:*}; pass=${user_pass#*:}
            [ -z "$user" ] && continue
            log INFO "Проверка и логин на $login_url как '$user'."
            http_request POST "$login_url" \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                --data-urlencode "username=$user" \
                --data-urlencode "password=$pass" \
                --cookie-jar "$COOKIE_JAR"
            if [ "$HTTP_CODE" -eq 200 ] && printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
                URL_BASE_RESOLVED="${base%/}"
                URL_LOGIN="$login_url"
                USERNAME="$user"
                PASSWORD="$pass"
                log INFO "Успешный логин на $login_url под '$user'."
                return 0
            fi
        done
        return 1
    }

    # Нормализуем webBasePath (убираем ведущие/концевые слэши)
    bp=$(printf '%s' "$webBasePath" | sed 's|^/*||; s|/*$||')
    if [ -n "$bp" ]; then
        bp_arg="/$bp"
    else
        bp_arg=""
    fi

    # Сбор вариантов
    bases="
        http://127.0.0.1:2053
        https://127.0.0.1:2053
        http://localhost:2053
        https://localhost:2053
    "
    if [ -n "$WEBDOMAIN" ]; then
        bases="$bases
        http://$WEBDOMAIN${bp_arg}
        https://$WEBDOMAIN${bp_arg}
    "
    fi
    if [ -n "$WEBDOMAIN" ] && [ -n "$webPort" ] && [ "$webPort" != "2053" ]; then
        bases="$bases
        http://$WEBDOMAIN:$webPort${bp_arg}
        https://$WEBDOMAIN:$webPort${bp_arg}
    "
    fi
    if [ -n "$webPort" ] && [ "$webPort" != "2053" ]; then
        bases="$bases
        http://127.0.0.1:$webPort
        https://127.0.0.1:$webPort
        http://localhost:$webPort
        https://localhost:$webPort
    "
    fi

    # Каталог для временных файлов
    tmpdir="/tmp/resolve_and_login.$$"
    mkdir -p "$tmpdir"

    i=0
    for base in $(echo "$bases"); do
        [ -z "$base" ] && continue
        norm_base=$(printf '%s' "$base" | sed 's|\([^:]\)//*|\1/|g')
        case "$norm_base" in
            http://*|https://*) ;;
            *) continue ;;
        esac
        flag="$tmpdir/flag_$i"
        COOKIE_JAR_LOCAL="$tmpdir/cookies_$i.txt"
        (
            export COOKIE_JAR="$COOKIE_JAR_LOCAL"
            if try_url "$norm_base"; then
                echo "$norm_base" > "$flag"
                # Сохраняем переменные для восстановления во внешнем shell
                printf '%s\n' \
                    "URL_BASE_RESOLVED='$URL_BASE_RESOLVED'" \
                    "URL_LOGIN='$URL_LOGIN'" \
                    "USERNAME='$USERNAME'" \
                    "PASSWORD='$PASSWORD'" \
                    > "$tmpdir/vars"
                cp "$COOKIE_JAR_LOCAL" "$tmpdir/cookies_ok.txt"
            fi
        ) &
        i=$((i + 1))
    done

    # Максимальное время ожидания (например, 12 секунд)
    timeout=12
    elapsed=0
    found=""

    while [ "$elapsed" -lt "$timeout" ]; do
        for f in "$tmpdir"/flag_*; do
            [ -f "$f" ] || continue
            found=$(cat "$f")
            break 2
        done
        sleep 0.2
        elapsed=$((elapsed + 1))
    done

    # Дожидаемся завершения всех (kill только если найден успех)
    if [ -n "$found" ]; then
        kill $(jobs -p) 2>/dev/null
    else
        wait
    fi

    # --- ВОССТАНАВЛИВАЕМ ВСЁ В ОСНОВНОМ ПРОЦЕССЕ ---
    if [ -n "$found" ]; then
        [ -f "$tmpdir/vars" ] && . "$tmpdir/vars"
        [ -f "$tmpdir/cookies_ok.txt" ] && cp "$tmpdir/cookies_ok.txt" "$COOKIE_JAR"
        # --- DEBUG ВЫВОД ---
        log DEBUG "URL_BASE_RESOLVED=$URL_BASE_RESOLVED, URL_LOGIN=$URL_LOGIN, USERNAME=$USERNAME, PASSWORD=$PASSWORD, COOKIE_JAR=$COOKIE_JAR"
        ls -l "$COOKIE_JAR"
        log INFO "Успешный логин найден через $found"
        rm -rf "$tmpdir"
        return 0
    fi

    rm -rf "$tmpdir"
    log ERROR "Не удалось найти и залогиниться ни на одном из адресов."
    exit 1
}

attempt_login() {
    local user="$1" pass="$2"
    local resp_file; resp_file="$(mktemp)"
    local http_code
    http_code=$(
        curl -k -sS -i -o "$resp_file" -w "%{http_code}" \
            --cookie-jar "$COOKIE_JAR" \
            --header "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "username=$user" \
            --data-urlencode "password=$pass" \
            "$URL_LOGIN"
    )
    local body; body="$(sed -n '/^\r$/,$p' "$resp_file" | sed '1d' || echo "")"
    if [ "$http_code" = "200" ]; then
        if success=$(echo "$body" | jq -e -r '.success // false' 2>/dev/null); then
            [ "$success" = "true" ] && GLOBAL_LOGIN_STATUS=0 || GLOBAL_LOGIN_STATUS=1
        else
            GLOBAL_LOGIN_STATUS=1
        fi
    else
        GLOBAL_LOGIN_STATUS=1
    fi
    rm -f "$resp_file"
}

update_admin_credentials() {
    log INFO "Этап 6: Обновление логина/пароля администратора (опционально)."
    if [ -n "${NEW_ADMIN_USERNAME:-}" ] && [ -n "${NEW_ADMIN_PASSWORD:-}" ]; then
        url="$URL_BASE_RESOLVED/panel/setting/updateUser"
        http_request POST "$url" \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode "oldUsername=$USERNAME" \
            --data-urlencode "oldPassword=$PASSWORD" \
            --data-urlencode "newUsername=$NEW_ADMIN_USERNAME" \
            --data-urlencode "newPassword=$NEW_ADMIN_PASSWORD"
        if [ "$HTTP_CODE" != "200" ]; then
            log ERROR "Не удалось обновить логин/пароль администратора: HTTP $HTTP_CODE"
            exit 1
        fi
        success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')
        if [ "$success" = "true" ]; then
            log INFO "Логин/пароль администратора обновлены (новый логин='$NEW_ADMIN_USERNAME')."
            USERNAME=$NEW_ADMIN_USERNAME
            PASSWORD=$NEW_ADMIN_PASSWORD
        else
            log ERROR "Сервер вернул success=false при обновлении логина/пароля"
            exit 1
        fi
    else
        log INFO "NEW_ADMIN_USERNAME/NEW_ADMIN_PASSWORD не заданы. Шаг пропущен."
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

create_inbound_tcp_reality() {
    log INFO "Этап 7: Создание inbound VLESS+Reality без клиентов."

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

restart_console() {
    log INFO "Этап 8: Перезагрузка консоли."
    url="$URL_BASE_RESOLVED/panel/setting/restartPanel"
    http_request POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest'
    [ "$HTTP_CODE" != "200" ] && log ERROR "Не удалось отправить запрос: HTTP $HTTP_CODE" && exit 1

    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')
    [ "$success" = "true" ] || ( log ERROR "Сервер вернул success=false при перезагрузке" && exit 1 )

    log INFO "Консоль перезагружается."
}

restart_xray() {
    log INFO "Этап 9: Перезагрузка XRAY."
    url="$URL_BASE_RESOLVED/server/restartXrayService"
    http_request POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest'

    # Ошибки curl 35/56 ожидаемы, не флудим WARN
    if [ "$HTTP_CODE" = "000" ]; then
        log INFO "Xray скорее всего успешно перезапущен (соединение разорвано как ожидается)."
    elif [ "$HTTP_CODE" != "200" ]; then
        log WARN "Не удалось отправить запрос (HTTP $HTTP_CODE), возможно Xray уже рестартанулся."
    else
        log INFO "Запрос на перезагрузку XRAY отправлен (HTTP $HTTP_CODE)."
    fi
}

update_xray_settings() {
    log INFO "Этап: Получение и логирование текущих параметров XRAY."

    url="$URL_BASE_RESOLVED/panel/xray/"
    http_request POST "$url" \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:141.0) Gecko/20100101 Firefox/141.0' \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Accept-Language: ru-RU,ru;q=0.8,en-US;q=0.5,en;q=0.3' \
        -H 'Accept-Encoding: gzip, deflate, br, zstd' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: https://$WEBDOMAIN" \
        -H "Referer: https://$URL_BASE_RESOLVED/panel/xray" \
        --compressed

    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "Не удалось получить параметры XRAY: HTTP $HTTP_CODE"
        return 1
    fi

    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')
    if [ "$success" != "true" ]; then
        log ERROR "Сервер вернул success=false: $HTTP_BODY"
        return 1
    fi

    XRAY_RAW_OBJ=$(printf '%s' "$HTTP_BODY" | jq -r '.obj // empty')
    if [ -z "$XRAY_RAW_OBJ" ]; then
        log ERROR "В ответе отсутствует поле obj!"
        return 1
    fi

    XRAY_OBJ=$(printf '%s' "$XRAY_RAW_OBJ" | jq . 2>/dev/null)
    if [ -z "$XRAY_OBJ" ]; then
        log ERROR "Не удалось разобрать XRAY JSON из obj!"
        return 1
    fi

    XRAY_SETTINGS_JSON="$XRAY_OBJ"

    # Логируем полный XRAY-конфиг ДО изменений (единым блоком)
    log INFO "Текущий конфиг XRAY (до изменений):$(printf '%s' "$XRAY_SETTINGS_JSON" | jq .)"

    # --- Здесь возможна модификация XRAY_SETTINGS_JSON ---
    update_xray_outbounds

    # Логируем полный XRAY-конфиг ПОСЛЕ изменений (единым блоком)
    log INFO "Конфиг XRAY после изменений:$(printf '%s' "$XRAY_SETTINGS_JSON" | jq .)"

    # Экспорт для дальнейших этапов
    export XRAY_SETTINGS_JSON
}

update_xray_outbounds() {
    log INFO "Этап: Обновление outbounds в XRAY-конфиге."

    # 1. Проверка доступности warp-plus:1080
    if nc -z -w2 warp-plus 1080 2>/dev/null; then
        log INFO "Адрес warp-plus:1080 доступен. Продолжаем обработку."
    else
        log WARN "Адрес warp-plus:1080 недоступен. Outbound не будет добавлен."
        return 0
    fi

    # 2. Проверка наличия outbound с tag=WARP-PLUS, address=warp-plus, port=1080
    exists=$(echo "$XRAY_SETTINGS_JSON" | jq \
        '[.xraySetting.outbounds[]? | select(.tag == "WARP-PLUS" and .protocol == "socks" and .settings.servers[0].address == "warp-plus" and .settings.servers[0].port == 1080)] | length')

    if [ "$exists" -gt 0 ]; then
        log INFO "Outbound для warp-plus:1080 уже присутствует в конфиге."
        update_xray_routing_warp # Правило в routing всё равно может потребоваться
        return 0
    fi

    # 3. Добавление outbound
    new_outbound=$(jq -nc '{
        tag: "WARP-PLUS",
        protocol: "socks",
        settings: {
            servers: [
                {
                    address: "warp-plus",
                    port: 1080,
                    users: []
                }
            ]
        }
    }')

    update_xray_routing_warp

    # Добавляем в массив outbounds
    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq \
        --argjson outbound "$new_outbound" \
        '.xraySetting.outbounds += [$outbound]')

    log INFO "Outbound для warp-plus:1080 добавлен. Итоговый XRAY-конфиг:\n$(echo "$XRAY_SETTINGS_JSON" | jq .)"

    export XRAY_SETTINGS_JSON
}

update_xray_routing_warp() {
    log INFO "Этап: Обновление routing XRAY-конфига."

    # 1. Шаблон нового правила (валидный JSON)
    new_rule=$(jq -nc '{
      type: "field",
      outboundTag: "WARP-PLUS",
      domain: [
        "ext:geosite_RU.dat:category-gov-ru",
        "ext:geosite_RU.dat:yandex",
        "ext:geosite_RU.dat:steam",
        "ext:geosite_RU.dat:vk",
        "regexp:\\.ru$",
        "regexp:\\.su$",
        "regexp:\\.xn--p1ai$",
        "regexp:\\.xn--p1acf$",
        "regexp:\\.80asehdb$",
        "regexp:\\.c1avg$",
        "regexp:\\.80aswg$",
        "regexp:\\.80adxhks$",
        "regexp:\\.moscow$",
        "regexp:\\.d1acj3b$"
      ]
    }')

    # 2. Проверяем — есть ли уже правило с outboundTag=WARP-PLUS и type=field
    exists=$(echo "$XRAY_SETTINGS_JSON" | jq '[.xraySetting.routing.rules[]? | select(.type == "field" and .outboundTag == "WARP-PLUS")] | length')

    if [ "$exists" -gt 0 ]; then
        log INFO "Правило с outboundTag=WARP-PLUS уже присутствует в routing.rules. Ничего не добавляем."
        return 0
    fi

    # 3. Добавляем правило в массив rules
    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson rule "$new_rule" '.xraySetting.routing.rules += [$rule]')

    log INFO "Новое правило routing добавлено. Итоговый XRAY-конфиг:\n$(echo "$XRAY_SETTINGS_JSON" | jq .)"

    export XRAY_SETTINGS_JSON
}

apply_xray_settings() {
    log INFO "Этап: Отправка обновлённого XRAY-конфига (только xraySetting) на сервер."

    # 1. Извлекаем только xraySetting из полной структуры
    XRAY_XRAYSETTING=$(echo "$XRAY_SETTINGS_JSON" | jq -c '.xraySetting')

    # 2. Добавляем/проверяем наличие поля xrayTemplateConfig (чтобы не было ошибки парсинга)
    XRAY_XRAYSETTING=$(echo "$XRAY_XRAYSETTING" | jq '.xrayTemplateConfig = (.xrayTemplateConfig // {})')

    # 3. Логируем итоговый payload
    log INFO "Финальный xraySetting для отправки:\n$(echo "$XRAY_XRAYSETTING" | jq .)"

    # 4. Сохраняем в файл (curl будет читать его через @)
    echo "$XRAY_XRAYSETTING" > xraysetting.json

    url="$URL_BASE_RESOLVED/panel/xray/update"

    http_request POST "$url" \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:141.0) Gecko/20100101 Firefox/141.0' \
        -H 'Accept: application/json, text/plain, */*' \
        -H 'Accept-Language: ru-RU,ru;q=0.8,en-US;q=0.5,en;q=0.3' \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Origin: https://$WEBDOMAIN" \
        -H "Referer: https://$URL_BASE_RESOLVED/panel/xray" \
        --data-urlencode "xraySetting@xraysetting.json"

    # 5. Чистим временный файл
    rm -f xraysetting.json

    # 6. Проверка результата
    if [ "$HTTP_CODE" != "200" ]; then
        log ERROR "Ошибка при обновлении XRAY: HTTP $HTTP_CODE"
        return 1
    fi

    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')
    if [ "$success" != "true" ]; then
        log ERROR "Сервер вернул ошибку при обновлении XRAY: $HTTP_BODY"
        return 1
    fi

    log INFO "Параметры XRAY успешно обновлены."
    log DEBUG "Ответ сервера: $HTTP_BODY"
}

main() {
    log INFO "Запуск сценария 3x-ui обновления."

    check_and_install_utils
    init_env_vars
    resolve_and_login
    update_panel_settings
    update_admin_credentials

    detect_country_flag
    SUBSCRIPTION_ID=$(gen_rand_str 16)

    # --- Этап 7: Inbound Vision (TCP/Reality) ---
    EXISTING_VISION_ID=$(check_inbound_exists "$PORT_LOCAL_VISION")
    if [ -n "$EXISTING_VISION_ID" ]; then
        log INFO "Inbound Vision (порт $PORT_LOCAL_VISION) уже существует (ID=$EXISTING_VISION_ID). Пропускаем создание."
        INBOUND_VISION_ID=$EXISTING_VISION_ID
    else
        INBOUND_VISION_ID=$(create_inbound_tcp_reality)
        log INFO "Vision inbound создан: ID=$INBOUND_VISION_ID"
        add_client_to_inbound "$INBOUND_VISION_ID" "$SUBSCRIPTION_ID" "xtls-rprx-vision"
    fi

    # # --- Этап 7b: Inbound XHTTP ---
    EXISTING_XHTTP_ID=$(check_inbound_exists "$PORT_LOCAL_XHTTP")
    if [ -n "$EXISTING_XHTTP_ID" ]; then
        log INFO "Inbound XHTTP (порт $PORT_LOCAL_XHTTP) уже существует (ID=$EXISTING_XHTTP_ID). Пропускаем создание."
        INBOUND_XHTTP_ID=$EXISTING_XHTTP_ID
    else
        INBOUND_XHTTP_ID=$(create_xhttp_inbound)
        log INFO "XHTTP inbound создан: ID=$INBOUND_XHTTP_ID"
        add_client_to_inbound "$INBOUND_XHTTP_ID" "$SUBSCRIPTION_ID"
    fi

    update_xray_settings
    apply_xray_settings

    # --- Этап 8: рестарт панели ---
    restart_console
    # --- Этап 9: рестарт xray ---
    restart_xray

    # Очистка
    rm -f "$COOKIE_JAR"

    log INFO "Сценарий выполнен успешно."
}

main "$@"
exit 0