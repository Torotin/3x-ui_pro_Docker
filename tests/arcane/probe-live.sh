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

# 1) login HTML
html=$(curl -fsS "${AUTH[@]}" "${BASE}/${URI_ARCANE}/login")
echo "$html" | grep -q 'base: "/'"${URI_ARCANE}"'"' || fail "login HTML missing rewritten base"
echo "$html" | grep -qi 'Target Multi-purpose' && fail "login returned Caddy decoy" || true
pass "login HTML base ok"

# 2) pick a /_app chunk URL from HTML if present, else probe entry start via listing heuristic
chunk=$(echo "$html" | grep -oE '/_app/immutable/[^" ]+\.js' | head -1 || true)
[[ -n "$chunk" ]] || fail "no /_app asset URL found in login HTML"
ctype=$(curl -fsSI "${AUTH[@]}" "${BASE}${chunk}" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print tolower($2); exit}')
[[ "$ctype" == *javascript* ]] || fail "asset content-type not javascript: $ctype ($chunk)"
body=$(curl -fsS "${AUTH[@]}" "${BASE}${chunk}")
echo "$body" | grep -qi '<!DOCTYPE html>' && fail "JS URL returned HTML" || true
echo "$body" | grep -qE '\(\?=/\|\$\)' && fail "broken lookahead present in served JS" || true
# rewritten strip marker
echo "$body" | grep -q "var b=\"/${URI_ARCANE}\"" || echo "$body" | grep -q "location.replace(\`/${URI_ARCANE}/login" || pass "chunk may not be the rewritten one; checking any immutable chunk next"

# Prefer a large chunks/*.js that usually holds guards
if ! echo "$body" | grep -q "var b=\"/${URI_ARCANE}\""; then
	# Download a few chunk URLs referenced by the first file.
	found=0
	while read -r rel; do
		[[ -z "$rel" ]] && continue
		u="$rel"
		[[ "$u" == ./* ]] && u="/_app/immutable/chunks/${u#./}"
		[[ "$u" == /* ]] || u="/_app/immutable/chunks/$u"
		b=$(curl -fsS "${AUTH[@]}" "${BASE}${u}" || true)
		if echo "$b" | grep -q "var b=\"/${URI_ARCANE}\""; then
			found=1
			echo "$b" | grep -qE '\(\?=/\|\$\)' && fail "broken lookahead in $u"
			break
		fi
	done < <(echo "$body" | grep -oE '\./[A-Za-z0-9_./-]+\.js' | head -20)
	[[ "$found" -eq 1 ]] || fail "no served JS contained path-prefix strip for /${URI_ARCANE}"
fi
pass "JS rewrite strip present; no decoy"

# 3) Traefik file provider healthy
docker logs traefik --since 10m 2>&1 | grep -q 'collecting file configs:.*arcane.yml' && fail "traefik still errors on arcane.yml" || true
docker logs traefik --since 5m 2>&1 | grep -q 'middleware "arcane-js-body@file" does not exist' && fail "arcane-js-body missing" || true
pass "traefik arcane middlewares look loaded"

printf 'Live Arcane probe OK\n'
