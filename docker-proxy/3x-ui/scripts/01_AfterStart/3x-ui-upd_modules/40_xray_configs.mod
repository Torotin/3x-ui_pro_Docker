#!/bin/bash
update_xray_settings() {
    log INFO "Получение текущих параметров XRAY."

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
    log DEBUG "Текущий конфиг XRAY (до изменений):$(printf '%s' "$XRAY_SETTINGS_JSON" | jq .)"

    # --- Здесь возможна модификация XRAY_SETTINGS_JSON ---
    update_xray_outbounds

    # Логируем полный XRAY-конфиг ПОСЛЕ изменений (единым блоком)
    log DEBUG "Конфиг XRAY после изменений:$(printf '%s' "$XRAY_SETTINGS_JSON" | jq .)"

    # Экспорт для дальнейших этапов
    export XRAY_SETTINGS_JSON
}

update_xray_outbounds() {
    log INFO "Обновление outbounds в XRAY-конфиге."

    update_xray_routing_warp
    # TOR outbound + routing for .onion domains
    if command -v update_xray_tor >/dev/null 2>&1; then
        update_xray_tor || log WARN "TOR update failed; keeping existing TOR settings."
    else
        log DEBUG "TOR module not loaded; skipping TOR routing update."
    fi
    update_xray_dns || log WARN "DNS update failed; keeping existing DNS settings."

    log DEBUG "Итоговый XRAY-конфиг:\n$(echo "$XRAY_SETTINGS_JSON" | jq .)"

    export XRAY_SETTINGS_JSON
}

apply_xray_settings() {
    log INFO "Отправка обновлённого XRAY-конфига (только xraySetting) на сервер."

    # 1. Извлекаем только xraySetting из полной структуры
    XRAY_XRAYSETTING=$(echo "$XRAY_SETTINGS_JSON" | jq -c '.xraySetting')

    # 2. Добавляем/проверяем наличие поля xrayTemplateConfig (чтобы не было ошибки парсинга)
    XRAY_XRAYSETTING=$(echo "$XRAY_XRAYSETTING" | jq '.xrayTemplateConfig = (.xrayTemplateConfig // {})')

    # 3. Логируем итоговый XRAY_XRAYSETTING 
    log DEBUG "Финальный xraySetting для отправки: $(echo "$XRAY_XRAYSETTING" | jq .)"

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

restart_xray() {
    url="$URL_BASE_RESOLVED/server/restartXrayService"
    http_request POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest'

    # Ошибки curl 35/56 ожидаемы, не флудим WARN
    if [ "$HTTP_CODE" = "000" ]; then
        log INFO "Xray скорее всего успешно перезапущен (соединение разорвано как ожидается)."
        return 0
    elif [ "$HTTP_CODE" = "200" ]; then
        log INFO "Запрос на перезагрузку XRAY отправлен (HTTP $HTTP_CODE)."
        return 0
    fi

    # Fallback: локальный рестарт через бинарник (если API недоступен, например 404)
    local enable_local=${XRAY_LOCAL_RESTART:-true}
    if [ "$enable_local" != "true" ]; then
        log WARN "Не удалось отправить запрос (HTTP $HTTP_CODE), локальный рестарт отключён (XRAY_LOCAL_RESTART=$XRAY_LOCAL_RESTART)."
        return 1
    fi

    # Определяем бинарник и конфиг
    local xray_bin
    xray_bin=$(find_xray_bin) || return 1
    # Если уже запущен — не плодим второй процесс
    local running_pids
    running_pids=$(pgrep -f "$xray_bin" 2>/dev/null || pgrep -f 'xray.*config' 2>/dev/null || true)
    if [ -n "$running_pids" ]; then
        log DEBUG "Xray уже запущен (PID: $running_pids). Пропускаем локальный рестарт."
        return 0
    fi
    local cfg=""
    for c in ${XRAY_CONFIG_PATH:-} \
             /app/bin/config.json \
             /etc/xray/config.json \
             /usr/local/etc/xray/config.json \
             /usr/local/bin/config.json \
             /root/config.json; do
        [ -n "$c" ] && [ -f "$c" ] && { cfg="$c"; break; }
    done
    if [ -z "$cfg" ]; then
        log WARN "Конфиг Xray не найден (проверьте XRAY_CONFIG_PATH). Локальный рестарт не выполнен."
        return 1
    fi

    log WARN "API перезапуска недоступно (HTTP $HTTP_CODE). Пробуем локальный рестарт через бинарник: $xray_bin -c $cfg"
    # Стартуем новый процесс (если вдруг поднимется параллельно — pid проверяли выше)
    local restart_log
    restart_log=$(mktemp)
    "$xray_bin" run -c "$cfg" >"$restart_log" 2>&1 &
    sleep 1
    if pgrep -f "$xray_bin" >/dev/null 2>&1; then
        log INFO "Xray успешно запущен локально через бинарник."
        rm -f "$restart_log"
        return 0
    else
        log ERROR "Локальный запуск xray через бинарник не удался."
        if [ -f "$restart_log" ] && [ -s "$restart_log" ]; then
            log DEBUG "xray stderr: $(tr '\n' ' ' < \"$restart_log\" 2>/dev/null)"
        fi
        rm -f "$restart_log" 2>/dev/null || true
        return 1
    fi
}
