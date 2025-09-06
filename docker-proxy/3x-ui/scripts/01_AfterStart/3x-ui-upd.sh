#!/bin/sh
# set -euo pipefail

: "${XUI_BIN_FOLDER:=/app/bin}"
# Файл для хранения cookies
COOKIE_JAR="cookies.txt"
# Статус последней попытки логина: 0=успех, !=0 — ошибка
GLOBAL_LOGIN_STATUS=0
# Уровень логирования по умолчанию
LOGLEVEL=${LOGLEVEL:-INFO}

# Module loader (sources modules from 3x-ui-upd_modules next to this script)
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || dirname "$0")
MODULES_DIR="$SCRIPT_DIR/3x-ui-upd_modules"

load_modules() {
    [ -d "$MODULES_DIR" ] || return 0
    for m in $(find "$MODULES_DIR" -maxdepth 1 -type f -name "*.mod" 2>/dev/null | sort); do
        # shellcheck source=/dev/null
        . "$m"
    done
}

main() {
    log INFO "Запуск сценария 3x-ui обновления."
    load_modules 
    log INFO "Этап 1: Проверка и установка утилит."
    check_and_install_utils
    log INFO "Этап 2: Инициализация переменных окружения."
    init_env_vars
    detect_country_flag

    log INFO "Этап 3: Поиск URL панели и авторизация (по приоритету)."
    resolve_and_login

    log INFO "Этап 4: Обновление настроек панели."
    update_panel_settings

    log INFO "Этап 5: Обновление логина/пароля администратора (опционально)."
    update_admin_credentials

    log INFO "Этап 6: Создание/проверка инбаундов."
    SUBSCRIPTION_ID=$(gen_rand_str 16)
    EXISTING_VISION_ID=$(check_inbound_exists "$PORT_LOCAL_VISION")
    EXISTING_XHTTP_ID=$(check_inbound_exists "$PORT_LOCAL_XHTTP")

    if [ -n "$EXISTING_VISION_ID" ]; then
        log INFO "Inbound Vision (порт $PORT_LOCAL_VISION) уже существует (ID=$EXISTING_VISION_ID). Пропускаем создание."
        INBOUND_VISION_ID=$EXISTING_VISION_ID
    else
        log INFO "Inbound Vision (порт $PORT_LOCAL_VISION) не существует. Создаём новый."
        INBOUND_VISION_ID=$(create_inbound_tcp_reality)
        log INFO "Vision inbound создан: ID=$INBOUND_VISION_ID"
        add_client_to_inbound "$INBOUND_VISION_ID" "$SUBSCRIPTION_ID" "xtls-rprx-vision"
    fi

    if [ -n "$EXISTING_XHTTP_ID" ]; then
        log INFO "Inbound XHTTP (порт $PORT_LOCAL_XHTTP) уже существует (ID=$EXISTING_XHTTP_ID). Пропускаем создание."
        INBOUND_XHTTP_ID=$EXISTING_XHTTP_ID
    else
        log INFO "Inbound XHTTP (порт $PORT_LOCAL_XHTTP) не существует. Создаём новый."
        INBOUND_XHTTP_ID=$(create_xhttp_inbound)
        log INFO "XHTTP inbound создан: ID=$INBOUND_XHTTP_ID"
        add_client_to_inbound "$INBOUND_XHTTP_ID" "$SUBSCRIPTION_ID"
    fi

    log INFO "Этап 7: Генерация новых настроек xray."
    update_xray_settings
    log INFO "Этап 8: Обновление настроек xray."
    apply_xray_settings

    log INFO "Этап 9: Перезагрузка консоли."
    restart_console

    log INFO "Этап 10: Перезагрузка XRAY."
    restart_xray

    rm -f "$COOKIE_JAR"

    log INFO "Сценарий выполнен успешно."
}

main "$@"
exit 0