

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
               subJsonURI subJsonFragment subJsonNoises subJsonMux subJsonRules subJsonEnable \
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

