#!/usr/bin/env bash
# Apply Telemt panel GeoIP URL sources (P3TERX GeoLite.mmdb by default).
# Settings live in panel-state (not TOML); this script uses PUT /api/settings/geoip.
# Does not wait for MMDB download — panel fetches asynchronously after PUT.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_ENV="${COMPOSE_ENV:-$PROJECT_ROOT/compose.d/.env}"
CONTAINER="${TELEMT_CONTAINER:-telemt}"
PANEL_URL="${TELEMT_PANEL_INTERNAL_URL:-http://127.0.0.1:8080}"

DEFAULT_CITY='https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-City.mmdb'
DEFAULT_ASN='https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-ASN.mmdb'
DEFAULT_COUNTRY='https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb'

log() { printf '[ensure-geoip] %s\n' "$*"; }

if [[ -f "$COMPOSE_ENV" ]]; then
	set -a
	# shellcheck disable=SC1090
	source "$COMPOSE_ENV"
	set +a
fi

case "${ENABLE_TELEMT:-false}" in
0 | false | no | off | disabled) log "ENABLE_TELEMT off — skip"; exit 0 ;;
esac

case "${TELEMT_GEOIP_ENABLED:-true}" in
0 | false | no | off | disabled) log "TELEMT_GEOIP_ENABLED off — skip"; exit 0 ;;
esac

CITY_URL=${TELEMT_GEOIP_CITY_URL:-$DEFAULT_CITY}
ASN_URL=${TELEMT_GEOIP_ASN_URL:-$DEFAULT_ASN}
COUNTRY_URL=${TELEMT_GEOIP_COUNTRY_URL:-$DEFAULT_COUNTRY}
SCHEDULE=${TELEMT_GEOIP_SCHEDULE:-weekly}

[[ -n "${USER_WEB:-}" && -n "${PASS_WEB:-}" ]] || {
	log "ERROR: USER_WEB/PASS_WEB required in $COMPOSE_ENV"
	exit 1
}

docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -qx true || {
	log "ERROR: container $CONTAINER is not running"
	exit 1
}

# Wait for panel HTTP
for _ in $(seq 1 60); do
	if docker exec "$CONTAINER" curl -fsS "$PANEL_URL/" >/dev/null 2>&1; then
		break
	fi
	sleep 2
done

BODY=$(printf '%s' "{\"enabled\":true,\"source\":\"urls\",\"schedule\":\"${SCHEDULE}\",\"country\":{\"enabled\":true,\"location\":\"${COUNTRY_URL}\"},\"asn\":{\"enabled\":true,\"location\":\"${ASN_URL}\"},\"city\":{\"enabled\":true,\"location\":\"${CITY_URL}\"}}")

# Run curl inside the container so Origin matches the panel listener (CSRF).
docker exec -e USER_WEB="$USER_WEB" -e PASS_WEB="$PASS_WEB" -e BODY="$BODY" -e PANEL_URL="$PANEL_URL" "$CONTAINER" sh -c '
set -eu
rm -f /tmp/ensure-geoip.cj
curl -sS -c /tmp/ensure-geoip.cj -b /tmp/ensure-geoip.cj \
  -H "Content-Type: application/json" \
  -H "Origin: ${PANEL_URL}" \
  -H "Referer: ${PANEL_URL}/server/settings" \
  -X POST "${PANEL_URL}/api/auth/login" \
  -d "{\"username\":\"${USER_WEB}\",\"password\":\"${PASS_WEB}\"}" >/dev/null
code=$(curl -sS -o /tmp/ensure-geoip.out -w "%{http_code}" -b /tmp/ensure-geoip.cj \
  -H "Content-Type: application/json" \
  -H "Origin: ${PANEL_URL}" \
  -H "Referer: ${PANEL_URL}/server/settings" \
  -X PUT "${PANEL_URL}/api/settings/geoip" \
  -d "$BODY")
echo "put_http=$code"
head -c 400 /tmp/ensure-geoip.out; echo
case "$code" in
200|202) ;;
*) exit 1 ;;
esac
# Snapshot only — do not block on download/ready; panel continues in parallel.
curl -sS -b /tmp/ensure-geoip.cj "${PANEL_URL}/api/settings/geoip" 2>/dev/null | head -c 400 || true
echo
exit 0
'

    log "GeoIP sources applied; MMDB download continues in panel (non-blocking)"
