#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bash -n "$ROOT_DIR/tests/agents-skills/test_skill_tree.bash"
bash "$ROOT_DIR/tests/agents-skills/test_skill_tree.bash"
