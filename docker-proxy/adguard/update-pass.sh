#!/bin/bash
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

if [ -z "${USER_HASH}" ] && [ -n "${HT_PASS_ENCODED:-}" ]; then
  USER_HASH="${HT_PASS_ENCODED#*:}"
  USER_HASH="$(printf '%s' "$USER_HASH" | sed 's/\$\$/\$/g')"
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

tmp_conf="${CONF_PATH}.tmp.$$"
awk -v user="$USER_NAME" -v hash="$HASH" '
  function print_users() {
    print "users:"
    print "  - name: \"" user "\""
    print "    password: \"" hash "\""
  }
  /^users:/ && !done {
    print_users()
    in_users = 1
    done = 1
    next
  }
  in_users && /^[^[:space:]#][^:]*:/ {
    in_users = 0
  }
  in_users {
    next
  }
  {
    print
  }
  END {
    if (!done) {
      print_users()
    }
  }
' "$CONF_PATH" >"$tmp_conf"
mv "$tmp_conf" "$CONF_PATH"

log "Password hash updated for user $USER_NAME."

exit 0
