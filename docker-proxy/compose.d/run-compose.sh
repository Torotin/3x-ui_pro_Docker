#!/bin/bash
# Запускает docker compose для всех *.yml/*.yaml в каталоге compose.d (если он есть) или рядом со скриптом (по алфавиту).
# Логика: 
# 1) выбираем каталог с файлами (compose.d или текущий);
# 2) выбираем env-файл (ENV_FILE или .env рядом со скриптом);
# 3) собираем и сортируем файлы compose;
# 4) выбираем доступную CLI (docker compose или docker-compose);
# 5) формируем цепочку --env-file/-f;
# 6) если аргументы не заданы, используем up -d;
# 7) поддерживаем перезапуск одного сервиса: restart <service>;
# 8) перед запуском up останавливаем текущий стек (down);
# 9) делаем до 3 попыток up (параметры RETRY_COUNT/RETRY_DELAY);
# 10) исполняем получившуюся команду.
# Пример итоговой команды:
#   docker compose -f "/path/compose.d/00-base.yml" -f "/path/compose.d/01-watchtower.yml" up -d
# Пример с docker-compose и пользовательскими аргументами:
#   docker-compose -f "/path/compose.d/00-base.yml" -f "/path/compose.d/01-watchtower.yml" ps
# Примеры запуска:
#   ./run-compose.sh               # up -d с тремя попытками, перед этим down
#   RETRY_COUNT=5 ./run-compose.sh # up -d с 5 попытками
#   ./run-compose.sh ps            # любая другая команда выполняется один раз
#   ENV_FILE=/opt/docker-proxy/.env ./run-compose.sh # указать общий env-файл
if [[ "${NO_CLEAR:-0}" -ne 1 ]]; then
  clear
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/compose.d"
ACTIVE_COMPOSE_DIR="$SCRIPT_DIR"
ENV_FILE_DEFAULT="$SCRIPT_DIR/.env"
ENV_FILE_USER_SET=false
if [[ -n "${ENV_FILE+set}" ]]; then
  ENV_FILE_USER_SET=true
fi
ENV_FILE="${ENV_FILE:-$ENV_FILE_DEFAULT}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
PULL_BEFORE_UP="${PULL_BEFORE_UP:-0}"
ENV_ARGS=()
COMPOSE_BASE_ARGS=()

# Единообразный вывод сообщений в stderr.
log() {
  echo "[run-compose] $*" >&2
}

# Выбор каталога: compose.d приоритетнее, иначе работаем из каталога скрипта.
pick_compose_dir() {
  if [[ -d "$COMPOSE_DIR" ]]; then
    ACTIVE_COMPOSE_DIR="$COMPOSE_DIR"
  else
    log "Каталог $COMPOSE_DIR не найден, ищем файлы рядом со скриптом ($ACTIVE_COMPOSE_DIR)"
  fi
}

# Сбор и сортировка файлов compose по имени с учётом пробелов и спецсимволов.
collect_compose_files() {
  mapfile -d '' -t COMPOSE_FILES < <(
    find "$ACTIVE_COMPOSE_DIR" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 |
      LC_ALL=C sort -z
  )
}

# Определяем подходящую CLI docker compose.
pick_compose_command() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    log "Не найден docker compose или docker-compose в PATH"
    exit 1
  fi
}

# Формируем список аргументов -f для всех найденных файлов.
build_compose_args() {
  COMPOSE_ARGS=()
  for f in "${COMPOSE_FILES[@]}"; do
    COMPOSE_ARGS+=(-f "$f")
  done
}

# Конфигурируем env-файл (ENV_FILE или .env рядом со скриптом).
configure_env_args() {
  ENV_ARGS=()

  if [[ -f "$ENV_FILE" ]]; then
    ENV_ARGS=(--env-file "$ENV_FILE")
    log "Используем env-файл: $ENV_FILE"
  elif [[ "$ENV_FILE_USER_SET" == "true" ]]; then
    log "Указанный env-файл не найден: $ENV_FILE (пропускаем)"
  fi
}

# Собираем итоговый набор аргументов (env + compose-файлы).
build_base_args() {
  COMPOSE_BASE_ARGS=("${ENV_ARGS[@]}" "${COMPOSE_ARGS[@]}")
}

