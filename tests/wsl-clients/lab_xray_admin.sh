#!/usr/bin/env bash
# Local WSL lab: run a v2rayN/Xray client JSON and probe admin :9443.
set -euo pipefail

LAB="${LAB_DIR:-/tmp/xray-admin-lab}"
SRC_CONFIG="${SRC_CONFIG:-/mnt/d/Test/v2rayN-windows-64-desktop/binConfigs/config.json}"
XRAY_VER="${XRAY_VER:-v26.3.27}"
ADMIN_URL="${ADMIN_URL:-https://arcane.streambase.linkpc.net:9443/}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
HTTP_PORT="${HTTP_PORT:-10809}"

mkdir -p "$LAB"
cd "$LAB"

if [[ ! -x "$LAB/xray" ]]; then
	echo "== download Xray ${XRAY_VER} =="
	curl -fsSL -o xray.zip \
		"https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
	unzip -o xray.zip xray
	chmod +x xray
fi
./xray version

[[ -f "$SRC_CONFIG" ]] || {
	echo "FAIL: missing SRC_CONFIG=$SRC_CONFIG" >&2
	exit 1
}
cp "$SRC_CONFIG" "$LAB/config.orig.json"

# Runnable copy: debug logs, drop remarks, optional single-outbound mode.
MODE="${MODE:-orig}" # orig | vision-only
case "$MODE" in
orig)
	jq 'del(.remarks) | .log.loglevel="debug"' config.orig.json >config.json
	;;
vision-only)
	# Isolate Vision: rename first bal-1-vless -> proxy, drop balancer/other proxies.
	jq '
		del(.remarks)
		| .log.loglevel = "debug"
		| (.outbounds |= map(if .tag == "bal-1-vless" then .tag = "proxy" else . end))
		| .outbounds |= map(select(.tag == "proxy" or .tag == "direct" or .tag == "block"))
		| del(.routing.balancers, .burstObservatory, .observatory)
		| .routing.rules = [
			{
				type: "field",
				domain: [
					"full:arcane.streambase.linkpc.net",
					"full:homepage.streambase.linkpc.net",
					"full:adguard.streambase.linkpc.net",
					"full:3x-ui.streambase.linkpc.net",
					"full:traefik.streambase.linkpc.net",
					"full:lampac-admin.streambase.linkpc.net"
				],
				outboundTag: "proxy"
			},
			{ type: "field", port: "9443", network: "tcp", outboundTag: "proxy" },
			{ type: "field", network: "tcp,udp", outboundTag: "direct" }
		]
	' config.orig.json >config.json
	;;
*)
	echo "FAIL: unknown MODE=$MODE (orig|vision-only)" >&2
	exit 1
	;;
esac

echo "== mode=$MODE =="
echo "inbounds:"; jq -c '.inbounds[] | {tag,protocol,port,sniffing:(.sniffing.enabled // false)}' config.json
echo "outbounds:"; jq -r '.outbounds[].tag' config.json
echo "rules:"; jq -c '.routing.rules' config.json
echo "dns.hosts arcane:"; jq -r '.dns.hosts["arcane.streambase.linkpc.net"] // empty' config.json

echo "== xray run -test =="
./xray run -test -c config.json

pkill -f "$LAB/xray run -c $LAB/config.json" 2>/dev/null || true
sleep 1
: >"$LAB/xray.log"
./xray run -c config.json >>"$LAB/xray.log" 2>&1 &
XPID=$!
cleanup() { kill "$XPID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2
if ! kill -0 "$XPID" 2>/dev/null; then
	echo "FAIL: xray exited"
	tail -80 "$LAB/xray.log"
	exit 1
fi
echo "xray pid=$XPID"

probe() {
	local name=$1 url=$2
	local code
	code=$(curl -sk --max-time 25 -o /tmp/admin.body -w '%{http_code}' "$url" || true)
	echo "$name -> HTTP ${code:-err}"
}

echo "== probes =="
probe "direct(no proxy)" "$ADMIN_URL"
code=$(curl -sk --max-time 25 -x "socks5h://127.0.0.1:${SOCKS_PORT}" -o /tmp/admin.body -w '%{http_code}' "$ADMIN_URL" || true)
echo "socks5h://${SOCKS_PORT} -> HTTP ${code:-err}"
code=$(curl -sk --max-time 25 -x "http://127.0.0.1:${HTTP_PORT}" -o /tmp/admin.body -w '%{http_code}' "$ADMIN_URL" || true)
echo "http://${HTTP_PORT} -> HTTP ${code:-err}"
# IP dial (simulates browser that resolved via hosts → PUBLIC_IPV4)
code=$(curl -sk --max-time 25 -x "socks5://127.0.0.1:${SOCKS_PORT}" -o /tmp/admin.body -w '%{http_code}' \
	--resolve "arcane.streambase.linkpc.net:9443:31.77.251.179" "$ADMIN_URL" || true)
echo "socks5+resolve IP -> HTTP ${code:-err}"

echo "== last xray log lines =="
tail -60 "$LAB/xray.log" || true
