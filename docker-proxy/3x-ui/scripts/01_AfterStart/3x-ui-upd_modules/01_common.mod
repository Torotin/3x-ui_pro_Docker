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
