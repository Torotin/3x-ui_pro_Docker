#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE="$ROOT_DIR/docker-proxy/compose.d"
TRAEFIK_YML="$ROOT_DIR/docker-proxy/traefik/traefik.yml"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

test_admin_entrypoint_exists() {
  grep -qE '^[[:space:]]*admin:' "$TRAEFIK_YML" || fail "entrypoint admin missing in traefik.yml"
  grep -qE 'address:[[:space:]]*":9443"' "$TRAEFIK_YML" \
    || grep -qE "address:[[:space:]]*':9443'" "$TRAEFIK_YML" \
    || fail "admin entrypoint must listen on :9443"
  pass "admin entrypoint present on :9443"
}

test_no_public_admin_entrypoints() {
  local patterns=(
    'routers.arcane-ui.entrypoints=websecure'
    'routers.homepage-router.entrypoints=websecure'
    'routers.adguard-panel.entrypoints=websecure'
    'routers.3xui-panel.entrypoints=websecure'
    'routers.traefik-dashboard-prefixed.entrypoints=websecure'
    'routers.lampac-sensitive.entrypoints=websecure'
  )
  local p
  for p in "${patterns[@]}"; do
    if grep -R -n --fixed-strings "$p" "$COMPOSE"/*.yml >/dev/null 2>&1; then
      fail "public admin still on websecure: $p"
    fi
  done
  pass "listed admin routers not on websecure"
}

test_subscription_and_doh_remain_public() {
  grep -n 'routers.3xui-sub.entrypoints=websecure' "$COMPOSE/12-3x-ui.yml" >/dev/null \
    || fail "3xui-sub must stay on websecure"
  grep -n 'routers.adguard-doh.entrypoints=websecure' "$COMPOSE/10-adguard.yml" >/dev/null \
    || fail "adguard-doh must stay on websecure"
  pass "sub + DoH remain public"
}

test_no_tailscale_compose() {
  if ls "$COMPOSE"/17-tailscale.yml >/dev/null 2>&1; then
    fail "17-tailscale.yml must not exist"
  fi
  if grep -R -n -i 'tailscale' "$COMPOSE"/*.yml >/dev/null 2>&1; then
    fail "compose.d must not reference tailscale"
  fi
  pass "no Tailscale compose"
}

test_admin_entrypoint_exists
test_no_public_admin_entrypoints
test_subscription_and_doh_remain_public
test_no_tailscale_compose
