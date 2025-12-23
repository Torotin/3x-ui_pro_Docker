#!/bin/bash
update_xray_tor() {
    # Добавляем SOCKS outbound на tor-proxy:9050 и правило маршрутизации для .onion

    TAG_TOR="tor-proxy"
    HOST="tor-proxy"
    PORT=9050

    # 0) Удаляем все существующие outbounds с тегом или адресом tor-proxy
    removed_tor=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" --arg host "$HOST" '
        .xraySetting.outbounds // [] |
        map(select(
            .tag==$tag
            or any(.settings.servers[]?; .address==$host)
            or any(.settings.vnext[]?; .address==$host)
            or (.settings.address?==$host)
        )) | length')
    XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" --arg host "$HOST" '
        .xraySetting.outbounds = ((.xraySetting.outbounds // []) | map(select(
            (.tag==$tag
             or any(.settings.servers[]?; .address==$host)
             or any(.settings.vnext[]?; .address==$host)
             or (.settings.address?==$host)) | not
        )))')
    if [ "${removed_tor:-0}" -gt 0 ]; then
        log INFO "Удалены старые outbounds с тегом '$TAG_TOR' или адресом '$HOST': $removed_tor"
    fi

    # 1) Добавляем свежий socks-outbound на tor-proxy:9050 (только если хост доступен)
    if nc -z -w2 "$HOST" "$PORT" 2>/dev/null; then
        new_tor_ob=$(jq -nc --arg tag "$TAG_TOR" --arg host "$HOST" --argjson port "$PORT" '{
            tag:$tag, protocol:"socks", settings:{ servers:[{ address:$host, port:$port }] }
        }')
        XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --argjson ob "$new_tor_ob" '
            .xraySetting.outbounds = (.xraySetting.outbounds // []) + [$ob]')
        log INFO "Outbound '$TAG_TOR' -> ${HOST}:${PORT} добавлен."
    else
        log WARN "Хост ${HOST}:${PORT} недоступен - outbound '$TAG_TOR' не будет добавлен."
    fi

    # 2) Добавим/обновим routing-правило: все .onion через outboundTag=tor-proxy
    desired_domains=$(jq -nc '[
        "domain:onion",
        "domain:torproject.org",
        "domain:ntc.party"
    ]')


    XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq '
        .xraySetting.routing = (.xraySetting.routing // {}) |
        .xraySetting.routing.rules = (.xraySetting.routing.rules // [])')

    has_tor_rule=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" 'any(.xraySetting.routing.rules[]?; .type=="field" and .outboundTag==$tag)')
    if [ "$has_tor_rule" = "true" ]; then
        XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --arg tag "$TAG_TOR" --argjson dom "$desired_domains" '
            .xraySetting.routing.rules |= map(
              if .type=="field" and .outboundTag==$tag then
                .domain = (((.domain // .domains // []) + $dom) | unique)
                | del(.domains)
              else . end)')
        log INFO "Routing-правило для outboundTag=$TAG_TOR обновлено."
    else
        new_rule=$(jq -nc --arg tag "$TAG_TOR" --argjson dom "$desired_domains" '{ type:"field", outboundTag:$tag, domain:$dom }')
        # Препендим правило, чтобы оно имело приоритет
        XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --argjson rule "$new_rule" '
            .xraySetting.routing.rules = [$rule] + (.xraySetting.routing.rules // [])')
        log INFO "Добавлено routing-правило для .onion через outboundTag=$TAG_TOR."
    fi

    export XRAY_SETTINGS_JSON
}
