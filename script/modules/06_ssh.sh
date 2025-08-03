#!/bin/bash
# lib/05_ssh.sh — SSH service configuration and access policy

# === Global variables ===
USER_SSH=${USER_SSH:-}
PORT_REMOTE_SSH=${PORT_REMOTE_SSH:-}
TEMPLATE_DIR=${TEMPLATE_DIR:-}
SSH_PBK=${SSH_PBK:-}

# === Main entry point (call this from your installer) ===
sshd_config() {
  log "INFO" "Starting SSH configuration for user $USER_SSH on port $PORT_REMOTE_SSH"

  local ssh_config="/etc/ssh/sshd_config"
  sshd_validate_input
  backup_file "$ssh_config"

  sshd_define_auth_method

  log "INFO" "Generating new sshd_config from template"
  export USER_SSH PORT_REMOTE_SSH pubkey_auth PASS_SSH_auth
  envsubst < "$TEMPLATE_DIR/sshd_config.template" > "$ssh_config" \
    || exit_error "Failed to generate sshd_config"

  sshd_detect_service
  ssh_validate_config "$ssh_config"
  ssh_restart_service "$ssh_config"
}

# === Validate required variables and files ===
sshd_validate_input() {
  if [[ -z "$USER_SSH" || -z "$PORT_REMOTE_SSH" ]]; then
    exit_error "Both USER_SSH and PORT_REMOTE_SSH must be provided"
  fi

  for f in /etc/ssh/sshd_config "$TEMPLATE_DIR/sshd_config.template"; do
    [[ -f $f ]] || exit_error "File not found: $f"
  done
}

# === Choose authentication method ===
sshd_define_auth_method() {
  if [[ -n "$SSH_PBK" ]]; then
    PASS_SSH_auth=no;   pubkey_auth=yes
    msg_pubkey_auth="Public-key authentication"
  else
    PASS_SSH_auth=yes;  pubkey_auth=no
    msg_pubkey_auth="Password authentication"
  fi
  export msg_pubkey_auth PASS_SSH_auth pubkey_auth
  log "DEBUG" "$msg_pubkey_auth selected"
}

# === Detect which ssh* unit to manage ===
detect_ssh_unit() {
  systemctl list-unit-files --no-legend \
    | awk '/^(ssh|sshd)\.(service|socket)/{print $1; exit}'
}

sshd_detect_service() {
  SSH_SERVICE_NAME=$(detect_ssh_unit)
  [[ -n "$SSH_SERVICE_NAME" ]] || exit_error "SSH service unit not found"
  if [[ ${SSH_SERVICE_NAME##*.} == socket ]]; then
    sudo install -d -m755 -o root -g root /run/sshd
  fi
  log "DEBUG" "Detected service: $SSH_SERVICE_NAME"
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

# === Restart & verify the SSH service ===
ssh_restart_service() {
  local cfg=$1
  if ! systemctl restart "$SSH_SERVICE_NAME"; then
    restore_backup_file "$cfg"
    exit_error "Failed to restart $SSH_SERVICE_NAME; restored backup"
  fi

  if ! systemctl is-active --quiet "$SSH_SERVICE_NAME"; then
    restore_backup_file "$cfg"
    exit_error "$SSH_SERVICE_NAME is not active; restored backup"
  fi

  log "OK" "$SSH_SERVICE_NAME is running"
}