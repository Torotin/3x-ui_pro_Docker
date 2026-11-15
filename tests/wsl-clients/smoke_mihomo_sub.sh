#!/usr/bin/env bash
# WSL smoke: fetch Clash/Mihomo subscription and validate connection policies.
# Optional: mihomo/clash -t; optional mixed-port curl to admin (expect 401).
set -Eeuo pipefail

WEBDOMAIN="${WEBDOMAIN:-streambase.linkpc.net}"
CLASH_PATH="${CLASH_PATH:-/A1yh2uqDoMqw/}"
SUB_ID="${SUB_ID:-}"
CLASH_SUB_URL="${CLASH_SUB_URL:-}"
PROFILE="${PROFILE:-/tmp/wsl-clash-smoke.yaml}"
MIXED_PORT="${MIXED_PORT:-17890}"
SKIP_RUNTIME="${SKIP_RUNTIME:-0}"
SKIP_PROXY_CURL="${SKIP_PROXY_CURL:-0}"

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
	if [[ -n "$CLASH_SUB_URL" ]]; then
		printf '%s\n' "$CLASH_SUB_URL"
		return 0
	fi
	[[ -n "$SUB_ID" ]] || die "set CLASH_SUB_URL or SUB_ID"
	case "$CLASH_PATH" in
		/*) ;;
		*) CLASH_PATH="/$CLASH_PATH" ;;
	esac
	printf 'https://%s%s%s\n' "$WEBDOMAIN" "$CLASH_PATH" "$SUB_ID"
}

find_mihomo() {
	local bin
	for bin in mihomo clash-meta clash; do
		if command -v "$bin" >/dev/null 2>&1; then
			printf '%s\n' "$bin"
			return 0
		fi
	done
	return 1
}

URL=$(resolve_url)
echo "== mihomo/Clash sub smoke =="
echo "WEBDOMAIN=$WEBDOMAIN"
echo "URL=$URL"
echo "PROFILE=$PROFILE"

fetch_url "$URL" "$PROFILE"
BYTES=$(wc -c <"$PROFILE" | tr -d ' ')
[[ "$BYTES" -gt 200 ]] || die "subscription body too small ($BYTES bytes)"
pass "fetched $BYTES bytes"

AUTO_NAME="AUTO-${WEBDOMAIN}"
PROXY_NAME="PROXY-${WEBDOMAIN}"
grep -Fq "name: ${AUTO_NAME}" "$PROFILE" || die "missing name: ${AUTO_NAME}"
pass "name: ${AUTO_NAME}"
grep -Fq 'hidden: true' "$PROFILE" || die "AUTO must be hidden: true"
pass "AUTO hidden: true"
grep -Fq "name: ${PROXY_NAME}" "$PROFILE" || die "missing name: ${PROXY_NAME}"
pass "name: ${PROXY_NAME}"
grep -Fq "      - ${AUTO_NAME}" "$PROFILE" || grep -Fq -- "- ${AUTO_NAME}" "$PROFILE" ||
	die "${PROXY_NAME} must list ${AUTO_NAME}"
pass "${PROXY_NAME} lists ${AUTO_NAME}"
grep -Fq 'type: url-test' "$PROFILE" || die "missing type: url-test"
pass "type: url-test"
grep -Fq 'MATCH,DIRECT' "$PROFILE" || die "missing MATCH,DIRECT"
pass "MATCH,DIRECT"
grep -Fq "DOMAIN,arcane.${WEBDOMAIN},${PROXY_NAME}" "$PROFILE" ||
	die "missing DOMAIN,arcane.${WEBDOMAIN},${PROXY_NAME}"
pass "admin DOMAIN,arcane…,${PROXY_NAME}"

if grep -Eq '(^|[[:space:]-])MATCH,PROXY([[:space:]]|$)' "$PROFILE"; then
	die "residual MATCH,PROXY must not remain"
fi
pass "no residual MATCH,PROXY"

MIHOMO_BIN=""
if [[ "$SKIP_RUNTIME" != "1" ]]; then
	if MIHOMO_BIN=$(find_mihomo); then
		echo "runtime binary: $MIHOMO_BIN"
		"$MIHOMO_BIN" -t -f "$PROFILE" || die "$MIHOMO_BIN -t failed"
		pass "$MIHOMO_BIN -t"
	else
		echo "SKIP: mihomo/clash binary not found (body asserts still passed)"
	fi
else
	echo "SKIP: runtime test (SKIP_RUNTIME=1)"
fi

# Optional: brief mixed-port listen + curl admin via PROXY (expect HTTP 401).
if [[ "$SKIP_PROXY_CURL" != "1" && -n "$MIHOMO_BIN" ]]; then
	RUNTIME_CFG="${PROFILE%.yaml}.runtime.yaml"
	# Force a known mixed-port and keep existing rules/groups.
	{
		echo "mixed-port: ${MIXED_PORT}"
		echo "allow-lan: false"
		echo "mode: rule"
		# Drop any existing port keys that would conflict; append profile body.
		grep -Ev '^(mixed-port|port|socks-port|redir-port|tproxy-port|allow-lan|external-controller):' "$PROFILE" || true
	} >"$RUNTIME_CFG"

	LOG=/tmp/wsl-mihomo-smoke.log
	"$MIHOMO_BIN" -f "$RUNTIME_CFG" >"$LOG" 2>&1 &
	PID=$!
	cleanup() {
		kill "$PID" >/dev/null 2>&1 || true
		wait "$PID" 2>/dev/null || true
	}
	trap cleanup EXIT

	ok_proxy=0
	for _ in $(seq 1 20); do
		if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${MIXED_PORT}" 2>/dev/null ||
			ss -ltn 2>/dev/null | grep -q ":${MIXED_PORT}" ||
			nc -z 127.0.0.1 "$MIXED_PORT" 2>/dev/null; then
			ok_proxy=1
			break
		fi
		sleep 0.25
	done

	if [[ "$ok_proxy" -eq 1 ]]; then
		code=$(curl -sx "http://127.0.0.1:${MIXED_PORT}" -sk \
			-o /dev/null -w "%{http_code}" --max-time 25 \
			"https://arcane.${WEBDOMAIN}:9443/" || true)
		if [[ "$code" == "401" ]]; then
			pass "PROXY curl arcane:9443 → 401"
		else
			echo "WARN: PROXY curl arcane:9443 expected 401 got '${code}' (non-fatal)"
		fi
	else
		echo "SKIP: mixed-port ${MIXED_PORT} did not come up (see $LOG)"
	fi
	cleanup
	trap - EXIT
else
	echo "SKIP: optional PROXY curl (no binary or SKIP_PROXY_CURL=1)"
fi

echo "smoke_mihomo_sub: PASS"
