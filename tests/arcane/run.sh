#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

syntax_check_files=(
	tests/arcane/run.sh
	tests/arcane/test_arcane_traefik.bash
	tests/arcane/probe-live.sh
)

for f in "${syntax_check_files[@]}"; do
	[[ -f "$f" ]] || continue
	bash -n "$f"
done

bash tests/arcane/test_arcane_traefik.bash
