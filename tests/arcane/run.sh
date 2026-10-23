#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

bash -n tests/arcane/run.sh tests/arcane/test_arcane_traefik.bash tests/arcane/probe-live.sh
bash tests/arcane/test_arcane_traefik.bash
