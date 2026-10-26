#!/usr/bin/env bash
# WSL smoke: fetch JSON subscription and validate routing + optional xray run -test.
set -Eeuo pipefail

WEBDOMAIN="${WEBDOMAIN:-streambase.linkpc.net}"
JSON_PATH="${JSON_PATH:-/Kr3AbtowEqom/}"
SUB_ID="${SUB_ID:-}"
JSON_SUB_URL="${JSON_SUB_URL:-}"
BODY="${BODY:-/tmp/wsl-json-smoke.json}"
CFG="${CFG:-/tmp/wsl-xray-smoke-config.json}"
SKIP_RUNTIME="${SKIP_RUNTIME:-0}"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

# Panel occasionally returns transient 500 on subscription endpoints.
fetch_url() {
	local url=$1 out=$2 attempt code
	for attempt in 1 2 3 4 5; do
		code=$(curl -sS -o "$out" -w "%{http_code}" --max-time 60 "$url" || true)
		if [[ "$code" == "200" ]]; then
			return 0
		fi
		echo "WARN: fetch attempt $attempt → HTTP ${code:-err}; retrying…" >&2
		sleep "$attempt"
	done
	die "curl fetch failed after retries: $url (last HTTP ${code:-err})"
}

resolve_url() {
	if [[ -n "$JSON_SUB_URL" ]]; then
		printf '%s\n' "$JSON_SUB_URL"
		return 0
	fi
	[[ -n "$SUB_ID" ]] || die "set JSON_SUB_URL or SUB_ID"
	case "$JSON_PATH" in
		/*) ;;
		*) JSON_PATH="/$JSON_PATH" ;;
	esac
	printf 'https://%s%s%s\n' "$WEBDOMAIN" "$JSON_PATH" "$SUB_ID"
}

find_xray() {
	local bin
	for bin in xray xray-core; do
		if command -v "$bin" >/dev/null 2>&1; then
			printf '%s\n' "$bin"
			return 0
		fi
	done
	return 1
}

URL=$(resolve_url)
echo "== xray JSON sub smoke =="
echo "WEBDOMAIN=$WEBDOMAIN"
echo "URL=$URL"
echo "BODY=$BODY"

fetch_url "$URL" "$BODY"
BYTES=$(wc -c <"$BODY" | tr -d ' ')
[[ "$BYTES" -gt 200 ]] || die "subscription body too small ($BYTES bytes)"
pass "fetched $BYTES bytes"

command -v jq >/dev/null 2>&1 || die "jq is required"

DOC_COUNT=$(jq 'if type=="array" then length else 1 end' "$BODY")
[[ "$DOC_COUNT" -ge 1 ]] || die "empty JSON subscription"
pass "docs=$DOC_COUNT"

# First document (inbound profile): admin→proxy then network→direct must appea
# before any later panel-appended catch-all→proxy (first-match wins).
jq -e --arg d "$WEBDOMAIN" '
	(if type=="array" then .[0] else . end) as $doc
	| ($doc.routing.rules // []) as $r
	| ($r | length) >= 2
	and ($r[0].domain != null)
	and (($r[0].domain | map(tostring) | join(" ")) | contains("arcane." + $d))
	and ($r[0].outboundTag == "proxy" or (($r[0].balancerTag // "") | length) > 0)
	and (([$r[] | select(.network != null)][0].outboundTag) == "direct")
' "$BODY" >/dev/null || {
	echo "first-doc rules:" >&2
	jq -c '(if type=="array" then .[0] else . end).routing.rules' "$BODY" >&2 || true
	die "first doc missing admin→proxy then network→direct"
}
pass "first doc: admin→proxy then network→direct"

# AUTO balancer document (if present): leastPing + balancers/observatory.
AUTO_IDX=$(jq -r '
	if type != "array" then empty
	else
		to_entries
		| map(select((.value.remarks // "") == "AUTO" or ((.value.routing.balancers // []) | length) > 0))
		| .[0].key // empty
	end
' "$BODY")

if [[ -n "$AUTO_IDX" ]]; then
	pass "AUTO/balancer doc at index $AUTO_IDX"
	jq -e --argjson i "$AUTO_IDX" '
		.[$i] as $doc
		| ($doc.routing.balancers // []) as $b
		| ($b | length) > 0
		and (
			([$b[] | .strategy.type // empty] | any(. == "leastPing"))
			or ([$b[] | .strategy // empty] | any(. == "leastPing"))
		)
	' "$BODY" >/dev/null || die "AUTO doc missing balancers/leastPing"
	pass "AUTO balancers/leastPing"
	if jq -e --argjson i "$AUTO_IDX" '
		.[$i] | (.burstObservatory != null) or (.observatory != null)
	' "$BODY" >/dev/null; then
		pass "AUTO observatory present"
	else
		echo "WARN: AUTO doc has no observatory/burstObservatory (non-fatal)"
	fi
	PICK_IDX=$AUTO_IDX
else
	echo "WARN: no AUTO/balancer doc found; will test first doc only"
	PICK_IDX=0
fi

# Materialize a single runnable config for xray run -test.
jq --argjson i "${PICK_IDX:-0}" '
	(if type=="array" then .[$i] else . end)
	| del(.remarks)
' "$BODY" >"$CFG"
pass "wrote test config $CFG"

if [[ "$SKIP_RUNTIME" != "1" ]]; then
	if XRAY_BIN=$(find_xray); then
		echo "runtime binary: $XRAY_BIN"
		"$XRAY_BIN" run -test -c "$CFG" || die "$XRAY_BIN run -test failed"
		pass "$XRAY_BIN run -test"
	else
		echo "SKIP: xray/xray-core binary not found (body asserts still passed)"
	fi
else
	echo "SKIP: runtime test (SKIP_RUNTIME=1)"
fi

echo "smoke_xray_sub: PASS"
