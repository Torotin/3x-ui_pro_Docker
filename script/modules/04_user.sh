#!/bin/bash
# lib/04_user.sh — User management module

# === Глобальные переменные (ожидаются извне или из .env) ===
: "${TEMPLATE_DIR:=/opt/template}"
: "${PROJECT_ROOT:=/opt}"
: "${USER_SSH:=}"
: "${PASS_SSH:=}"
: "${SSH_PBK:=}"

# Получение домашней дирректории
get_home_dir() {
    eval echo "~$USER_SSH"
}

# === Главная функция ===
user_create() {
    log "INFO" "Starting full user setup: $USER_SSH"

    if [[ "$USER_SSH" == "root" ]]; then
        log "WARN" "Skipping setup for root user — not supported by design."
        return
    fi

    check_user_vars
    user_create_account
    user_set_password
    user_setup_ssh
    user_add_to_groups
    user_configure_sudo
    user_generate_ssh_key
    user_install_bash_aliases

    chown -R "$USER_SSH:$USER_SSH" "$(get_home_dir)"
    log "OK" "User $USER_SSH fully configured."
}

# === Проверка переменных ===
check_user_vars() {
    [[ -z "$USER_SSH" || -z "$PASS_SSH" ]] && exit_error "Variables USER_SSH or PASS_SSH are not set."
}

# === Создание пользователя и домашней директории ===
user_create_account() {
    local home_dir="$(get_home_dir)"
    if id "$USER_SSH" &>/dev/null; then
        log "WARN" "User $USER_SSH already exists."
        ensure_directory_exists "$home_dir"
    else
        useradd -m -s /bin/bash "$USER_SSH" || exit_error "Failed to create user $USER_SSH."
        log "OK" "User $USER_SSH created."
    fi
}

# === Установка пароля ===
user_set_password() {
    echo "$USER_SSH:$PASS_SSH" | chpasswd || exit_error "Failed to set password for $USER_SSH."
    unset PASS_SSH
    log "DEBUG" "Password set for $USER_SSH."
}

# === Настройка SSH-директории и authorized_keys ===
user_setup_ssh() {
    local ssh_dir="$(get_home_dir)/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    ensure_directory_exists "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$USER_SSH:$USER_SSH" "$ssh_dir"

    ensure_file_exists "$auth_keys"
    chmod 600 "$auth_keys"
    chown "$USER_SSH:$USER_SSH" "$auth_keys"

    if [[ -n "$SSH_PBK" ]]; then
        echo "$SSH_PBK" >> "$auth_keys"
        sort -u "$auth_keys" -o "$auth_keys"
        log "DEBUG" "SSH public key added to authorized_keys."
    else
        log "WARN" "No SSH key provided for $USER_SSH."
    fi
}

# === Добавление в группы ===
user_add_to_groups() {
    local groups=("sudo" "docker")
    for group in "${groups[@]}"; do
        usermod -aG "$group" "$USER_SSH" 2>/dev/null || log "WARN" "Group $group not found, skipping."
    done
    log "DEBUG" "User $USER_SSH added to groups."
}

# === Настройка sudo-прав и логирования ===
user_configure_sudo() {
    local sudoers_file="/etc/sudoers.d/$USER_SSH"
    local sudo_log="$home_dir/sudo_${USER_SSH}.log"

    backup_file "$sudoers_file"
    {
        echo "$USER_SSH ALL=(ALL) NOPASSWD:ALL"
        echo "Defaults:$USER_SSH log_output"
        echo "Defaults:$USER_SSH logfile=\"$sudo_log\""
        echo "Defaults:$USER_SSH !tty_tickets"
        echo "Defaults:$USER_SSH !requiretty"
    } > "$sudoers_file"
    chmod 0440 "$sudoers_file"

    ensure_file_exists "$sudo_log"
    chmod 600 "$sudo_log"
    chown root:root "$sudo_log"
    log "DEBUG" "Sudo configuration complete for $USER_SSH."
}

# === Генерация SSH-ключа, если не существует ===
user_generate_ssh_key() {
    local ssh_key="$(get_home_dir)/.ssh/id_rsa"

    if [[ ! -f "$ssh_key" ]]; then
        ssh-keygen -t rsa -b 4096 -N "" -f "$ssh_key" -C "$USER_SSH" -q
        chown "$USER_SSH:$USER_SSH" "$ssh_key" "$ssh_key.pub"
        log "DEBUG" "SSH keypair generated for $USER_SSH."
    else
        log "INFO" "SSH key already exists for $USER_SSH."
    fi
}

# === Установка и подключение .bash_aliases ===
user_install_bash_aliases() {
    local alias_src="$TEMPLATE_DIR/.bash_aliases.template"
    local alias_dst="$(get_home_dir)/.bash_aliases"
    local bashrc="$(get_home_dir)/.bashrc"

    if [[ -f "$alias_src" ]]; then
        cp "$alias_src" "$alias_dst"
        chmod 644 "$alias_dst"
        chown "$USER_SSH:$USER_SSH" "$alias_dst"
        log "DEBUG" ".bash_aliases installed from template."
    else
        log "WARN" "Alias template not found: $alias_src"
    fi

    if [[ -f "$bashrc" && ! $(grep -F '.bash_aliases' "$bashrc") ]]; then
        echo -e '\n[ -f ~/.bash_aliases ] && . ~/.bash_aliases' >> "$bashrc"
        log "DEBUG" ".bash_aliases sourcing added to .bashrc"
    fi

}