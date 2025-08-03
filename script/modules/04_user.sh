#!/bin/bash
# lib/04_user.sh — User management module

# === Global variables ===
TEMPLATE_DIR=${TEMPLATE_DIR:-}
PROJECT_ROOT=${PROJECT_ROOT:-}
USER_SSH=${USER_SSH:-}
PASS_SSH=${PASS_SSH:-}
SSH_PBK=${SSH_PBK:-}   # optional

# === Helper functions ===

# ensure_directory: create directory with specified mode and chown to USER_SSH
ensure_directory() {
    local mode=$1
    local dir=$2
    mkdir -p "$dir"
    chmod "$mode" "$dir"
    chown "$USER_SSH:$USER_SSH" "$dir" || true
}

# ensure_file: create empty file if missing, set mode and chown to USER_SSH
ensure_file() {
    local mode=$1
    local file=$2
    [[ -e "$file" ]] || touch "$file"
    chmod "$mode" "$file"
    chown "$USER_SSH:$USER_SSH" "$file" || true
}

# detect_home_dir: get the user's home directory via getent or fallback to /home/USER_SSH
detect_home_dir() {
    local hd
    if hd=$(getent passwd "$USER_SSH" 2>/dev/null | cut -d: -f6) && [[ -n "$hd" ]]; then
        echo "$hd"
    else
        echo "/home/$USER_SSH"
    fi
}

# check_user_vars: ensure USER_SSH and PASS_SSH are provided
check_user_vars() {
    if [[ -z "$USER_SSH" || -z "$PASS_SSH" ]]; then
        exit_error "Both USER_SSH and PASS_SSH must be provided."
    fi
}

# === Module functions ===

# user_create_account: create the system user if it does not exist
user_create_account() {
    log "INFO" "Creating account for user $USER_SSH"
    if id "$USER_SSH" &>/dev/null; then
        log "WARN" "User $USER_SSH already exists, skipping creation."
        ensure_directory 700 "$HOME_DIR"
    else
        useradd -m -d "$HOME_DIR" -s /bin/bash "$USER_SSH" \
            || exit_error "Failed to create user $USER_SSH."
        log "OK" "User account $USER_SSH created."
    fi
}

# user_set_password: set the user's password and unset PASS_SSH
user_set_password() {
    echo "${USER_SSH}:${PASS_SSH}" | chpasswd \
        || exit_error "Failed to set password for $USER_SSH."
    unset PASS_SSH
    log "DEBUG" "Password set for $USER_SSH."
}

# user_generate_ssh_key: generate ED25519 keypair if missing
user_generate_ssh_key() {
    log "INFO" "Ensuring ED25519 keypair for $USER_SSH"
    local ed_key="$HOME_DIR/.ssh/id_ed25519"

    # prepare .ssh directory
    ensure_directory 700 "$HOME_DIR/.ssh"

    # generate ED25519 keypair
    if [[ ! -f "$ed_key" ]]; then
        ssh-keygen -t ed25519 -N "" -f "$ed_key" -C "$USER_SSH" -q \
            || exit_error "Failed to generate ED25519 key"
        chown "$USER_SSH:$USER_SSH" "$ed_key"{,.pub}
        log "DEBUG" "ED25519 keypair generated"
    else
        log "INFO" "ED25519 keypair already exists"
    fi
}

# user_setup_ssh: populate authorized_keys with provided and generated ED25519 key
user_setup_ssh() {
    log "INFO" "Setting up authorized_keys for $USER_SSH"
    local ssh_dir="$HOME_DIR/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    ensure_directory 700 "$ssh_dir"
    ensure_file      600 "$auth_keys"

    # collect keys: optional SSH_PBK, then generated ED25519 public key
    declare -a pub_keys=()
    if [[ -n "$SSH_PBK" ]]; then
        pub_keys+=( "$SSH_PBK" )
    fi
    pub_keys+=( "$(cat "$ssh_dir/id_ed25519.pub")" )

    # append each key if not already present
    for key in "${pub_keys[@]}"; do
        grep -qxF "$key" "$auth_keys" || echo "$key" >> "$auth_keys"
    done

    # remove duplicates just in case
    sort -u "$auth_keys" -o "$auth_keys"
    log "DEBUG" "authorized_keys populated with ED25519 key(s)"
}

# user_add_to_groups: add the user to default groups (sudo, docker)
user_add_to_groups() {
    log "INFO" "Adding $USER_SSH to default groups"
    local groups=(sudo docker)
    for g in "${groups[@]}"; do
        if getent group "$g" &>/dev/null; then
            usermod -aG "$g" "$USER_SSH" \
                && log "DEBUG" "Added $USER_SSH to group $g"
        else
            log "DEBUG" "Group $g not found, skipping"
        fi
    done
}

# user_configure_sudo: create sudoers entry with NOPASSWD and logging
user_configure_sudo() {
    log "INFO" "Configuring sudoers for $USER_SSH"
    local sudoers_file="/etc/sudoers.d/$USER_SSH"
    local sudo_log="$HOME_DIR/sudo_${USER_SSH}.log"

    backup_file "$sudoers_file"
    umask 0277
    cat > "$sudoers_file" <<EOF
$USER_SSH ALL=(ALL) NOPASSWD:ALL
Defaults:$USER_SSH log_output
Defaults:$USER_SSH logfile="$sudo_log"
Defaults:$USER_SSH !tty_tickets
Defaults:$USER_SSH !requiretty
EOF
    chmod 0440 "$sudoers_file"

    # ensure sudo log exists under root ownership
    [[ -e "$sudo_log" ]] || touch "$sudo_log"
    chmod 600 "$sudo_log"
    chown root:root "$sudo_log"
    log "DEBUG" "Sudo configuration completed for $USER_SSH."
}

# user_install_bash_aliases: copy .bash_aliases template and enable sourcing
user_install_bash_aliases() {
    log "INFO" "Installing bash aliases for $USER_SSH"
    local src="$TEMPLATE_DIR/.bash_aliases.template"
    local dst="$HOME_DIR/.bash_aliases"
    local bashrc="$HOME_DIR/.bashrc"

    if [[ -f "$src" ]]; then
        cp "$src" "$dst"
        chmod 644 "$dst"
        chown "$USER_SSH:$USER_SSH" "$dst"
        if ! grep -qxF '[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases' "$bashrc"; then
            echo '[[ -f ~/.bash_aliases ]] && . ~/.bash_aliases' >> "$bashrc"
            log "DEBUG" ".bash_aliases sourcing added to .bashrc"
        fi
        log "DEBUG" ".bash_aliases installed from template"
    else
        log "WARN" "Alias template not found at: $src"
    fi
}

# user_create: orchestrate the full user setup (not invoked automatically)
user_create() {
    check_user_vars
    log "INFO" "Starting full user setup for user $USER_SSH"

    if [[ "$USER_SSH" == "root" ]]; then
        log "WARN" "Skipping setup for root user"
        return
    fi

    HOME_DIR=$(detect_home_dir)

    user_create_account
    user_set_password
    user_generate_ssh_key
    user_setup_ssh
    user_add_to_groups
    user_configure_sudo
    user_install_bash_aliases

    chown -R "$USER_SSH:$USER_SSH" "$HOME_DIR"
    log "OK" "User $USER_SSH has been fully configured."
}
