#!/usr/bin/env sh
set -eu

# Configuration inside containers
CONF_PATH="${ADGUARD_CONF:-/opt/adguardhome/conf/AdGuardHome.yaml}"
# Prefer USER_WEB/PASS_WEB, fallback to ADGUARD_* vars
USER_NAME="${USER_WEB:-${ADGUARD_ADMIN_USER:-admin}}"
USER_PASS="${PASS_WEB:-${ADGUARD_ADMIN_PASS:-}}"
USER_HASH="${ADGUARD_ADMIN_HASH:-}"
BCRYPT_COST="${ADGUARD_BCRYPT_COST:-10}"

log() { printf "[adguard-passwd] %s\n" "$*"; }

if [ -z "${USER_PASS}" ] && [ -z "${USER_HASH}" ]; then
  log "USER_WEB/PASS_WEB not set and no ADGUARD_ADMIN_HASH; skipping."
  exit 0
fi

# Ensure tools are present (htpasswd only needed if we hash from plaintext)
if [ -z "${USER_HASH}" ]; then
  if ! command -v htpasswd >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
      log "Installing apache2-utils (htpasswd)..."
      apk add --no-cache apache2-utils >/dev/null 2>&1 || {
        log "Failed to install apache2-utils"; exit 1; }
    fi
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    log "htpasswd not found and cannot be installed; aborting."
    exit 1
  fi
fi

if ! command -v yq >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    log "Installing yq..."
    apk add --no-cache yq >/dev/null 2>&1 || {
      log "Failed to install yq via apk"; exit 1; }
  else
    log "yq not found and apk unavailable; cannot safely edit YAML."
    exit 1
  fi
fi

if [ ! -f "$CONF_PATH" ]; then
  log "Config not found at $CONF_PATH; nothing to update (first run?)."
  exit 0
fi

# Generate or accept provided bcrypt hash
if [ -n "$USER_HASH" ]; then
  HASH="$USER_HASH"
else
  HASH=$(htpasswd -B -C "$BCRYPT_COST" -n -b "$USER_NAME" "$USER_PASS" | awk -F: '{print $2}')
  if [ -z "$HASH" ]; then
    log "Failed to generate bcrypt hash."
    exit 1
  fi
fi

log "Updating user entry in config..."

# Ensure .users exists and replace or add the user with new hash
# Export variables so yq strenv() can read them
export USER_NAME HASH
yq -i \
  ' .users = ((.users // [])
    | map(select((.name != strenv(USER_NAME)) and (.name != null) and (.name != "")))
    + [{"name": strenv(USER_NAME), "password": strenv(HASH)}]) ' \
  "$CONF_PATH"

log "Password hash updated for user $USER_NAME."

exit 0
