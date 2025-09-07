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

have() { command -v "$1" >/dev/null 2>&1; }

# Startup context
log INFO "Entrypoint started (pid $$)"
log INFO "User: $(id -u 2>/dev/null):$(id -g 2>/dev/null) $(id -un 2>/dev/null || echo unknown)/$(id -gn 2>/dev/null || echo unknown)"
log INFO "Kernel: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
if [ -f /etc/alpine-release ]; then
  log INFO "Alpine: $(cat /etc/alpine-release)"
fi
log INFO "Config: /etc/traefik/traefik.yml | ACME: /acme.json | Templates: /templates -> /dynamic"
log INFO "LOGLEVEL=${LOGLEVEL:-INFO} RENDER_DELAY=${RENDER_DELAY:-2} TZ=${TZ:-unset}"

if have traefik; then
  log INFO "Traefik bin: $(command -v traefik)"
  (traefik version 2>/dev/null || traefik --version 2>/dev/null || true) | sed 's/^/    /' || true
else
  log ERROR "traefik binary not found in PATH"
fi

# — проверим нужные утилиты и при отсутствии установим —
if command -v apk >/dev/null 2>&1; then
  # проверяем зависимости и собираем недостающие пакеты
  missing=$(for pair in envsubst:gettext inotifywait:inotify-tools; do
    cmd=${pair%%:*}; pkg=${pair#*:}
    command -v "$cmd" >/dev/null 2>&1 || printf '%s ' "$pkg"
  done)

  # ставим только если что-то не хватает
  [ -n "$missing" ] && { log INFO "Installing missing tools: $missing"; apk add --no-cache $missing; }
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
  if command -v sha256sum >/dev/null 2>&1; then
    for g in "$tmp"/*.yml; do
      [ -e "$g" ] || continue
      log DEBUG "SHA256 $(basename "$g"): $(sha256sum "$g" | awk '{print $1}')"
    done
  fi
  log DEBUG "Updating existing dynamic dir in place"
  # убедимся, что папка есть
  mkdir -p "$dst"
  # удаляем старые файлы и папки внутри (но не сам dst)
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  # перемещаем все свежесгенерированные файлы
  mv -f "$tmp"/* "$dst"/
  # и удаляем временный
  rmdir "$tmp"
  if command -v ls >/dev/null 2>&1; then
    log INFO "Dynamic files in $dst:"
    ls -l "$dst" | sed 's/^/    /'
  fi
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

# Error trap for unexpected failures
on_err() {
  ec=$?
  log ERROR "Entrypoint failed at line ${1:-unknown} with code $ec"
}
trap 'on_err $LINENO' ERR

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
log INFO "Preparing ACME file permissions"
chmod 600 /acme.json || log WARN "Failed to chmod /acme.json"
if command -v ls >/dev/null 2>&1; then
  ls -l /acme.json | sed 's/^/    /'
fi
if [ -f /etc/traefik/traefik.yml ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    log INFO "traefik.yml SHA256: $(sha256sum /etc/traefik/traefik.yml | awk '{print $1}')"
  fi
else
  log ERROR "/etc/traefik/traefik.yml not found"
fi
log INFO "Starting Traefik: traefik --configFile=/etc/traefik/traefik.yml"
traefik --configFile=/etc/traefik/traefik.yml &
traefik_pid=$!
log INFO "Traefik PID: $traefik_pid"

# Quick bind checks for common entrypoints
check_bind() {
  host="${1:-127.0.0.1}"
  port="$2"
  label="$3"
  timeout="${4:-15}"
  i=0
  while ! nc -z "$host" "$port" 2>/dev/null; do
    i=$((i+1))
    [ "$i" -ge "$timeout" ] && { log WARN "$label port $host:$port not open after ${timeout}s"; return 1; }
    sleep 1
  done
  log INFO "$label port $host:$port is open"
}

# These may or may not be configured; logs clarify either way
check_bind 127.0.0.1 80    "entryPoint web"      || true
check_bind 127.0.0.1 4443  "entryPoint websecure" || true
check_bind 127.0.0.1 443   "entryPoint l4"        || true

if command -v ss >/dev/null 2>&1; then
  log INFO "Listening sockets (ss):"
  ss -ltnup 2>/dev/null | sed 's/^/    /' || true
elif command -v netstat >/dev/null 2>&1; then
  log INFO "Listening sockets (netstat):"
  netstat -tuln 2>/dev/null | sed 's/^/    /' || true
fi

# — ждём завершения Traefik (или сигнала) —
wait "$traefik_pid"; rc=$?
log INFO "Traefik process $traefik_pid exited with code $rc"
exit "$rc"
