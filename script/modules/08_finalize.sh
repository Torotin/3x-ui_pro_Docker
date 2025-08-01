#!/bin/bash
# ./lib/08_finalize.sh — Финальный вывод настроек и сохранение в файл

msg_final() {
    local summary_file="$PROJECT_ROOT/install.summary"
    local template_file="$PROJECT_ROOT/template/install.summary.template"
    : > "$summary_file"

    log "SEP"
    log "WARN" "Installation complete. Summary of key configuration:"
    log "SEP"

    # Вычисление условий
    [[ -n "$PORT_REMOTE_SSH" && -n "$USER_SSH" ]] && SSH_ENABLED=true || SSH_ENABLED=false
    [[ -n "$PUBLIC_IPV6" && "$PUBLIC_IPV6" != "::" && "$PUBLIC_IPV6" != "$PUBLIC_IPV4" ]] && IPV6_ENABLED=true || IPV6_ENABLED=false

    render_template_with_conditions "$template_file" "$summary_file"

    while IFS= read -r line; do
        [[ -n "$line" ]] && log "INFO" "$line" || log "SEP"
    done < "$summary_file"
}


render_template_with_conditions() {
    local template="$1"
    local output="$2"

    local SSH_ENABLED="${SSH_ENABLED:-false}"
    local IPV6_ENABLED="${IPV6_ENABLED:-false}"

    # Экранируем значения для безопасной подстановки
    escape_sed() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

    local esc_PORT_REMOTE_SSH=$(escape_sed "$PORT_REMOTE_SSH")
    local esc_USER_SSH=$(escape_sed "$USER_SSH")
    local esc_msg_pubkey_auth=$(escape_sed "${msg_pubkey_auth:-unspecified}")
    local esc_PUBLIC_IPV4=$(escape_sed "$PUBLIC_IPV4")
    local esc_PUBLIC_IPV6=$(escape_sed "$PUBLIC_IPV6")
    local esc_WEBDOMAIN=$(escape_sed "$WEBDOMAIN")
    local esc_URI_PANEL_PATH=$(escape_sed "$URI_PANEL_PATH")
    local esc_URI_JSON_PATH=$(escape_sed "$URI_JSON_PATH")
    local esc_URI_SUB_PATH=$(escape_sed "$URI_SUB_PATH")
    local esc_URI_CORSA=$(escape_sed "$URI_CORSA")
    local esc_URI_DOZZLE=$(escape_sed "$URI_DOZZLE")
    local esc_DOCKER_DIR=$(escape_sed "$DOCKER_DIR")
    local esc_summary_file=$(escape_sed "$output")

    # Этап 1: убрать неактивные блоки через awk
    awk -v ssh="$SSH_ENABLED" -v ipv6="$IPV6_ENABLED" '
    BEGIN { skip = 0 }
    /^\{\{#if SSH_ENABLED\}\}/ { if (ssh != "true") skip = 1; next }
    /^\{\{#if IPV6_ENABLED\}\}/ { if (ipv6 != "true") skip = 1; next }
    /^\{\{else\}\}/ { skip = !skip; next }
    /^\{\{\/if\}\}/ { skip = 0; next }
    skip == 0 { print }
    ' "$template" |

    # Этап 2: подставить переменные через sed
    sed -e "s#{{PORT_REMOTE_SSH}}#${esc_PORT_REMOTE_SSH}#g" \
        -e "s#{{USER_SSH}}#${esc_USER_SSH}#g" \
        -e "s#{{msg_pubkey_auth}}#${esc_msg_pubkey_auth}#g" \
        -e "s#{{PUBLIC_IPV4}}#${esc_PUBLIC_IPV4}#g" \
        -e "s#{{PUBLIC_IPV6}}#${esc_PUBLIC_IPV6}#g" \
        -e "s#{{WEBDOMAIN}}#${esc_WEBDOMAIN}#g" \
        -e "s#{{URI_PANEL_PATH}}#${esc_URI_PANEL_PATH}#g" \
        -e "s#{{URI_JSON_PATH}}#${esc_URI_JSON_PATH}#g" \
        -e "s#{{URI_SUB_PATH}}#${esc_URI_SUB_PATH}#g" \
        -e "s#{{URI_CORSA}}#${esc_URI_CORSA}#g" \
        -e "s#{{URI_DOZZLE}}#${esc_URI_DOZZLE}#g" \
        -e "s#{{DOCKER_DIR}}#${esc_DOCKER_DIR}#g" \
        -e "s#{{summary_file}}#${esc_summary_file}#g" \
        > "$output"
}
