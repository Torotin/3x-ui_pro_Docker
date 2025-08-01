#!/bin/sh
set -eu -o pipefail

# — логирование —
log() {
  level="${1:-INFO}"; shift
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    ERROR) pri=1; color='\033[1;31m' ;;
    WARN*) pri=2; color='\033[1;33m' ;;
    INFO)  pri=3; color='\033[1;34m' ;;
    DEBUG) pri=4; color='\033[1;36m' ;;
    *)     pri=3; color='\033[0m' ;;
  esac
  case "${LOGLEVEL:-INFO}" in
    ERROR) act=1 ;;
    WARN*) act=2 ;;
    INFO)  act=3 ;;
    DEBUG) act=4 ;;
    *)     act=3 ;;
  esac
  [ "$pri" -gt "$act" ] && return
  printf '%s %b%s%b - %s\n' "$timestamp" "$color" "$level" '\033[0m' "$*" >&2
}

# — проверим нужные утилиты и при отсутствии установим —
if command -v apk >/dev/null 2>&1; then
  # проверяем зависимости и собираем недостающие пакеты
  missing=$(for pair in envsubst:gettext inotifywait:inotify-tools; do
    cmd=${pair%%:*}; pkg=${pair#*:}
    command -v "$cmd" >/dev/null 2>&1 || printf '%s ' "$pkg"
  done)

  # ставим только если что-то не хватает
  [ -n "$missing" ] && apk add --no-cache $missing
fi

# — атомарный рендер —
render() {
  src=/templates
  dst=/dynamic
  tmp=$(mktemp -d /tmp/tmp.XXXXXX)
  log INFO "Rendering templates…"
  for f in "$src"/*.yml; do
    envsubst <"$f" >"$tmp/$(basename "$f")"
  done
  log DEBUG "Updating existing dynamic dir in place"
  # убедимся, что папка есть
  mkdir -p "$dst"
  # удаляем старые файлы и папки внутри (но не сам dst)
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  # перемещаем все свежесгенерированные файлы
  mv -f "$tmp"/* "$dst"/
  # и удаляем временный
  rmdir "$tmp"
}

# — общие переменные —
watcher_pid=
timer_pid=
traefik_pid=

# — централизованный cleanup —
cleanup() {
  log INFO "Shutting down…"
  [ -n "$timer_pid"   ] && kill "$timer_pid"   2>/dev/null || :
  [ -n "$watcher_pid" ] && kill "$watcher_pid" 2>/dev/null || :
  [ -n "$traefik_pid" ] && kill -TERM "$traefik_pid" 2>/dev/null || :
  exit 0
}
trap 'cleanup' INT TERM

# — дождаться Crowdsec с таймаутом 60 сек —
log INFO "Waiting for Crowdsec…"
timeout=60
i=0
while ! nc -z crowdsec 8080; do
  i=$((i+1))
  [ "$i" -ge "$timeout" ] && {
    log ERROR "Crowdsec did not start within ${timeout}s"
    exit 1
  }
  sleep 1
done
log INFO "Crowdsec is up"

# — первый рендер —
render

# — watcher на шаблоны с debounce —
inotifywait -qm -e create,close_write,delete,move --format '%f' /templates | \
while read -r file; do
  log INFO "Detected change in template: $file"    # ← вот эта строка
  [ -n "$timer_pid" ] && kill "$timer_pid" 2>/dev/null || :
  (
    sleep "${RENDER_DELAY:-2}"
    log INFO "Debounce elapsed, re-rendering (triggered by $file)"
    render
    if [ -f "$dst/$file" ]; then
        log INFO "===== BEGIN rendered $file ====="
        sed 's/^/    /' "$dst/$file"
        log INFO "=====  END  rendered $file ====="
    else
        log WARN "$file not found in $dst"
    fi
  ) & timer_pid=$!
done &
watcher_pid=$!

# — запускаем Traefik —
chmod 600 /acme.json
traefik --configFile=/etc/traefik/traefik.yml &
traefik_pid=$!

# — ждём завершения Traefik (или сигнала) —
wait "$traefik_pid"
