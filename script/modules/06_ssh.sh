#!/bin/bash
# lib/05_ssh.sh — Настройка SSH-сервера и политики доступа

# === Глобальные переменные (ожидаются извне) ===
: "${USER_SSH:=}"
: "${PORT_REMOTE_SSH:=}"
: "${SSH_PBK:=}"
msg_pubkey_auth=""

# === Главная точка входа ===
sshd_config() {
    log "INFO" "Starting SSH service configuration..."

    local ssh_config="/etc/ssh/sshd_config"

    # Проверка переменных и шаблона
    sshd_validate_input || return 1
    backup_file "$ssh_config"

    # Определение метода аутентификации
    sshd_define_auth_method

    # Генерация sshd_config из шаблона
    export USER_SSH PORT_REMOTE_SSH pubkey_auth PASS_SSH_auth
    generate_sshd_config_template "$TEMPLATE_DIR/sshd_config.template" "$ssh_config" || return 1

    # Проверка службы и конфигурации
    sshd_detect_service || return 1
    ssh_validate_config "$ssh_config" || return 1

    # Перезапуск и проверка статуса
    ssh_restart_service "$ssh_config"
}

# === Проверка входных переменных ===
sshd_validate_input() {
    if [[ -z "$PORT_REMOTE_SSH" || -z "$USER_SSH" ]]; then
        log "ERROR" "Missing required variables: PORT_REMOTE_SSH or USER_SSH."
        return 1
    fi
    if [[ ! -f /etc/ssh/sshd_config ]]; then
        exit_error "/etc/ssh/sshd_config not found. Ensure OpenSSH is installed."
    fi
    if [[ ! -f "$TEMPLATE_DIR/sshd_config.template" ]]; then
        exit_error "Template not found: $TEMPLATE_DIR/sshd_config.template"
    fi
    return 0
}

# === Определение метода аутентификации ===
sshd_define_auth_method() {
    if [[ -n "$SSH_PBK" ]]; then
        PASS_SSH_auth="no"
        pubkey_auth="yes"
        export msg_pubkey_auth="Authentication via public key"
    else
        PASS_SSH_auth="yes"
        pubkey_auth="no"
        export msg_pubkey_auth="Authentication via password"
    fi
}

# === Генерация sshd_config через шаблон ===
generate_sshd_config_template() {
    local template="$1"
    local output="$2"
    log "INFO" "Generating sshd_config from template..."
    envsubst < "$template" > "$output" || exit_error "Failed to generate sshd_config"
    log "OK" "sshd_config generated: $output"
}

# === Поиск и подготовка службы SSH ===
sshd_detect_service() {
    if systemctl list-units --type=service | grep -qw "sshd.service"; then
        SERVICE_NAME="sshd.service"
    elif systemctl list-units --type=service | grep -qw "ssh.service"; then
        SERVICE_NAME="ssh.service"
    elif systemctl list-units --type=socket | grep -qw "ssh.socket"; then
        SERVICE_NAME="ssh.socket"
        sudo mkdir -p /run/sshd
        sudo chown root:root /run/sshd
        sudo chmod 755 /run/sshd
    else
        exit_error "Neither ssh.service, sshd.service nor ssh.socket found. Ensure OpenSSH is installed."
    fi
    log "DEBUG" "Detected $SERVICE_NAME."
}


# === Проверка конфигурации SSH ===
ssh_validate_config() {
    local config="$1"
    if sshd -t -f "$config"; then
        log "DEBUG" "SSHD configuration syntax is valid."
        return 0
    else
        local error_message=$(sshd -t -f "$config" 2>&1)
        log "ERROR" "SSHD configuration contains errors. Fix before restarting."
        log "ERROR" "Error details: $error_message"
        return 1
    fi
}

# === Перезапуск SSH и откат при неудаче ===
ssh_restart_service() {
    local config="$1"
    if systemctl restart "$SERVICE_NAME" 2>/dev/null; then
        log "DEBUG" "$SERVICE_NAME restarted."
    else
        log "ERROR" "Failed to restart $SERVICE_NAME."
        restore_backup_file "$config"
        systemctl restart "$SERVICE_NAME" 2>/dev/null
        exit_error "Configuration restored. Please check SSH settings."
    fi

    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        log "OK" "$SERVICE_NAME is running."
    else
        restore_backup_file "$config"
        systemctl restart "$SERVICE_NAME" 2>/dev/null
        exit_error "$SERVICE_NAME failed to start. Restored previous config."
    fi
}
