#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ARCANE_PROBE_ENV:-/opt/script/install-state/install.env}"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE"; exit 2; }

# shellcheck disable=SC1090
set -a
# Read only the probe inputs without executing the env file.
while IFS= read -r line; do
	case "$line" in
	USER_WEB=*|PASS_WEB=*|URI_ARCANE=*|WEBDOMAIN=*)
		key=${line%%=*}
		val=${line#*=}
		val=${val%\"}
		val=${val#\"}
		printf -v "$key" '%s' "$val"
		export "$key"
		;;
	esac
done <"$ENV_FILE"
set +a

: "${WEBDOMAIN:?}" "${URI_ARCANE:?}" "${USER_WEB:?}" "${PASS_WEB:?}"
AUTH=(-u "${USER_WEB}:${PASS_WEB}")
BASE="https://${WEBDOMAIN}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

normalize_js_ref() {
	local base_path=$1 ref=$2 dir

	case "$ref" in
		/_app/*)
			printf '%s\n' "$ref"
			;;
		../*)
			dir=$(dirname "$base_path")
			while [[ "$ref" == ../* ]]; do
				dir=$(dirname "$dir")
				ref=${ref#../}
			done
			printf '%s/%s\n' "$dir" "$ref"
			;;
		./*)
			dir=$(dirname "$base_path")
			printf '%s/%s\n' "$dir" "${ref#./}"
			;;
		*)
			printf '/_app/immutable/chunks/%s\n' "$ref"
			;;
	esac
}

# 1) login HTML
html=$(curl -fsS "${AUTH[@]}" "${BASE}/${URI_ARCANE}/login")
echo "$html" | grep -q 'base: "/'"${URI_ARCANE}"'"' || fail "login HTML missing rewritten base"
echo "$html" | grep -qi 'Target Multi-purpose' && fail "login returned Caddy decoy" || true
pass "login HTML base ok"

# 2) pick a /_app chunk URL from HTML if present, else probe entry start via listing heuristic
html_js=$(echo "$html" | grep -oE '/_app/immutable/[^" ]+\.js' | sort -u || true)
chunk=$(echo "$html_js" | head -1 || true)
[[ -n "$chunk" ]] || fail "no /_app asset URL found in login HTML"
ctype=$(curl -fsS "${AUTH[@]}" -D - -o /dev/null "${BASE}${chunk}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2); exit}')
[[ "$ctype" == *javascript* ]] || fail "asset content-type not javascript: $ctype ($chunk)"
body=$(curl -fsS "${AUTH[@]}" "${BASE}${chunk}")
echo "$body" | grep -qi '<!DOCTYPE html>' && fail "JS URL returned HTML" || true
echo "$body" | grep -qE '\(\?=/\|\$\)' && fail "broken lookahead present in served JS" || true
# rewritten strip marker
echo "$body" | grep -q "var b=\"/${URI_ARCANE}\"" || echo "$body" | grep -q "location.replace(\`/${URI_ARCANE}/login" || pass "chunk may not be the rewritten one; checking any immutable chunk next"

# Prefer a large chunks/*.js that usually holds guards
if ! echo "$body" | grep -q "var b=\"/${URI_ARCANE}\""; then
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	seen="$tmpdir/seen"
	: >"$seen"

	found=0
	checked=0
	queue=()
	while read -r u; do
		[[ -n "$u" ]] || continue
		queue+=("$u")
	done <<<"$html_js"
	while read -r rel; do
		[[ -n "$rel" ]] || continue
		queue+=("$(normalize_js_ref "$chunk" "$rel")")
	done < <(echo "$body" | grep -oE '((\.\./|\./)?[A-Za-z0-9_./-]+\.js|/_app/immutable/[^"`'"'"' )]+\.js)' | head -80)

	while (( ${#queue[@]} > 0 && checked < 120 )); do
		u=${queue[0]}
		queue=("${queue[@]:1}")
		[[ -n "$u" ]] || continue
		grep -qxF "$u" "$seen" && continue
		printf '%s\n' "$u" >>"$seen"
		checked=$((checked + 1))
		b=$(curl -fsS "${AUTH[@]}" "${BASE}${u}" || true)
		if echo "$b" | grep -q "var b=\"/${URI_ARCANE}\""; then
			found=1
			echo "$b" | grep -qE '\(\?=/\|\$\)' && fail "broken lookahead in $u"
			break
		fi
		while read -r rel; do
			[[ -n "$rel" ]] || continue
			next=$(normalize_js_ref "$u" "$rel")
			grep -qxF "$next" "$seen" || queue+=("$next")
		done < <(echo "$b" | grep -oE '((\.\./|\./)?[A-Za-z0-9_./-]+\.js|/_app/immutable/[^"`'"'"' )]+\.js)' | head -80)
	done
	[[ "$found" -eq 1 ]] || fail "no served JS contained path-prefix strip for /${URI_ARCANE}"
fi
pass "JS rewrite strip present; no decoy"

# 3) Traefik file provider healthy
docker logs traefik --since 10m 2>&1 | grep -q 'collecting file configs:.*arcane.yml' && fail "traefik still errors on arcane.yml" || true
docker logs traefik --since 5m 2>&1 | grep -q 'middleware "arcane-js-body@file" does not exist' && fail "arcane-js-body missing" || true
pass "traefik arcane middlewares look loaded"

printf 'Live Arcane probe OK\n'
