#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
LIB="$ROOT/docker-proxy/3x-ui/scripts/lib"
FIX="$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "$FIX"
# shellcheck source=../../../../docker-proxy/3x-ui/scripts/lib/desired_state.bash
. "$LIB/desired_state.bash"
# shellcheck source=../../../../docker-proxy/3x-ui/scripts/lib/inbound_runtime.bash
. "$LIB/inbound_runtime.bash"

export WEBDOMAIN=fixture.example.test
export URI_VLESS_XHTTP=/xhttp-fixture
export URI_VLESS_GRPC=/grpc-fixture
export CLIENT_EMAIL_PREFIX=autogen
export CLIENT_SUB_ID=fixture-sub-id-01
FP=random

SOCK=$(build_sockopt_json false AsIs off)
V=$(build_vision_stream_json telemt:9443 fixture.example.test priv-key pub-key \
	'["aa11","bb22"]' "$SOCK" "" "" 1)
V=$(printf '%s' "$V" | jq -c --arg fp "$FP" \
	'.realitySettings.settings.fingerprint=$fp | .externalProxy[0].fingerprint=$fp')
printf '%s\n' "$V" >"$FIX/vision_stream.json"

X=$(build_xhttp_stream_json /xhttp-fixture fixture.example.test)
X=$(printf '%s' "$X" | jq -c --arg fp "$FP" '.externalProxy[0].fingerprint=$fp')
printf '%s\n' "$X" >"$FIX/xhttp_stream.json"

G=$(build_grpc_stream_json /grpc-fixture fixture.example.test \
	/etc/fixture/cert.pem /etc/fixture/key.pem)
G=$(printf '%s' "$G" | jq -c --arg fp "$FP" \
	'.tlsSettings.settings.fingerprint=$fp | .externalProxy[0].fingerprint=$fp')
printf '%s\n' "$G" >"$FIX/grpc_stream.json"

unset HYSTERIA2_MASQ_URL
H=$(build_hysteria2_stream_json fixture.example.test /etc/fixture/cert.pem \
	/etc/fixture/key.pem h2-auth)
H=$(printf '%s' "$H" | jq -c --arg fp "$FP" '.tlsSettings.settings.fingerprint=$fp')
printf '%s\n' "$H" >"$FIX/hysteria2_stream.json"

DESIRED=$(build_desired_state)
A=$(build_amneziawg_settings_json "$DESIRED")
printf '%s\n' "$A" >"$FIX/amneziawg_settings.json"

SETTINGS=$(build_hysteria2_settings_json '' "$DESIRED" fixed-hysteria-auth)
printf '%s\n' "$SETTINGS" >"$FIX/hysteria2_settings.json"

build_tls_settings_json fixture.example.test /etc/fixture/cert.pem \
	/etc/fixture/key.pem '["h3"]' random >"$FIX/tls_settings.json"
build_external_proxy_json fixture.example.test tls '["h2"]' random >"$FIX/external_proxy.json"
build_sockopt_json false UseIP tproxy '["X-Fixture-Trusted"]' >"$FIX/sockopt.json"

echo "fixtures written to $FIX"