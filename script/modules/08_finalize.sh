#!/usr/bin/env bash
# lib/render.sh — универсальный движок шаблонов на bash + awk

render_template() {
  local tpl="$1"
  local out="${2:-/dev/stdout}"

  awk '
    BEGIN { skip = 0 }
    # хелпер: получить окружение
    function getenv(n,   v) {
      v = ENVIRON[n]
      return (v == "" ? "" : v)
    }
    {
      # 1) Обработка {{#if VAR}}
      if ($0 ~ /^\{\{#if[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\}\}$/) {
        match($0, /^\{\{#if[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\}\}$/, m)
        val = getenv(m[1])
        if (val == "" || val == "false") skip = 1
        else skip = 0
        next
      }
      # 2) {{else}} / {{/if}}
      if ($0 == "{{else}}") { skip = !skip; next }
      if ($0 == "{{/if}}")  { skip = 0;      next }
      if (skip) next

      line = $0
      out_line = ""

      # 3) Подстановка {{VAR:-default}} и {{VAR}}
      while (match(line, /\{\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]+)?\}\}/)) {
        token  = substr(line, RSTART, RLENGTH)
        prefix = substr(line, 1, RSTART-1)
        suffix = substr(line, RSTART+RLENGTH)

        # внутри без {{ }}
        inner = token; sub(/^\{\{/, "", inner); sub(/\}\}$/, "", inner)

        # разбиваем на имя и дефолт по ":-"
        split(inner, parts, ":-")
        name  = parts[1]
        defval = ""
        if (length(parts) > 1) defval = parts[2]

        value = getenv(name)
        if (value == "") value = defval

        out_line = out_line prefix value
        line     = suffix
      }
      # остаток строки
      out_line = out_line line
      print out_line
    }
  ' "$tpl" > "$out"
}


# Пример: финальная функция
msg_final() {
    local PROJECT_ROOT="${PROJECT_ROOT:-.}"
    local tpl="$PROJECT_ROOT/template/install.summary.template"
    local out="$PROJECT_ROOT/install.summary"

    : > "$out"

    log "WARN" "Installation complete. Summary of key configuration:"

  export SSH_ENABLED=$(
    [[ -n "$PORT_REMOTE_SSH" && -n "$USER_SSH" ]] && echo true || echo false
  )
  export IPV6_ENABLED=$(
    [[ -n "$PUBLIC_IPV6" && "$PUBLIC_IPV6" != "::" && "$PUBLIC_IPV6" != "$PUBLIC_IPV4" ]] \
      && echo true || echo false
  )

    render_template "$tpl" "$out"

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
        log "INFO" "$line"
        fi
    done < "$out"
}
