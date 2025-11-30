#!/bin/bash
# Определение флага страны по IP (POSIX совместимо)
detect_country_flag() {
    log INFO "Определение флага страны по IP."
    EMOJI_FLAG="⚠"  # значение по умолчанию

    CURL_OPTS="-sS --fail --location --retry 1 --connect-timeout 2 --max-time 4 -H Accept:application/json"

    # Источники: URL + jq-путь
    for entry in \
        "https://ipwho.is/|.flag.emoji" \
        "https://ipwhois.io/json/|.country_flag_emoji"
    do
        src=${entry%%|*}
        jqpath=${entry#*|}

        resp=$(curl $CURL_OPTS "$src") || {
            log WARN "$src: запрос не удался."
            continue
        }

        printf '%s' "$resp" | jq -e . >/dev/null 2>&1 || {
            log WARN "$src: ответ не валидный JSON."
            continue
        }

        emoji=$(printf '%s' "$resp" | jq -r "$jqpath // empty" 2>/dev/null || true)
        if [ -n "$emoji" ]; then
            EMOJI_FLAG="$emoji"
            log INFO "Флаг страны ($src): $EMOJI_FLAG"
            return 0
        else
            log WARN "$src: поле $jqpath пустое."
        fi
    done

    log WARN "Флаг страны не определён, используем ⚠."
    return 1
}


gen_rand_str() {
    length="${1:-8}"
    # urandom может не быть, но на Alpine всегда есть
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_short_ids() {
    # $1 — count, $2 — max_size (default: 8, 8)
    count="${1:-8}"
    max_size="${2:-8}"
    i=1
    result=""
    while [ "$i" -le "$count" ]; do
        # Рандомная длина от 2 до max_size
        if command -v od >/dev/null 2>&1; then
            len=$(od -An -N1 -tu1 < /dev/urandom | tr -d ' ' || echo 2)
            # len ∈ [0..255], приводим к [2..max_size]
            len=$((2 + len % (max_size - 1)))
        else
            len=6 # fallback если нет od
        fi

        # Генерируем hex строки выбранной длины
        if command -v openssl >/dev/null 2>&1; then
            hex="$(openssl rand -hex "$len" 2>/dev/null)"
        elif command -v xxd >/dev/null 2>&1; then
            hex="$(head -c "$len" /dev/urandom | xxd -p -c 256)"
        else
            hex="$(head -c "$len" /dev/urandom | od -An -vtx1 | tr -d ' \n')"
        fi

        if [ -n "$result" ]; then
            result="${result},\"$hex\""
        else
            result="\"$hex\""
        fi
        i=$((i + 1))
    done
    echo "[$result]"
}

# --- Enhanced country flag detection helpers and override ---
letter_to_regional() {
    case "$1" in
        A) printf '🇦';; B) printf '🇧';; C) printf '🇨';; D) printf '🇩';; E) printf '🇪';;
        F) printf '🇫';; G) printf '🇬';; H) printf '🇭';; I) printf '🇮';; J) printf '🇯';;
        K) printf '🇰';; L) printf '🇱';; M) printf '🇲';; N) printf '🇳';; O) printf '🇴';;
        P) printf '🇵';; Q) printf '🇶';; R) printf '🇷';; S) printf '🇸';; T) printf '🇹';;
        U) printf '🇺';; V) printf '🇻';; W) printf '🇼';; X) printf '🇽';; Y) printf '🇾';;
        Z) printf '🇿';; *) return 1;;
    esac
}

cc_to_emoji() {
    code=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    c1=$(printf '%s' "$code" | cut -c1)
    c2=$(printf '%s' "$code" | cut -c2)
    [ "${#code}" -ge 2 ] || return 1
    e1=$(letter_to_regional "$c1") || return 1
    e2=$(letter_to_regional "$c2") || return 1
    printf '%s%s' "$e1" "$e2"
}

