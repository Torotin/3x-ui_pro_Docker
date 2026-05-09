#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${CLEAR_SCREEN:-0}" == "1" && -t 1 ]]; then
	clear
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_COMPOSE_DIR="$SCRIPT_DIR"
if [[ "$(basename "$SCRIPT_DIR")" != "compose.d" && -d "$SCRIPT_DIR/compose.d" ]]; then
	DEFAULT_COMPOSE_DIR="$SCRIPT_DIR/compose.d"
fi

COMPOSE_DIR="${COMPOSE_DIR:-$DEFAULT_COMPOSE_DIR}"
ACTIVE_COMPOSE_DIR="$COMPOSE_DIR"
ENV_FILE_DEFAULT="$SCRIPT_DIR/.env"
ENV_FILE_USER_SET=false
if [[ -n "${ENV_FILE+set}" ]]; then
	ENV_FILE_USER_SET=true
fi

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-docker-proxy}"
PULL_BEFORE_UP="${PULL_BEFORE_UP:-0}"
PULL_ON_REBUILD="${PULL_ON_REBUILD:-1}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
RESTART_WITH_DEPS="${RESTART_WITH_DEPS:-0}"
CLEAN_UNHEALTHY="${CLEAN_UNHEALTHY:-0}"
LOCK_FILE="${LOCK_FILE:-$COMPOSE_DIR/.run-compose.lock}"

ENV_ARGS=()
COMPOSE_ARGS=()
COMPOSE_BASE_ARGS=()
COMPOSE_FILES=()

log() {
	printf '[%s] [run-compose] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

usage() {
	cat <<'USAGE'
Usage:
  run-compose.sh [up|-d args...]          Safe docker compose up -d by default.
  run-compose.sh validate                 Run docker compose config.
  run-compose.sh list-files               Print active compose files in order.
  run-compose.sh restart [--logs] SERVICE [SERVICE...]
  run-compose.sh rebuild [SERVICE...]     Pull, remove, and force recreate.
  run-compose.sh logs SERVICE [ARGS...]   Follow docker logs.
  run-compose.sh clean-unhealthy          Show logs and remove unhealthy containers.
  run-compose.sh down [ARGS...]           Pass through docker compose down.

Environment:
  COMPOSE_PROJECT_NAME=docker-proxy
  COMPOSE_DIR=<dir>
  ENV_FILE=<path>
  RESTART_WITH_DEPS=1
  PULL_BEFORE_UP=1
  PULL_ON_REBUILD=0
  CLEAN_UNHEALTHY=1
  CLEAR_SCREEN=1
USAGE
}

pick_compose_dir() {
	if [[ -d "$ACTIVE_COMPOSE_DIR" ]]; then
		return
	fi

	log "Каталог $ACTIVE_COMPOSE_DIR не найден, ищем файлы рядом со скриптом ($SCRIPT_DIR)"
	ACTIVE_COMPOSE_DIR="$SCRIPT_DIR"

	if [[ ! -d "$ACTIVE_COMPOSE_DIR" ]]; then
		log "ERROR: Каталог с compose-файлами не найден: $ACTIVE_COMPOSE_DIR"
		exit 1
	fi
}

collect_compose_files() {
	mapfile -d '' -t COMPOSE_FILES < <(
		find "$ACTIVE_COMPOSE_DIR" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 |
			LC_ALL=C sort -z
	)
}

pick_compose_command() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		COMPOSE_CMD=(docker compose)
	elif command -v docker-compose >/dev/null 2>&1; then
		COMPOSE_CMD=(docker-compose)
	else
		log "ERROR: Не найден docker compose или docker-compose в PATH"
		exit 1
	fi
}

build_compose_args() {
	COMPOSE_ARGS=()
	for f in "${COMPOSE_FILES[@]}"; do
		COMPOSE_ARGS+=(-f "$f")
	done
}

setup_env_file_path() {
	if [[ "$ENV_FILE_USER_SET" == "true" ]]; then
		return
	fi
	ENV_FILE="$ENV_FILE_DEFAULT"
}

ensure_env_file() {
	if [[ -f "${ENV_FILE:-}" ]]; then
		return
	fi

	if [[ "$ENV_FILE_USER_SET" == "true" ]]; then
		log "ERROR: Указанный env-файл не найден: $ENV_FILE"
	else
		log "ERROR: Env-файл по умолчанию не найден: $ENV_FILE"
	fi
	log "Подсказка: задайте ENV_FILE=... или создайте файл по указанному пути"
	exit 1
}

configure_env_args() {
	ENV_ARGS=()
	ensure_env_file
	ENV_ARGS=(--env-file "$ENV_FILE")
	log "Используем env-файл: $ENV_FILE"
}

build_base_args() {
	COMPOSE_BASE_ARGS=(--project-name "$COMPOSE_PROJECT_NAME" "${ENV_ARGS[@]}" "${COMPOSE_ARGS[@]}")
}

run_compose() {
	"${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"
}

