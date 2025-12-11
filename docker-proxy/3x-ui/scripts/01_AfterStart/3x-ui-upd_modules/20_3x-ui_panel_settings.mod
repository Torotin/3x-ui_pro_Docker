#!/bin/bash


restart_console() {
    url="$URL_BASE_RESOLVED/panel/setting/restartPanel"
    http_request POST "$url" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest'
    [ "$HTTP_CODE" != "200" ] && log ERROR "Не удалось отправить запрос: HTTP $HTTP_CODE" && exit 1

    success=$(printf '%s' "$HTTP_BODY" | jq -r '.success // false')
    [ "$success" = "true" ] || ( log ERROR "Сервер вернул success=false при перезагрузке" && exit 1 )

    log INFO "Консоль перезагружается."
}

update_panel_settings() {
    # Проверяем наличие базового URL и cookies
    if [ -z "${URL_BASE_RESOLVED:-}" ] || [ ! -f "$COOKIE_JAR" ]; then
        log ERROR "Нет URL или cookies"
        exit 1
    fi

    # Получаем текущие настройки панели, чтобы не перетирать непереданные поля
    current_settings='{}'
    settings_url="$URL_BASE_RESOLVED/panel/setting/all"
    http_request POST "$settings_url" \
        -b "$COOKIE_JAR" \
        -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
        -H 'X-Requested-With: XMLHttpRequest'
    if [ "$HTTP_CODE" = "200" ] && printf '%s' "$HTTP_BODY" | jq -e '.success==true' >/dev/null 2>&1; then
        current_settings=$(printf '%s' "$HTTP_BODY" | jq -c '.obj // {}' 2>/dev/null || printf '{}')
        log INFO "Текущие настройки панели получены."
        log INFO "Полученные параметры: $(printf '%s' "$current_settings")"
    else
        log WARN "Не удалось получить текущие настройки панели (HTTP $HTTP_CODE). Продолжаем без них."
    fi

    # Normalize subscription-related values (strip quotes, expand templates)
    normalize_sub_value() {
        local name=$1 raw expanded
        raw=$(eval "printf '%s' \"\${$name:-}\"")
        case "$raw" in
            \"*\" ) raw=${raw#\"}; raw=${raw%\"};;
            \'*\' ) raw=${raw#\'}; raw=${raw%\'};;
        esac
        if [ -n "$raw" ]; then
            expanded=$(eval "printf '%s' \"$raw\"")
            raw=$expanded
        fi
        eval "$name=\$raw"
    }

    normalize_sub_value subPath
    normalize_sub_value subJsonPath
    normalize_sub_value subURI
    normalize_sub_value subJsonURI

    url="$URL_BASE_RESOLVED/panel/setting/update"
    # Собираем параметры --data-urlencode в позиционные параметры через set --
    set --
    param_list=""
    override_list=""
    for var in webListen webDomain webPort webCertFile webKeyFile webBasePath \
               sessionMaxAge pageSize expireDiff trafficDiff remarkModel datepicker \
               tgBotEnable tgBotToken tgBotProxy tgBotAPIServer tgBotChatId \
               tgRunTime tgBotBackup tgBotLoginNotify tgCpu tgLang \
               twoFactorEnable twoFactorToken xrayTemplateConfig subEnable \
               subTitle subListen subPort subPath subJsonPath subDomain \
               externalTrafficInformEnable externalTrafficInformURI subCertFile \
               subKeyFile subUpdates subEncrypt subShowInfo subURI \
               subJsonURI subJsonFragment subJsonNoises subJsonMux subJsonRules subJsonEnable \
               timeLocation; do
        # Получаем значение переменной
        env_val=$(eval "printf '%s' \"\${$var:-}\"")
        if [ -n "$env_val" ]; then
            val="$env_val"
            override_list="$override_list$var=$val "
        else
            val=$(printf '%s' "$current_settings" | jq -r --arg k "$var" 'if has($k) then .[$k] else "" end' 2>/dev/null)
        fi
        set -- "$@" "--data-urlencode" "$var=$val"
        param_list="$param_list$var=$val "
    done

    # Логируем, что именно отправляем
    log INFO "Отправляем запрос на обновление панели: $url"
    log INFO "Параметры (полный набор): $param_list"
    if [ -n "$override_list" ]; then
        log INFO "Изменяем параметры (из окружения): $override_list"
    else
        log INFO "Изменяем параметры (из окружения): нет"
    fi

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

update_admin_credentials() {
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
