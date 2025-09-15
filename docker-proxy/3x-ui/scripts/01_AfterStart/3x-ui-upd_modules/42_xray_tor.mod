update_xray_tor() {
    # Добавляем SOCKS outbound на tor-proxy:9150 и правило маршрутизации для .onion

    TAG_TOR="tor-proxy"
    HOST="tor-proxy"
    PORT=9150

    # 1) Добавим outbound socks -> tor-proxy:9150, если его нет
    if nc -z -w2 "$HOST" "$PORT" 2>/dev/null; then
        exists_tor=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" --arg host "$HOST" --argjson port "$PORT" '
            [.xraySetting.outbounds[]? | select(.tag==$tag and .protocol=="socks" and .settings.servers[0]?.address==$host and (.settings.servers[0]?.port|tonumber)==$port)] | length')
        if [ "${exists_tor:-0}" -eq 0 ]; then
            new_tor_ob=$(jq -nc --arg tag "$TAG_TOR" --arg host "$HOST" --argjson port "$PORT" '{
                tag:$tag, protocol:"socks", settings:{ servers:[{ address:$host, port:$port }] }
            }')
            XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson ob "$new_tor_ob" '
                .xraySetting.outbounds = (.xraySetting.outbounds // []) |
                .xraySetting.outbounds += [$ob]')
            log INFO "Outbound '$TAG_TOR' -> ${HOST}:${PORT} добавлен."
        else
            log INFO "Outbound '$TAG_TOR' уже присутствует."
        fi
    else
        log WARN "Хост ${HOST}:${PORT} недоступен - outbound '$TAG_TOR' не будет добавлен."
    fi

    # 2) Добавим/обновим routing-правило: все .onion через outboundTag=tor-proxy
    desired_domains=$(jq -nc '["domain:onion"]')

    XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq '
        .xraySetting.routing = (.xraySetting.routing // {}) |
        .xraySetting.routing.rules = (.xraySetting.routing.rules // [])')

    has_tor_rule=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" 'any(.xraySetting.routing.rules[]?; .type=="field" and .outboundTag==$tag)')
    if [ "$has_tor_rule" = "true" ]; then
        XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" --argjson dom "$desired_domains" '
            .xraySetting.routing.rules |= map(
              if .type=="field" and .outboundTag==$tag then
                .domain = (((.domain // []) + $dom) | unique)
              else . end)')
        log INFO "Routing-правило для outboundTag=$TAG_TOR обновлено."
    else
        new_rule=$(jq -nc --arg tag "$TAG_TOR" --argjson dom "$desired_domains" '{ type:"field", outboundTag:$tag, domains:$dom }')
        # Препендим правило, чтобы оно имело приоритет
        XRAY_SETTINGS_JSON=$(echo "$XRAY_SETTINGS_JSON" | jq --argjson rule "$new_rule" '
            .xraySetting.routing.rules = [$rule] + (.xraySetting.routing.rules // [])')
        log INFO "Добавлено routing-правило для .onion через outboundTag=$TAG_TOR."
    fi

    export XRAY_SETTINGS_JSON
}
