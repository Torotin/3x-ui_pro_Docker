#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

mapfile -t shell_files < <(
	find script -type f \( -name '*.sh' -o -name '*.bash' \) | sort
)

# ASCII hygiene: reject NBSP (U+00A0) and CRLF in installer shell sources.
hygiene_fail=0
while IFS= read -r -d '' f; do
	if grep -q $'\xC2\xA0' "$f"; then
		printf 'FAIL: non-breaking space (U+00A0) in %s\n' "$f" >&2
		hygiene_fail=1
	fi
	if grep -q $'\r' "$f"; then
		printf 'FAIL: CRLF line ending in %s\n' "$f" >&2
		hygiene_fail=1
	fi
done < <(find script tests/install-scripts -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
((hygiene_fail == 0)) || exit 1

bash tests/install-scripts/test_installer_cli.bash

bash -n "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh
shellcheck -x -S warning "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh

if command -v shfmt >/dev/null 2>&1; then
	shfmt -d "${shell_files[@]}" tests/install-scripts/*.bash tests/install-scripts/run.sh
else
	printf 'shfmt not installed; skipping format diff\n'
fi
