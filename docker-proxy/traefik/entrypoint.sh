#!/bin/sh
set -eu

# ——— Логирование с уровнями и цветами ———
log() {
    level=$1; shift
    # убираем пробелы, по умолчанию INFO
    level=$(printf '%s' "$level" | tr -d '[:space:]')
    [ -z "$level" ] && level=INFO

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        ERROR) current=1 ;;
        WARN*) current=2 ;;
        INFO)  current=3 ;;
        DEBUG) current=4 ;;
        *)     current=3 ;;
    esac

    case "${LOGLEVEL:-INFO}" in
        ERROR) active=1 ;;
        WARN*) active=2 ;;
        INFO)  active=3 ;;
        DEBUG) active=4 ;;
        *)     active=3 ;;
    esac

    [ "$current" -gt "$active" ] && return

    case "$level" in
        INFO)  color='\033[1;34m' ;;
        WARN*) color='\033[1;33m' ;;
        ERROR) color='\033[1;31m' ;;
        DEBUG) color='\033[1;36m' ;;
        *)     color='\033[0m' ;;
    esac
    reset='\033[0m'

    printf '%s %b%s%b - %s\n' \
      "$timestamp" "$color" "$level" "$reset" "$*" >&2
}

# ——— Установка зависимостей ———
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache gettext inotify-tools
fi

# ——— Рендеринг шаблонов (атомарный swap) ———
render() {
    src=/templates
    dst=/dynamic
    tmp=$(mktemp -d "${dst}.tmp.XXXXXX")

    log INFO "Rendering templates into $tmp…"
    for tmpl in "$src"/*.yml; do
        [ -f "$tmpl" ] || continue
        name=$(basename "$tmpl")
        if ! envsubst < "$tmpl" > "$tmp/$name"; then
            log ERROR "Rendering failed for $tmpl"
            rm -rf "$tmp"
            return 1
        fi
    done

    rm -rf "$dst"
    mv "$tmp" "$dst"
    log INFO "Render complete — now serving $dst"
}

# ——— Обработчик сигналов ———
cleanup() {
    log INFO "Signal received, shutting down watcher"
    [ -n "${watcher_pid:-}" ] && kill "$watcher_pid" 2>/dev/null || :
    [ -n "${timer_pid:-}"   ] && kill "$timer_pid"   2>/dev/null || :
    exit 0
}
trap 'cleanup' INT TERM

# ——— Первый рендер ———
render

# ——— Наблюдение за /templates с дебаунсом ———
DELAY=${RENDER_DELAY:-2}
log INFO "Watching /templates (debounce=${DELAY}s)…"
inotifywait -qm -e create,close_write,delete,move --format '%f' /templates | \
while read file; do
    log DEBUG "Change detected: $file, scheduling render in ${DELAY}s…"
    [ -n "${timer_pid:-}" ] && kill "$timer_pid" 2>/dev/null || :
    (
        sleep "$DELAY"
        log INFO "Debounce elapsed — re-rendering"
        render
    ) &
    timer_pid=$!
done &
watcher_pid=$!

# ——— Запуск Traefik как PID 1 ———
chmod 600 /acme.json
exec traefik --configFile=/etc/traefik/traefik.yml