compose_config_output() {
	run_compose config
}

warn_on_top_level_name() {
	local output=$1 configured_name
	configured_name=$(awk '/^name: / {print $2; exit}' <<<"$output")
	if [[ -n "$configured_name" && "$configured_name" != "$COMPOSE_PROJECT_NAME" ]]; then
		log "WARN: docker compose config содержит name: $configured_name; принудительно используется --project-name $COMPOSE_PROJECT_NAME"
	elif rg -n '^name:' "$ACTIVE_COMPOSE_DIR"/*.yml "$ACTIVE_COMPOSE_DIR"/*.yaml >/dev/null 2>&1; then
		log "WARN: Найден top-level name: в compose-файлах; project name зафиксирован как $COMPOSE_PROJECT_NAME"
	fi
}

validate_configs() {
	local output
	log "Проверяем конфигурацию: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} config"
	if ! output=$(compose_config_output 2>&1); then
		log "ERROR: Найдены ошибки в конфигурации compose:"
		printf '%s\n' "$output" >&2
		exit 1
	fi
	warn_on_top_level_name "$output"
	printf '%s\n' "$output"
}

compose_container_names() {
	compose_config_output | awk '
		/^services:/ {in_services=1; next}
		in_services && /^[^[:space:]]/ {in_services=0}
		in_services && /^  [A-Za-z0-9_.-]+:/ {
			service=$1
			sub(/:$/, "", service)
		}
		in_services && /^[[:space:]]+container_name:/ {
			print service "\t" $2
		}
	'
}

service_is_selected() {
	local candidate=$1 service
	shift || true
	if (($# == 0)); then
		return 0
	fi
	for service in "$@"; do
		if [[ "$service" == "$candidate" ]]; then
			return 0
		fi
	done
	return 1
}

preflight_container_name_conflicts() {
	local service container project conflict=0
	while IFS=$'\t' read -r service container; do
		[[ -n "$service" && -n "$container" ]] || continue
		service_is_selected "$service" "$@" || continue
		if ! docker container inspect "$container" >/dev/null 2>&1; then
			continue
		fi
		project=$(docker container inspect "$container" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)
		if [[ "$project" != "$COMPOSE_PROJECT_NAME" ]]; then
			log "ERROR: контейнер '$container' для сервиса '$service' уже существует вне project '$COMPOSE_PROJECT_NAME' (project='${project:-<none>}')"
			conflict=1
		fi
	done < <(compose_container_names)
	if ((conflict == 1)); then
		log "Подсказка: удалите конфликтующий контейнер вручную или используйте отдельную явную очистку, затем повторите команду"
		exit 1
	fi
}

get_compose_images() {
	compose_config_output | awk '/image:/ {print $2}' | sort -u
}

snapshot_images_state() {
	while read -r img; do
		[[ -n "$img" ]] || continue
		printf '%s %s\n' "$img" "$(docker image inspect "$img" --format '{{.Id}}' 2>/dev/null || echo "<missing>")"
	done < <(get_compose_images)
}

pull_images() {
	local before after updated
	log "Проверяем и скачиваем обновления образов"
	before="$(snapshot_images_state)"
	run_compose pull
	after="$(snapshot_images_state)"
	updated=$(join -j1 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | awk '$2 != $3 {print $1, $2, "→", $3}')
	if [[ -n "$updated" ]]; then
		log "Обновлены образы:"
		while read -r line; do
			log "  - $line"
		done <<<"$updated"
	else
		log "Образы уже актуальны"
	fi
}

remove_unhealthy_containers() {
	if ! command -v awk >/dev/null 2>&1; then
		log "WARN: awk недоступен, пропускаем удаление unhealthy контейнеров"
		return
	fi

	local lines
	if ! lines=$(run_compose ps --format "table {{.Name}}\t{{.Health}}" 2>/dev/null); then
		log "WARN: Не удалось получить список контейнеров для проверки здоровья"
		return
	fi

	mapfile -t UNHEALTHY < <(printf '%s\n' "$lines" | tail -n +2 | awk '$2=="unhealthy"{print $1}')
	if [[ ${#UNHEALTHY[@]} -eq 0 ]]; then
		log "Unhealthy контейнеров не обнаружено"
		return
	fi

	log "Найдены unhealthy контейнеры: ${UNHEALTHY[*]}"
	for c in "${UNHEALTHY[@]}"; do
		log "Логи $c (последние 100 строк):"
		docker logs --tail 100 "$c" 2>&1 || log "WARN: Не удалось получить логи $c"
	done

	log "Останавливаем и удаляем: ${UNHEALTHY[*]}"
	for c in "${UNHEALTHY[@]}"; do
		docker rm -f "$c" >/dev/null 2>&1 || log "WARN: Не удалось удалить $c"
	done
}

run_up_with_retries() {
	local attempts="$RETRY_COUNT" delay="$RETRY_DELAY" attempt
	preflight_container_name_conflicts "$@"
	for ((attempt = 1; attempt <= attempts; attempt++)); do
		log "Попытка ${attempt}/${attempts}: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} up -d $*"
		if run_compose up -d "$@"; then
			return 0
		fi
		if [[ "$CLEAN_UNHEALTHY" == "1" ]]; then
			remove_unhealthy_containers
		fi
		if ((attempt < attempts)); then
			log "Попытка ${attempt} неудачна, повтор через ${delay}с"
			sleep "$delay"
		fi
	done
	log "Команда не удалась после ${attempts} попыток"
	return 1
}

run_rebuild() {
	local services=("$@")
	validate_configs >/dev/null
	preflight_container_name_conflicts "${services[@]}"
	if [[ "$PULL_ON_REBUILD" == "1" ]]; then
		pull_images
	fi
	log "Удаляем контейнеры перед rebuild: ${services[*]:-весь стек}"
	if ((${#services[@]} > 0)); then
		run_compose rm --stop --force "${services[@]}" || log "WARN: rm завершился с ошибкой, продолжаем"
		run_compose up -d --force-recreate "${services[@]}"
	else
		run_compose rm --stop --force || log "WARN: rm завершился с ошибкой, продолжаем"
		run_compose up -d --force-recreate
	fi
}

run_restart() {
	local follow_logs=0 services=() svc up_args=(-d --force-recreate)
	while (($# > 0)); do
		case "$1" in
			--logs) follow_logs=1 ;;
			*) services+=("$1") ;;
		esac
		shift
	done
	if ((${#services[@]} == 0)); then
		log "ERROR: Для restart нужно указать имя сервиса(ов)"
		exit 1
	fi
	if [[ "$RESTART_WITH_DEPS" != "1" ]]; then
		up_args=(-d --no-deps --force-recreate)
	else
		preflight_container_name_conflicts "${services[@]}"
	fi
	for svc in "${services[@]}"; do
		log "Перезапуск сервиса (rm --stop --force): $svc"
		run_compose rm --stop --force "$svc" || log "WARN: Не удалось удалить контейнер $svc, продолжаем"
		log "Запуск сервиса: $svc"
		run_compose up "${up_args[@]}" "$svc"
	done
	if ((follow_logs == 1)); then
		log "Показываем логи сервиса ${services[-1]} (Ctrl+C для выхода)"
		exec docker logs -f "${services[-1]}"
	fi
}

run_logs() {
	if (($# == 0)); then
		log "ERROR: Для logs нужно указать имя контейнера"
		exit 1
	fi
	exec docker logs -f "$@"
}

list_files() {
	printf '%s\n' "${COMPOSE_FILES[@]}"
}

acquire_lock() {
	local cmd=${1:-}
	case "$cmd" in
		help|--help|-h|list-files|logs|validate|config|ps) return ;;
	esac
	command -v flock >/dev/null 2>&1 || {
		log "WARN: flock недоступен, продолжаем без lock"
		return
	}
	if [[ ! -e "$LOCK_FILE" ]]; then
		install -m 0666 /dev/null "$LOCK_FILE"
	elif [[ ! -w "$LOCK_FILE" ]]; then
		log "ERROR: Lock file is not writable: $LOCK_FILE"
		log "ERROR: Remove it or fix permissions, for example: sudo rm -f '$LOCK_FILE'"
		exit 1
	fi
	chmod a+rw "$LOCK_FILE" 2>/dev/null || true
	exec 9>"$LOCK_FILE"
	if ! flock -n 9; then
		log "ERROR: Уже выполняется другой run-compose.sh (lock: $LOCK_FILE)"
		exit 1
	fi
}

main() {
	pick_compose_dir
	setup_env_file_path
	log "Каталог с compose-файлами: $ACTIVE_COMPOSE_DIR"
	collect_compose_files
	if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
		log "ERROR: В каталоге $ACTIVE_COMPOSE_DIR нет файлов compose (*.yml или *.yaml)"
		exit 1
	fi

	if (($# == 0)); then
		set -- up
	fi

	case "$1" in
		help|--help|-h)
			usage
			return
			;;
		list-files)
			list_files
			return
			;;
		logs)
			shift
			run_logs "$@"
			return
			;;
	esac

	pick_compose_command
	build_compose_args
	configure_env_args
	build_base_args

	acquire_lock "$1"

	case "$1" in
		validate|config)
			validate_configs >/dev/null
			;;
		up)
			shift
			if [[ "$PULL_BEFORE_UP" == "1" ]]; then
				pull_images
			fi
			run_up_with_retries "$@"
			;;
		rebuild)
			shift
			run_rebuild "$@"
			;;
		restart)
			shift
			run_restart "$@"
			;;
		clean-unhealthy)
			remove_unhealthy_containers
			;;
		down)
			shift
			log "Остановка стека: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} down $*"
			exec "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" down "$@"
			;;
		*)
			log "Запуск: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} $*"
			exec "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"
			;;
	esac
}

main "$@"
