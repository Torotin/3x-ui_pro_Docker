#!/bin/bash
# lib/05_ssh.sh — SSH service configuration and access policy

# === Global variables ===
USER_SSH=${USER_SSH:-}
PORT_REMOTE_SSH=${PORT_REMOTE_SSH:-}
TEMPLATE_DIR=${TEMPLATE_DIR:-}
SSH_PBK=${SSH_PBK:-}

# === Main entry point (invoke from installer) ===
sshd_config() {
    log "INFO" "Starting SSH configuration"
    log "DEBUG" "Parameters: USER_SSH=$USER_SSH, PORT_REMOTE_SSH=$PORT_REMOTE_SSH, TEMPLATE_DIR=$TEMPLATE_DIR, SSH_PBK=${SSH_PBK:+<present>}"

    local ssh_config="/etc/ssh/sshd_config"

    # validate inputs
    log "INFO" "Validating input parameters and files"
    sshd_validate_input
    log "DEBUG" "Input validation passed"

    # backup existing config
    log "INFO" "Backing up existing sshd_config"
    backup_file "$ssh_config"
    log "DEBUG" "Backup completed for $ssh_config"

    # choose auth method
    log "INFO" "Determining authentication method"
    sshd_define_auth_method
    log "DEBUG" "Authentication method: $msg_pubkey_auth"

    # generate new config
    log "INFO" "Generating new sshd_config from template"
    log "DEBUG" "Using template $TEMPLATE_DIR/sshd_config.template"
    export USER_SSH PORT_REMOTE_SSH pubkey_auth PASS_SSH_auth
    if envsubst < "$TEMPLATE_DIR/sshd_config.template" > "$ssh_config"; then
        log "OK" "Rendered sshd_config to $ssh_config"
    else
        exit_error "Failed to render sshd_config"
    fi

    # detect and prepare service
    log "INFO" "Detecting SSH service unit"
    sshd_detect_service
    log "DEBUG" "Service unit prepared: $SSH_SERVICE_NAME"

    # syntax check
    log "INFO" "Validating sshd_config syntax"
    ssh_validate_config "$ssh_config"
    log "DEBUG" "sshd_config syntax is correct"

    # restart service
    log "INFO" "Restarting SSH service $SSH_SERVICE_NAME"
    ssh_restart_service "$ssh_config"
    log "OK" "SSH configuration completed successfully"
}

# === Validate required variables and files ===
sshd_validate_input() {
    if [[ -z "$USER_SSH" || -z "$PORT_REMOTE_SSH" ]]; then
        exit_error "Both USER_SSH and PORT_REMOTE_SSH must be provided"
    fi

    for f in /etc/ssh/sshd_config "$TEMPLATE_DIR/sshd_config.template"; do
        if [[ ! -f $f ]]; then
            exit_error "Required file not found: $f"
        else
            log "DEBUG" "Found file: $f"
        fi
    done
}

# === Choose authentication method ===
sshd_define_auth_method() {
    if [[ -n "$SSH_PBK" ]]; then
        PASS_SSH_auth=no; pubkey_auth=yes
        msg_pubkey_auth="Public-key authentication"
    else
        PASS_SSH_auth=yes; pubkey_auth=no
        msg_pubkey_auth="Password authentication"
    fi
    export msg_pubkey_auth PASS_SSH_auth pubkey_auth
}

# === Detect which systemd unit manages SSH ===
detect_ssh_unit() {
    systemctl list-unit-files --no-legend \
        | awk '/^(ssh|sshd)\.(service|socket)/{print $1; exit}'
}

# === Prepare SSH service and required directories ===
sshd_detect_service() {
    SSH_SERVICE_NAME=$(detect_ssh_unit)
    [[ -n "$SSH_SERVICE_NAME" ]] || exit_error "SSH service unit not found"
    log "DEBUG" "Detected unit: $SSH_SERVICE_NAME"

    # Ensure privilege separation directory exists
    if [[ ! -d /run/sshd ]]; then
        log "INFO" "Creating /run/sshd for privilege separation"
        sudo mkdir -p /run/sshd
        sudo chown root:root /run/sshd
        sudo chmod 755 /run/sshd
        log "DEBUG" "/run/sshd created"
    else
        log "DEBUG" "/run/sshd already exists"
    fi
}

# === Validate sshd_config syntax ===
ssh_validate_config() {
    local cfg=$1
    if ! sshd -t -f "$cfg"; then
        log "ERROR" "sshd_config syntax invalid:"
        sshd -t -f "$cfg" 2>&1 | while read -r line; do
            log "ERROR" "$line"
        done
        exit 1
    fi
}

# === Restart and verify SSH service ===
ssh_restart_service() {
    local cfg=$1

    log "DEBUG" "Executing: systemctl restart $SSH_SERVICE_NAME"
    if ! systemctl restart "$SSH_SERVICE_NAME"; then
        log "ERROR" "Restart command failed"
        restore_backup_file "$cfg"
        exit_error "Failed to restart $SSH_SERVICE_NAME; restored backup"
    fi
    log "DEBUG" "Restart command succeeded"

    log "DEBUG" "Checking if $SSH_SERVICE_NAME is active"
    if ! systemctl is-active --quiet "$SSH_SERVICE_NAME"; then
        log "ERROR" "Service $SSH_SERVICE_NAME is not active"
        restore_backup_file "$cfg"
        exit_error "$SSH_SERVICE_NAME failed to start; restored backup"
    fi
    log "OK" "$SSH_SERVICE_NAME is running"
}