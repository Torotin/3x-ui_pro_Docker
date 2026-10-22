#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
INSTALLER="$ROOT_DIR/script/install.sh"
INSTALLER_VERSION=$(sed -n '1{s/[[:space:]]//g;p;q;}' "$ROOT_DIR/script/VERSION")
INSTALLER_NEWER_VERSION=$(
	IFS=. read -r major minor patch <<<"$INSTALLER_VERSION"
	printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
)
# shellcheck source=/dev/null
source <(awk 'NR >= 13 { if ($0 ~ /^test_[a-z_0-9]+$/) exit; print }' "$ROOT_DIR/tests/install-scripts/test_installer_cli.bash")
test_env_writes_host_ip_mode_dual
test_env_ipv4_only_does_not_copy_v4_into_v6
test_env_detects_public_ips_when_missing
test_ip_probe_clears_stale_ipv6_when_unreachable
printf 'focused env ip tests: OK\n'
