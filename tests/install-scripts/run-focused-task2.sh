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
tests=(
	test_env_writes_host_ip_mode_dual
	test_env_ipv4_only_does_not_copy_v4_into_v6
	test_env_detects_public_ips_when_missing
	test_ip_probe_sets_dual_mode_in_mock
	test_ip_probe_ipv4_only_leaves_ipv6_empty
	test_env_preserves_existing_state_defaults
	test_final_summary_mentions_host_dnscrypt
	test_final_summary_prints_details
)
for t in "${tests[@]}"; do
	"$t"
done
printf 'focused task2 tests: OK\n'
