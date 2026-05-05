#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

bash tests/3x-ui-scripts/test_libs.bash

mapfile -t shell_files < <(
	find docker-proxy/3x-ui/scripts -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.mod' \) | sort
)

bash -n "${shell_files[@]}"
shellcheck -x -S warning "${shell_files[@]}" tests/3x-ui-scripts/*.bash tests/3x-ui-scripts/run.sh

if command -v shfmt >/dev/null 2>&1; then
	shfmt -d "${shell_files[@]}" tests/3x-ui-scripts/*.bash tests/3x-ui-scripts/run.sh
else
	printf 'shfmt not installed; skipping format diff\n'
fi
