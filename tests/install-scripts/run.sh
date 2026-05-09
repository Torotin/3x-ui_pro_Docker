#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

bash tests/install-scripts/test_installer_cli.bash

mapfile -t shell_files < <(
	find script -type f -name '*.sh' | sort
)

bash -n "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh
shellcheck -x -S warning "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh

if command -v shfmt >/dev/null 2>&1; then
	shfmt -d "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh
else
	printf 'shfmt not installed; skipping format diff\n'
fi
