#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SKILL_ROOT="$ROOT_DIR/.agents/skill"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

REQUIRED_SKILLS=(
  3x-ui-pro-docker
  installer
  compose-stack
  traefik
  3x-ui
  lampac
  crowdsec
  adguard
  arcane
  homepage
  mihomo
  telemt
  proxy-backends
  logrotate
  caddy
)

test_shared_conventions_exist() {
  [[ -f "$SKILL_ROOT/_shared/project-conventions.md" ]] || fail "_shared/project-conventions.md missing"
  grep -q 'skill-maintenance' "$SKILL_ROOT/_shared/project-conventions.md" \
    || grep -qi 'update the matching skill' "$SKILL_ROOT/_shared/project-conventions.md" \
    || fail "_shared missing skill-maintenance contract"
  pass "shared conventions present"
}

test_each_skill_has_frontmatter() {
  local name path
  for name in "${REQUIRED_SKILLS[@]}"; do
    path="$SKILL_ROOT/$name/SKILL.md"
    [[ -f "$path" ]] || fail "missing $path"
    grep -q '^name:' "$path" || fail "$path missing name:"
    grep -q '^description:' "$path" || fail "$path missing description:"
    if grep -q 'disable-model-invocation:' "$path"; then
      fail "$path must omit disable-model-invocation"
    fi
  done
  pass "all skills have required frontmatter"
}

test_router_lists_all_skills() {
  local router="$SKILL_ROOT/3x-ui-pro-docker/SKILL.md" name
  [[ -f "$router" ]] || fail "router missing"
  for name in "${REQUIRED_SKILLS[@]}"; do
    [[ "$name" == "3x-ui-pro-docker" ]] && continue
    grep -q "$name" "$router" || fail "router does not mention $name"
  done
  pass "router mentions all service skills"
}

test_no_active_legacy_inventory() {
  # Skills may mention remnants only as do-not-revive / out of scope.
  local f
  while IFS= read -r f; do
    if grep -nE 'warp|dockcheck|torproxy|sub-json-processor|caddy/subs' "$f" >/dev/null 2>&1; then
      grep -nE 'warp|dockcheck|torproxy|sub-json-processor|caddy/subs' "$f" \
        | grep -viE 'do-not-revive|out of scope|remnant|not used|disabled|removed|do not' \
        | grep -viE '/xray/warp|xui_warp_|warp=on' \
        && fail "active legacy inventory wording in $f"
    fi
  done < <(find "$SKILL_ROOT" -name 'SKILL.md' -o -name '*.md')
  pass "no active legacy inventory"
}

test_skill_links_stay_in_agents_or_repo() {
  local f
  while IFS= read -r f; do
    if grep -nE '~/.cursor/skills|%USERPROFILE%\\\\.cursor\\\\skills|C:/Users/.*/\.cursor/skills' "$f" >/dev/null 2>&1; then
      # Allow a single historical note only inside router rollout section is NOT allowed —
      # project skills must not require global paths.
      fail "skill references personal global skill path: $f"
    fi
  done < <(find "$SKILL_ROOT" -type f -name '*.md')
  pass "no personal global skill path requirements"
}

test_official_documentation_section() {
  local name path
  for name in "${REQUIRED_SKILLS[@]}"; do
    path="$SKILL_ROOT/$name/SKILL.md"
    [[ -f "$path" ]] || fail "missing $path"
    grep -q '^## Official documentation$' "$path" \
      || fail "$path missing exact heading: ## Official documentation"
  done
  pass "all skills have Official documentation section"
}

main() {
  [[ -d "$SKILL_ROOT" ]] || fail ".agents/skill missing"
  test_shared_conventions_exist
  test_each_skill_has_frontmatter
  test_router_lists_all_skills
  test_no_active_legacy_inventory
  test_skill_links_stay_in_agents_or_repo
  test_official_documentation_section
  printf 'All agents-skills checks passed\n'
}

main "$@"
