#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE_FILE="$ROOT_DIR/docker-proxy/compose.d/12-3x-ui.yml"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

compose_value() {
	local filter=$1
	yq -r "$filter" "$COMPOSE_FILE"
}

require_tool yq

image=$(compose_value '.services."sub-json-processor".image // ""')
[[ "$image" == "python:3.12-alpine" ]] ||
	fail "sub-json-processor must use python:3.12-alpine; got '${image:-<missing>}'"

command=$(compose_value '.services."sub-json-processor".command | join(" ")')
[[ "$command" == "python /app/server.py" ]] ||
	fail "sub-json-processor command mismatch; got '${command:-<missing>}'"

mounts=$(compose_value '.services."sub-json-processor".volumes[]?')
grep -Fxq "../3x-ui/sub-json-processor:/app:ro" <<<"$mounts" ||
	fail "sub-json-processor must mount ../3x-ui/sub-json-processor:/app:ro"

environment=$(compose_value '.services."sub-json-processor".environment[]?')
grep -Fxq "SUB_JSON_PROCESSOR_PORT=8080" <<<"$environment" ||
	fail "sub-json-processor must define SUB_JSON_PROCESSOR_PORT locally in compose"
grep -Fxq "SUB_JSON_GEODATA_ENABLE=true" <<<"$environment" ||
	fail "sub-json-processor must define SUB_JSON_GEODATA_ENABLE locally in compose"
grep -Fxq "SUB_JSON_GEODATA_CRON=0 4 * * *" <<<"$environment" ||
	fail "sub-json-processor must define SUB_JSON_GEODATA_CRON locally in compose"
if grep -Fq "SUB_JSON_" "$ROOT_DIR/docker-proxy/3x-ui/3x-ui.env"; then
	fail "SUB_JSON_* processor defaults must not live in docker-proxy/3x-ui/3x-ui.env"
fi

depends_condition=$(compose_value '.services."sub-json-processor".depends_on."3x-ui".condition // ""')
[[ "$depends_condition" == "service_healthy" ]] ||
	fail "sub-json-processor must wait for healthy 3x-ui; got '${depends_condition:-<missing>}'"

processor_rule=$(compose_value '.services."sub-json-processor".labels[] | select(test("traefik.http.routers.sub-json-processor.rule="))')
grep -Fq 'PathPrefix(`${URI_JSON_PATH}`)' <<<"$processor_rule" ||
	fail "sub-json-processor router must match URI_JSON_PATH"

processor_priority=$(compose_value '.services."sub-json-processor".labels[] | select(test("traefik.http.routers.sub-json-processor.priority=")) | split("=")[1] | tonumber')
xui_sub_priority=$(compose_value '.services."3x-ui".labels[] | select(test("traefik.http.routers.3xui-sub.priority=")) | split("=")[1] | tonumber')
((processor_priority > xui_sub_priority)) ||
	fail "sub-json-processor priority must be higher than 3xui-sub"

xui_sub_rule=$(compose_value '.services."3x-ui".labels[] | select(test("traefik.http.routers.3xui-sub.rule="))')
if grep -Fq 'URI_JSON_PATH' <<<"$xui_sub_rule"; then
	fail "3xui-sub router must not match URI_JSON_PATH after processor interception"
fi
grep -Fq 'URI_SUB_PATH' <<<"$xui_sub_rule" ||
	fail "3xui-sub router must keep plain subscription path"
grep -Fq 'URI_CLASH_PATH' <<<"$xui_sub_rule" ||
	fail "3xui-sub router must keep Clash path"

printf 'test_sub_json_processor.bash: OK\n'
