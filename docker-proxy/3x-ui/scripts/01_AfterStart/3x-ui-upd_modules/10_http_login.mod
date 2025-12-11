#!/bin/bash
resolve_and_login() {
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
    pids=""
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
        pids="$pids $!"
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
        if [ -n "$pids" ]; then
            set -- $pids
            kill "$@" 2>/dev/null
            # Подчищаем завершения наших фоновых задач
            wait "$@" 2>/dev/null || true
        fi
    else
        if [ -n "$pids" ]; then
            set -- $pids
            wait "$@" || true
        fi
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
            log WARN "curl error при $method $url (код $ret), попыток осталось $attempts. Ждём $delay с..."
            sleep "$delay"
            delay=$((delay * 2))
        else
            log ERROR "curl окончательно не удался при $method $url после 3 попыток."
        fi
    done
}
