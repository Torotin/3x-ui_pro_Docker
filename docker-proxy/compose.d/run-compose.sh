#!/bin/bash
# Запускает docker compose для всех *.yml/*.yaml в каталоге compose.d (если он есть) или рядом со скриптом (по алфавиту).
# Логика: 
# 1) выбираем каталог с файлами (compose.d или текущий);
# 2) собираем и сортируем файлы compose;
# 3) выбираем доступную CLI (docker compose или docker-compose);
# 4) формируем цепочку -f;
# 5) если аргументы не заданы, используем up -d;
# 6) перед запуском останавливаем текущий стек (down);
# 7) делаем до 3 попыток запуска (параметры RETRY_COUNT/RETRY_DELAY);
# 8) исполняем получившуюся команду.
# Пример итоговой команды:
#   docker compose -f "/path/compose.d/00 - base.yml" -f "/path/compose.d/01 - watchtower.yml" up -d
# Пример с docker-compose и пользовательскими аргументами:
#   docker-compose -f "/path/compose.d/00 - base.yml" -f "/path/compose.d/01 - watchtower.yml" ps
# Примеры запуска:
#   ./run-compose.sh               # up -d с тремя попытками, перед этим down
#   RETRY_COUNT=5 ./run-compose.sh # up -d с 5 попытками
#   ./run-compose.sh ps            # любая другая команда выполняется один раз

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/compose.d"
ACTIVE_COMPOSE_DIR="$SCRIPT_DIR"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

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

# Если запускаем up, предварительно останавливаем стек.
stop_existing_stack() {
  local primary_cmd="$1"
  if [[ "$primary_cmd" != "up" ]]; then
    return
  fi

  log "Останавливаем стек перед запуском: ${COMPOSE_CMD[*]} ${COMPOSE_ARGS[*]} down"
  if ! "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" down; then
    log "Предварительный down завершился с ошибкой, продолжаем выполнение"
  fi
}

# Многократный запуск (для up): по умолчанию 3 попытки с задержкой.
run_with_retries() {
  local attempts="$RETRY_COUNT"
  local delay="$RETRY_DELAY"

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    log "Попытка ${attempt}/${attempts}: ${COMPOSE_CMD[*]} ${COMPOSE_ARGS[*]} $*"
    if "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" "$@"; then
      return 0
    fi

    if (( attempt < attempts )); then
      log "Попытка ${attempt} неудачна, повтор через ${delay}с"
      sleep "$delay"
    fi
  done

  log "Команда не удалась после ${attempts} попыток"
  return 1
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

  # По умолчанию выполняем up -d, если пользователь не передал аргументы.
  if [[ $# -eq 0 ]]; then
    set -- up -d
  fi

  stop_existing_stack "$1"

  if [[ "$1" == "up" ]]; then
    run_with_retries "$@" || exit 1
    exit 0
  fi

  log "Запуск: ${COMPOSE_CMD[*]} ${COMPOSE_ARGS[*]} $*"
  exec "${COMPOSE_CMD[@]}" "${COMPOSE_ARGS[@]}" "$@"
}

main "$@"
