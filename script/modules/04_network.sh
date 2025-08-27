#!/bin/bash
#./lib/03_network.sh

# === Используемые глобальные переменные проекта ===
# LOG_LEVEL, PROJECT_ROOT, BACKUP_DIR, TEMPLATE_DIR, ENV_FILE, SYSCTL_CONF, и др.
# Они должны быть экспортированы в окружение до вызова этого скрипта.

: "${LOG_LEVEL:=INFO}"
: "${PROJECT_ROOT:=/mnt/share}"
: "${BACKUP_DIR:=${PROJECT_ROOT}/backup}"
: "${TEMPLATE_DIR:=${PROJECT_ROOT}/template}"
: "${SYSCTL_CONF:=/etc/sysctl.conf}"
: "${NETWORK_TEMPLATE:=${TEMPLATE_DIR}/99-xray-network.conf.template}"

# === Проверка версии ядра ===
check_kernel_version() {
    local required_version="4.9"
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)

    if [[ "$(printf '%s\n' "$required_version" "$kernel_version" | sort -V | head -n1)" != "$required_version" ]]; then
        log "ERROR" "BBR не поддерживается на ядрах ниже $required_version. Текущая версия ядра: $kernel_version"
        return 1
    fi
    log "INFO" "Проверка версии ядра пройдена. Текущая версия ядра: $kernel_version"
}

# === Загрузка модуля tcp_bbr ===
load_bbr_module() {
    if ! lsmod | grep -q "tcp_bbr"; then
        if ! modprobe tcp_bbr; then
            log "ERROR" "Не удалось загрузить модуль tcp_bbr."
            return 1
        fi
    fi
    log "INFO" "Модуль tcp_bbr успешно загружен."
}

# === Проверка поддержки BBR ===
network_check_bbr_support() {
    if sysctl net.ipv4.tcp_available_congestion_control | grep -qw "bbr"; then
        log "INFO" "BBR поддерживается ядром."
        return 0
    else
        log "ERROR" "BBR недоступен. Убедитесь, что ядро поддерживает BBR."
        return 1
    fi
}

# === Удаление старых сетевых настроек (BBR) ===
network_remove_bbr_settings() {
    local settings=("net.core.default_qdisc" "net.ipv4.tcp_congestion_control")
    local sed_script
    sed_script=$(mktemp)

    for setting in "${settings[@]}"; do
        echo "\|^\s*${setting}\s*=.*|d" >> "$sed_script"
    done

    sed -i -f "$sed_script" "$SYSCTL_CONF"
    rm "$sed_script"
    log "INFO" "Старые сетевые настройки удалены из $SYSCTL_CONF."
}

# === Генерация и применение сетевого конфига через шаблон ===
network_apply_template_settings() {
    local template_file="${1:-$NETWORK_TEMPLATE}"
    local sysctl_conf="${2:-$SYSCTL_CONF}"
    local tmp_conf
    tmp_conf=$(mktemp)

    # --- Новый блок: загрузка и автозагрузка nf_conntrack ---
    load_nf_conntrack_module

    if [[ ! -f "$template_file" ]]; then
        log "ERROR" "Шаблон сетевых настроек не найден: $template_file"
        return 1
    fi

    # Генерируем новый конфиг с помощью envsubst (или cat, если переменных нет)
    if grep -q '\${' "$template_file"; then
        envsubst < "$template_file" > "$tmp_conf"
    else
        cp "$template_file" "$tmp_conf"
    fi

    # Бэкапим старый конфиг
    backup_file "$sysctl_conf" || return 1

    # Удаляем старые BBR-настройки
    network_remove_bbr_settings

    # Добавляем/заменяем параметры из шаблона
    while IFS= read -r line; do
        # Пропускаем комментарии и пустые строки
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        local key="${line%%=*}"
        key="${key// /}"
        if grep -q "^\s*${key}\s*=" "$sysctl_conf"; then
            sed -i "s|^\s*${key}\s*=.*|${line}|" "$sysctl_conf"
        else
            echo "$line" >> "$sysctl_conf"
        fi
        log "DEBUG" "Применена настройка: $line"
    done < "$tmp_conf"

    rm "$tmp_conf"

    sysctl_output=$(sysctl -p 2>&1)
    sysctl_exit_code=$?

    # В лог DEBUG или INFO пишем только успешные строки (без 'sysctl:')
    echo "$sysctl_output" | grep -v '^sysctl:' | while read -r line; do
        [[ -n "$line" ]] && log "DEBUG" "$line"
    done

    # В лог ERROR пишем только ошибки sysctl
    echo "$sysctl_output" | grep '^sysctl:' | while read -r line; do
        log "ERROR" "$line"
    done

    # Если есть ошибки "cannot stat", вывести отдельную подсказку
    if echo "$sysctl_output" | grep -q 'cannot stat'; then
        log "WARN" "Некоторые параметры не поддерживаются вашим ядром или не загружен соответствующий модуль (например, nf_conntrack). Проверьте поддержку параметров и наличие необходимых модулей."
    fi

    if [[ $sysctl_exit_code -ne 0 ]]; then
        log "ERROR" "Не удалось применить сетевые настройки. Некоторые параметры не были применены."
        return 1
    fi
    log "INFO" "Сетевые настройки успешно применены из шаблона $template_file."
}



# === Загрузка и автозагрузка модуля nf_conntrack ===
load_nf_conntrack_module() {
    local module="nf_conntrack"
    local modules_load_dir="/etc/modules-load.d"
    local modules_load_file="${modules_load_dir}/nf_conntrack.conf"

    # Проверяем, загружен ли модуль
    if ! lsmod | grep -qw "$module"; then
        if modprobe "$module"; then
            log "INFO" "Модуль $module успешно загружен."
        else
            log "WARN" "Не удалось загрузить модуль $module. Некоторые параметры sysctl могут быть недоступны."
            return 1
        fi
    else
        log "INFO" "Модуль $module уже загружен."
    fi

    # Обеспечиваем автозагрузку при старте системы
    if [[ ! -d "$modules_load_dir" ]]; then
        mkdir -p "$modules_load_dir"
    fi
    if ! grep -qw "$module" "$modules_load_file" 2>/dev/null; then
        echo "$module" >> "$modules_load_file"
        log "INFO" "Модуль $module добавлен в автозагрузку ($modules_load_file)."
    else
        log "DEBUG" "Модуль $module уже присутствует в $modules_load_file для автозагрузки."
    fi
}

# === Проверка активации BBR ===
network_verify_bbr_activation() {
    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')

    if [[ "$current_cc" == "bbr" ]]; then
        log "INFO" "BBR успешно активирован."
        return 0
    else
        log "ERROR" "Не удалось активировать BBR."
        return 1
    fi
}

# === Основная функция для применения сетевого шаблона ===
network_config_modify() {
    local template_file="${1:-$NETWORK_TEMPLATE}"

    log "INFO" "Включение BBR и оптимизация сетевых настроек через шаблон..."

    check_kernel_version || return 1
    load_bbr_module || return 1
    network_check_bbr_support || return 1

    network_apply_template_settings "$template_file" "$SYSCTL_CONF" || {
        restore_backup_file "$SYSCTL_CONF"
        return 1
    }

    network_verify_bbr_activation || {
        restore_backup_file "$SYSCTL_CONF"
        return 1
    }

    log "INFO" "BBR успешно включен и настройки оптимизированы через шаблон."
}