# Если запускаем up, предварительно удаляем старые контейнеры (rm --stop --force).
stop_existing_stack() {
  local primary_cmd="$1"
  if [[ "$primary_cmd" != "up" ]]; then
    return
  fi

  log "Удаляем контейнеры перед запуском (force stop): ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} rm --stop --force"
  if ! "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" rm --stop --force; then
    log "Предварительный rm завершился с ошибкой, продолжаем выполнение"
  fi
}

# Многократный запуск (для up): по умолчанию 3 попытки с задержкой.
run_with_retries() {
  local attempts="$RETRY_COUNT"
  local delay="$RETRY_DELAY"

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    log "Попытка ${attempt}/${attempts}: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} $*"
    if "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"; then
      return 0
    fi

    # Проверяем и убираем unhealthy между ретраями, чтобы не тащить битые контейнеры дальше
    remove_unhealthy_containers

    if (( attempt < attempts )); then
      log "Попытка ${attempt} неудачна, повтор через ${delay}с"
      sleep "$delay"
    fi
  done

  log "Команда не удалась после ${attempts} попыток"
  return 1
}

remove_unhealthy_containers() {
  # Ищем только в текущем стеке (compose ps) и удаляем контейнеры со статусом unhealthy.
  if ! command -v awk >/dev/null 2>&1; then
    log "WARN: awk недоступен, пропускаем удаление unhealthy контейнеров"
    return
  fi

  local lines
  if ! lines=$("${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" ps --format "table {{.Name}}\t{{.Health}}" 2>/dev/null); then
    log "WARN: Не удалось получить список контейнеров для проверки здоровья"
    return
  fi

  mapfile -t UNHEALTHY < <(echo "$lines" | tail -n +2 | awk '$2=="unhealthy"{print $1}')
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

validate_configs() {
  local primary_cmd="$1"
  if [[ "$primary_cmd" != "up" ]]; then
    return
  fi

  log "Проверяем конфигурацию: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} config"
  if ! output=$("${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" config >/dev/null 2>&1); then
    log "ERROR: Найдены ошибки в конфигурации compose:"
    echo "$output" >&2
    exit 1
  fi
}

pull_images_if_needed() {
  local primary_cmd="$1"
  if [[ "$primary_cmd" != "up" || "$PULL_BEFORE_UP" == "0" ]]; then
    return
  fi

  log "Проверяем обновления образов: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} pull --quiet"
  if ! "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" pull --quiet; then
    log "WARN: Не удалось обновить образы (pull), продолжаем без обновления"
  fi
}

main() {
  pick_compose_dir
  log "Каталог с compose-файлами: $ACTIVE_COMPOSE_DIR"
  collect_compose_files
  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    log "В каталоге $ACTIVE_COMPOSE_DIR нет файлов compose (*.yml или *.yaml)"
    exit 1
  fi

  pick_compose_command
  build_compose_args
  configure_env_args
  build_base_args

  # По умолчанию выполняем up -d, если пользователь не передал аргументы.
  if [[ $# -eq 0 ]]; then
    set -- up -d
  fi

  # Явный down: прокидываем как есть.
  if [[ "$1" == "down" ]]; then
    log "Остановка стека: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} $*"
    exec "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"
  fi

  # Точный перезапуск одного/нескольких сервисов без остановки всего стека.
  if [[ "$1" == "restart" ]]; then
    shift
    if [[ $# -lt 1 ]]; then
      log "ERROR: Для restart нужно указать имя сервиса(ов)"
      exit 1
    fi

    local last_svc=""
    for svc in "$@"; do
      last_svc="$svc"
      log "Перезапуск сервиса (rm --stop --force): $svc"
      if ! "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" rm --stop --force "$svc"; then
        log "WARN: Не удалось удалить контейнер $svc, продолжаем"
      fi
      log "Запуск сервиса: $svc"
      if ! "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" up -d "$svc"; then
        log "ERROR: Не удалось поднять сервис $svc"
        exit 1
      fi
    done

    log "Показываем логи сервиса $last_svc (Ctrl+C для выхода)"
    exec docker logs -f "$last_svc"
  fi

  validate_configs "$1"
  pull_images_if_needed "$1"
  stop_existing_stack "$1"

  if [[ "$1" == "up" ]]; then
    if run_with_retries "$@"; then
      exit 0
    else
      remove_unhealthy_containers
      exit 1
    fi
    exit 0
  fi

  log "Запуск: ${COMPOSE_CMD[*]} ${COMPOSE_BASE_ARGS[*]} $*"
  exec "${COMPOSE_CMD[@]}" "${COMPOSE_BASE_ARGS[@]}" "$@"
}

main "$@"