# Override with richer fallback list (defined after original to take precedence)
detect_country_flag() {
    log INFO "Определение флага страны по IP."
    EMOJI_FLAG="⚠"

    CURL_OPTS="-sS --fail --location --retry 1 --connect-timeout 2 --max-time 4 -H Accept:application/json"

    # Вспомогательные функции DoH (DNS over HTTPS) для обхода локального DNS/AdBlock
    doh_resolve_ipv4() {
        host="$1"
        # 1) Google DoH
        body=$(curl -sS --fail --location --connect-timeout 2 --max-time 4 \
                 -H 'accept: application/dns-json' \
                 --resolve 'dns.google:443:8.8.8.8' \
                 "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null) || body=""
        ip=$(printf '%s' "$body" | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1)
        if printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then printf '%s' "$ip"; return 0; fi

        # 2) Cloudflare DoH
        body=$(curl -sS --fail --location --connect-timeout 2 --max-time 4 \
                 -H 'accept: application/dns-json' \
                 --resolve 'cloudflare-dns.com:443:1.1.1.1' \
                 "https://cloudflare-dns.com/dns-query?name=${host}&type=A" 2>/dev/null) || body=""
        ip=$(printf '%s' "$body" | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | head -n1)
        if printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then printf '%s' "$ip"; return 0; fi

        return 1
    }

    http_json_via_doh() {
        url="$1"
        # Разбираем URL на протокол/host/порт
        proto=${url%%://*}
        rest=${url#*://}
        host_port=${rest%%/*}
        path=/${rest#*/}
        case "$host_port" in
            *:*) host=${host_port%%:*}; port=${host_port#*:} ;;
            *)   host=$host_port; port=$([ "$proto" = "https" ] && echo 443 || echo 80) ;;
        esac

        ip=$(doh_resolve_ipv4 "$host") || return 1
        # Выполняем запрос по IP, но с виртуальным хостом через --resolve
        curl $CURL_OPTS --resolve "${host}:${port}:${ip}" "${url}" 2>/dev/null
    }

    # Format: URL|jq-path|kind (kind: emoji|cc)
    for entry in \
        "https://ipwho.is/|.flag.emoji|emoji" \
        "https://ipwhois.io/json/|.country_flag_emoji|emoji" \
        "http://ip-api.com/json/?fields=status,country,countryCode|.countryCode|cc" \
        "https://ifconfig.co/json|.country_iso|cc" \
        "https://api.ip.sb/geoip|.country_code|cc" \
        "https://ipinfo.io/json|.country|cc" \
        "https://ipapi.co/json|.country_code|cc"
    do
        src=${entry%%|*}
        rest=${entry#*|}
        jqpath=${rest%%|*}
        kind=${rest#*|}
        [ "$rest" = "$kind" ] && kind=emoji

        if [ "${DETECT_FLAG_DOH:-1}" != "0" ]; then
            resp=$(http_json_via_doh "$src") || resp=""
            [ -n "$resp" ] || resp=$(curl $CURL_OPTS "$src" 2>/dev/null)
        else
            resp=$(curl $CURL_OPTS "$src" 2>/dev/null)
        fi
        [ -n "$resp" ] || { log WARN "$src: запрос не удался."; continue; }
        printf '%s' "$resp" | jq -e . >/dev/null 2>&1 || { log WARN "$src: ответ не JSON."; continue; }

        val=$(printf '%s' "$resp" | jq -r "$jqpath // empty" 2>/dev/null || true)
        [ -n "$val" ] || { log WARN "$src: поле $jqpath пустое."; continue; }

        if [ "$kind" = "cc" ]; then
            emoji=$(cc_to_emoji "$val" || true)
        else
            emoji="$val"
        fi

        if [ -n "$emoji" ]; then
            EMOJI_FLAG="$emoji"
            log INFO "Флаг страны ($src): $EMOJI_FLAG"
            return 0
        fi
    done

    log WARN "Флаг страны не определён, используем ⚠."
    return 1
}
