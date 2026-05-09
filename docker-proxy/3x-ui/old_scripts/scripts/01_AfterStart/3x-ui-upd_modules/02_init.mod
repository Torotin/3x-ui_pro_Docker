#!/bin/bash
init_env_vars() {
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


check_and_install_utils() {
    # Список утилит:команда=пакет
    UTILS=" curl=curl
            jq=jq
            timeout=busybox
            openssl=openssl
            dig=bind-tools
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