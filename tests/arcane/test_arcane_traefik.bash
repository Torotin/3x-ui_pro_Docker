#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ARCANE_YML="$ROOT_DIR/docker-proxy/traefik/dynamic/arcane.yml"
COMPOSE_ARCANE="$ROOT_DIR/docker-proxy/compose.d/07-arcane.yml"
FIXTURE="$ROOT_DIR/tests/arcane/fixtures/sample-chunk.js"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

test_arcane_yml_comments_have_no_go_template_delimiters() {
	# Traefik templates the whole file; {{ }} in YAML comments break parsing. Values may use templates.
	local bad
	bad=$(
		python3 - "$ARCANE_YML" <<'PY' || true
import re
import sys

path = sys.argv[1]
bad = []
with open(path, encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, 1):
        stripped = line.rstrip("\n")
        if re.match(r"^\s*#", stripped):
            comment = stripped
        else:
            m = re.search(r"\s+#(.*)$", stripped)
            if not m:
                continue
            comment = m.group(1)
        if "{{" in comment or "}}" in comment:
            bad.append(f"{lineno}:{stripped}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
	)
	[[ -z "$bad" ]] || fail "Go-template delimiters in YAML comments:\n$bad"
	pass "arcane.yml comments have no {{ }}"
}

test_arcane_js_rewrite_regexes_match_fixture() {
	python3 - "$ARCANE_YML" "$FIXTURE" <<'PY'
import re
import sys

arcane_yml, fixture_path = sys.argv[1:3]
text = open(arcane_yml, encoding="utf-8").read()
fixture = open(fixture_path, encoding="utf-8").read()

m = re.search(
    r"(?ms)^\s*arcane-js-body:\s*$.*?(?=^\S|\Z)",
    text,
)
if not m:
    sys.exit("arcane-js-body section not found in arcane.yml")

section = m.group(0)
regexes = re.findall(r"^\s+- regex: '((?:[^']|'')*)'\s*$", section, re.M)
if len(regexes) != 4:
    sys.exit(f"expected 4 JS rewrite regexes under arcane-js-body, got {len(regexes)}")

failures = []
for i, raw in enumerate(regexes, 1):
    pattern = raw.replace("''", "'")
    try:
        hit = re.search(pattern, fixture)
    except re.error as exc:
        failures.append(f"regex #{i} invalid: {exc}\n  pattern={pattern!r}")
        continue
    if not hit:
        failures.append(f"regex #{i} does not match fixture\n  pattern={pattern!r}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
PY
	pass "arcane-js-body rewrite regexes match fixture"
}

test_arcane_yml_js_rewrites_are_semantic_not_minified_names() {
	grep -qE "var Q=\\\\?\(e,t\)" "$ARCANE_YML" && fail "JS rewrite still keys on minified var Q"
	grep -qE "function Ph\\\\?\(e,t,n,r" "$ARCANE_YML" && fail "JS rewrite still keys on minified function Ph"
	grep -qF 'location\.replace\(`/login\?redirect=' "$ARCANE_YML" || fail "missing location.replace login rewrite"
	grep -qF 'e\.startsWith\(`\$\{t\}/`\)' "$ARCANE_YML" || fail 'missing semantic startsWith(`${t}/`) guard matcher'
	grep -qF 'i=!1,a=`/dashboard`' "$ARCANE_YML" || fail "missing semantic dashboard-guard matcher"
	pass "JS rewrites are semantic"
}

test_arcane_yml_replacements_avoid_broken_js_regex_lookahead() {
	grep -nE '\(\?=/\|\$\)' "$ARCANE_YML" && fail "forbidden (?=/|$) lookahead present" || true
	grep -q 'e.slice(b.length)' "$ARCANE_YML" || fail "expected startsWith/slice style replacement"
	pass "no broken lookahead; slice strip present"
}

test_compose_pins_arcane_image_not_latest() {
	local img
	img=$(grep -E '^\s*image:' "$COMPOSE_ARCANE" | head -1)
	[[ "$img" == *':latest'* ]] && fail "image still uses :latest — $img"
	[[ "$img" == *'@sha256:'* || "$img" == *'manager:'* ]] || fail "unexpected image line: $img"
	[[ "$img" != *':latest'* ]] || fail "latest not allowed"
	# require digest pin explicitly
	[[ "$img" == *'@sha256:'* ]] || fail "image must be pinned by @sha256 digest"
	pass "compose pins Arcane by digest"
}

test_live_probe_uses_get_for_asset_headers() {
	grep -q -- '-fsSI' "$ROOT_DIR/tests/arcane/probe-live.sh" && fail "probe must not use HEAD for Arcane JS assets"
	grep -q -- '-D -' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe should capture headers from a GET request"
	pass "live probe checks asset headers with GET"
}

test_live_probe_crawls_relative_js_chunks() {
	grep -q 'normalize_js_ref' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe must normalize nested JS references"
	grep -q 'dirname "$base_path"' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe must resolve relative chunks from source path"
	grep -q 'html_js=' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe must seed crawl from all HTML JS assets"
	grep -q 'queue+=(' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe must process discovered chunks from an in-memory queue"
	grep -q 'checked < 120' "$ROOT_DIR/tests/arcane/probe-live.sh" || fail "probe must crawl beyond first-level chunks with a bound"
	pass "live probe crawls nested JS chunks"
}

test_fixture_contains_unstable_names_for_semantic_coverage() {
	grep -q 'function Xx(' "$FIXTURE" || fail "fixture must use non-Ph name Xx"
	grep -q 'var Guard=' "$FIXTURE" || fail "fixture must use non-Q name Guard"
	grep -q 'location.replace(`/login?redirect=' "$FIXTURE" || fail "fixture missing login replace"
	pass "fixture ready"
}

main() {
	test_fixture_contains_unstable_names_for_semantic_coverage
	test_arcane_yml_comments_have_no_go_template_delimiters
	test_arcane_js_rewrite_regexes_match_fixture
	test_arcane_yml_js_rewrites_are_semantic_not_minified_names
	test_arcane_yml_replacements_avoid_broken_js_regex_lookahead
	test_compose_pins_arcane_image_not_latest
	test_live_probe_uses_get_for_asset_headers
	test_live_probe_crawls_relative_js_chunks
	printf 'All arcane traefik tests passed\n'
}

main "$@"
