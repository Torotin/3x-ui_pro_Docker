#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$ROOT_DIR/docker-proxy/compose.d/run-compose.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	local needle=$1 file=$2 message=$3
	grep -Fq -- "$needle" "$file" || fail "$message; missing: $needle"
}

assert_not_contains() {
	local needle=$1 file=$2 message=$3
	! grep -Fq -- "$needle" "$file" || fail "$message; unexpected: $needle"
}

make_fixture() {
	tmpdir=$(mktemp -d)
	mkdir -p "$tmpdir/bin" "$tmpdir/compose.d"
	cat >"$tmpdir/compose.d/00-base.yml" <<'YAML'
services:
  base:
    image: alpine:latest
    container_name: base
YAML
	cat >"$tmpdir/compose.d/06-traefik.yml" <<'YAML'
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    depends_on:
      dozzle:
        condition: service_healthy
YAML
	cat >"$tmpdir/compose.d/07-dozzle.yml" <<'YAML'
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
YAML
	cat >"$tmpdir/compose.d/99-disabled.yml.disable" <<'YAML'
services:
  disabled:
    image: disabled:latest
YAML
	: >"$tmpdir/compose.d/.env"
	cat >"$tmpdir/bin/docker" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG:?}"
if [[ "${1:-}" == "compose" ]]; then
	shift
	case "$*" in
		*version*) echo "Docker Compose version v2.0.0"; exit 0 ;;
	esac
	cmd=
	for arg in "$@"; do
		case "$arg" in
			config|ps|pull|rm|up|down) cmd=$arg; break ;;
		esac
	done
	case "$cmd" in
		config)
			cat <<'OUT'
name: docker-proxy
services:
  traefik:
    image: traefik:latest
    container_name: traefik
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
OUT
			;;
		ps)
			printf 'Name\tHealth\n'
			;;
	esac
	exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
	echo "sha256:${3:-unknown}"
	exit 0
fi
if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
	exit 1
fi
if [[ "${1:-}" == "logs" ]]; then
	exit 0
fi
exit 0
BASH
	chmod +x "$tmpdir/bin/docker"
}

run_runner() {
	DOCKER_LOG="$tmpdir/docker.log" PATH="$tmpdir/bin:$PATH" COMPOSE_DIR="$tmpdir/compose.d" ENV_FILE="$tmpdir/compose.d/.env" "$RUNNER" "$@"
}

run_runner_default_env() {
	DOCKER_LOG="$tmpdir/docker.log" PATH="$tmpdir/bin:$PATH" COMPOSE_DIR="$tmpdir/compose.d" "$RUNNER" "$@"
}

test_restart_uses_no_deps_by_default() {
	make_fixture
	run_runner restart traefik
	assert_contains "compose --project-name docker-proxy --env-file $tmpdir/compose.d/.env -f $tmpdir/compose.d/00-base.yml -f $tmpdir/compose.d/06-traefik.yml -f $tmpdir/compose.d/07-dozzle.yml rm --stop --force traefik" "$tmpdir/docker.log" "restart must remove target service"
	assert_contains "compose --project-name docker-proxy --env-file $tmpdir/compose.d/.env -f $tmpdir/compose.d/00-base.yml -f $tmpdir/compose.d/06-traefik.yml -f $tmpdir/compose.d/07-dozzle.yml up -d --no-deps --force-recreate traefik" "$tmpdir/docker.log" "restart must recreate target without dependencies"
	assert_not_contains "logs -f traefik" "$tmpdir/docker.log" "restart must not follow logs by default"
}

test_restart_can_include_dependencies() {
	make_fixture
	DOCKER_LOG="$tmpdir/docker.log" PATH="$tmpdir/bin:$PATH" COMPOSE_DIR="$tmpdir/compose.d" ENV_FILE="$tmpdir/compose.d/.env" RESTART_WITH_DEPS=1 "$RUNNER" restart traefik
	assert_contains "up -d --force-recreate traefik" "$tmpdir/docker.log" "RESTART_WITH_DEPS must omit --no-deps"
	assert_not_contains "--no-deps" "$tmpdir/docker.log" "RESTART_WITH_DEPS must not use --no-deps"
}

test_restart_logs_is_explicit() {
	make_fixture
	run_runner restart --logs traefik
	assert_contains "logs -f traefik" "$tmpdir/docker.log" "restart --logs must follow logs"
}

test_up_is_safe_by_default() {
	make_fixture
	run_runner up
	assert_contains "up -d" "$tmpdir/docker.log" "up must run detached by default"
	assert_not_contains " pull" "$tmpdir/docker.log" "safe up must not pull by default"
	assert_not_contains "rm --stop --force" "$tmpdir/docker.log" "safe up must not remove containers"
}

test_lock_file_is_compose_local_and_world_writable() {
	make_fixture
	run_runner up
	local lock_file="$tmpdir/compose.d/.run-compose.lock"
	[[ -f "$lock_file" ]] || fail "run-compose must create compose-local lock file"
	local mode
	mode=$(stat -c '%a' "$lock_file")
	[[ "$mode" == "666" ]] || fail "run-compose lock file must be writable across sudo/non-sudo runs; got $mode"
}

