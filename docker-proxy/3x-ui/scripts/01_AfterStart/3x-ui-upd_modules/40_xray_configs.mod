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
    elif [ "$HTTP_CODE" != "200" ]; then
        log WARN "Не удалось отправить запрос (HTTP $HTTP_CODE), возможно Xray уже рестартанулся."
    else
        log INFO "Запрос на перезагрузку XRAY отправлен (HTTP $HTTP_CODE)."
    fi
}
