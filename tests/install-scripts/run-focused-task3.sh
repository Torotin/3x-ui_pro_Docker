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
	test_dnscrypt_detect_connectivity_uses_shared_probe_in_mock
	test_dnscrypt_mock_install_logs_intent_without_host_mutation
)
for t in "${tests[@]}"; do
	"$t"
done
printf 'focused task3 tests: OK\n'