test_default_env_and_lock_follow_active_compose_dir() {
	make_fixture
	run_runner_default_env up >/tmp/run-compose-default-env.out 2>&1
	assert_contains "Project root: $tmpdir" /tmp/run-compose-default-env.out "run-compose must report project root derived from active compose dir"
	assert_contains "Каталог с compose-файлами: $tmpdir/compose.d" /tmp/run-compose-default-env.out "run-compose must use active compose dir"
	assert_contains "Используем env-файл: $tmpdir/compose.d/.env" /tmp/run-compose-default-env.out "default env file must be active compose dir .env"
	assert_contains "Lock file: $tmpdir/compose.d/.run-compose.lock" /tmp/run-compose-default-env.out "default lock file must be active compose dir local lock"
	assert_contains "compose --project-name docker-proxy --env-file $tmpdir/compose.d/.env" "$tmpdir/docker.log" "docker compose must receive active compose dir env file"
}

test_rebuild_is_destructive_explicitly() {
	make_fixture
	run_runner rebuild traefik
	assert_contains "config" "$tmpdir/docker.log" "rebuild must validate config"
	assert_contains "pull" "$tmpdir/docker.log" "rebuild must pull images"
	assert_contains "rm --stop --force traefik" "$tmpdir/docker.log" "rebuild must remove target"
	assert_contains "up -d --force-recreate traefik" "$tmpdir/docker.log" "rebuild must force recreate target"
}

test_missing_explicit_env_file_fails() {
	make_fixture
	if DOCKER_LOG="$tmpdir/docker.log" PATH="$tmpdir/bin:$PATH" COMPOSE_DIR="$tmpdir/compose.d" ENV_FILE="$tmpdir/missing.env" "$RUNNER" validate >/tmp/run-compose-missing.out 2>&1; then
		fail "missing explicit ENV_FILE must fail"
	fi
	assert_contains "Указанный env-файл не найден" /tmp/run-compose-missing.out "missing explicit env must explain failure"
}

test_list_files_excludes_disabled_files() {
	make_fixture
	output=$(run_runner list-files)
	if ! grep -Fq "00-base.yml" <<<"$output"; then
		fail "list-files must include active compose files"
	fi
	if grep -Fq "99-disabled.yml.disable" <<<"$output"; then
		fail "list-files must exclude disabled files"
	fi
}

test_list_files_does_not_require_env_file() {
	make_fixture
	rm -f "$tmpdir/compose.d/.env"
	output=$(DOCKER_LOG="$tmpdir/docker.log" PATH="$tmpdir/bin:$PATH" COMPOSE_DIR="$tmpdir/compose.d" "$RUNNER" list-files)
	if ! grep -Fq "00-base.yml" <<<"$output"; then
		fail "list-files must work without env file"
	fi
	if [[ -f "$tmpdir/docker.log" ]]; then
		fail "list-files must not invoke docker"
	fi
}

test_up_reports_foreign_container_name_conflict() {
	make_fixture
	cat >"$tmpdir/bin/docker" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG:?}"
if [[ "${1:-}" == "compose" ]]; then
	shift
	case "$*" in
		*version*) echo "Docker Compose version v2.0.0"; exit 0 ;;
	esac
	for arg in "$@"; do
		if [[ "$arg" == "config" ]]; then
			cat <<'OUT'
name: docker-proxy
services:
  traefik:
    image: traefik:latest
    container_name: traefik
OUT
			exit 0
		fi
	done
	exit 0
fi
if [[ "${1:-}" == "container" && "${2:-}" == "inspect" ]]; then
	if [[ "${4:-}" == "--format" ]]; then
		echo "other-project"
	fi
	exit 0
fi
exit 0
BASH
	chmod +x "$tmpdir/bin/docker"
	if run_runner up >/tmp/run-compose-conflict.out 2>&1; then
		fail "foreign container_name conflict must fail"
	fi
	assert_contains "уже существует вне project" /tmp/run-compose-conflict.out "conflict error must be explicit"
}

test_compose_fragments_do_not_hardcode_project_root() {
	if grep -R --line-number --fixed-strings "/opt/docker-proxy" "$ROOT_DIR/docker-proxy/compose.d"; then
		fail "compose fragments must use paths relative to compose.d instead of /opt/docker-proxy"
	fi
}

test_restart_uses_no_deps_by_default
test_restart_can_include_dependencies
test_restart_logs_is_explicit
test_up_is_safe_by_default
test_lock_file_is_compose_local_and_world_writable
test_default_env_and_lock_follow_active_compose_dir
test_rebuild_is_destructive_explicitly
test_missing_explicit_env_file_fails
test_list_files_excludes_disabled_files
test_list_files_does_not_require_env_file
test_up_reports_foreign_container_name_conflict
test_compose_fragments_do_not_hardcode_project_root
printf 'test_run_compose.bash: OK\n'
