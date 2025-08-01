#!/bin/sh
set -eu

# ——— Логирование ———
log() {
  printf '[entrypoint %s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

# ——— Установка зависимостей ———
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache gettext inotify-tools
fi

# ——— Функция рендеринга (атомарный swap) ———
render() {
  local src="/templates" dst="/dynamic" tmp
  tmp="$(mktemp -d "${dst}.tmp.XXXXXX")"
  log "Rendering templates into $tmp …"
  for tmpl in "$src"/*.yml; do
    [ -f "$tmpl" ] || continue
    name="$(basename "$tmpl")"
    if ! envsubst < "$tmpl" > "$tmp/$name"; then
      log "ERROR" "Failed to render $tmpl"
      rm -rf "$tmp"
      return 1
    fi
  done
  # Меняем директорию целиком
  rm -rf "$dst" && mv "$tmp" "$dst"
  log "Render complete — now serving $dst"
}

# ——— Первый рендер ———
render

# ——— Следим за изменениями и дебаунсим рендер ———
DELAY="${RENDER_DELAY:-2}"
log "Watching /templates (debounce=${DELAY}s)…"
inotifywait -qm \
  -e create,close_write,delete,move \
  --format '%f' /templates | \
while read -r file; do
  log "Change detected: $file, scheduling render in ${DELAY}s…"
  [ -n "${timer:-}" ] && kill "$timer" 2>/dev/null || :
  (
    sleep "$DELAY"
    log "Debounce elapsed — re-rendering"
    render
  ) &
  timer=$!
done &

# ——— Запускаем Traefik как PID 1 ———
exec traefik --configFile=/etc/traefik/traefik.yml
