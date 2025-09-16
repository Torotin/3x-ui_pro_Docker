#!/bin/sh

# DNS helpers and XRAY dns section update

# Default extra DNS resolvers list (DoH/DoT). You can override with env `XRAY_EXTRA_DNS_LIST`.
EXTRA_DNS_LIST_DEFAULT='
https://dns10.quad9.net/dns-query
quic://dns.alidns.com:853
https://dns.alidns.com/dns-query
https://doh.sandbox.opendns.com/dns-query
https://freedns.controld.com/p0
https://doh.dns.sb/dns-query
https://dns.google/dns-query
https://dns.nextdns.io
https://dns.quad9.net/dns-query
https://dns11.quad9.net/dns-query
https://dns.rabbitdns.org/dns-query
https://basic.rethinkdns.com/
https://wikimedia-dns.org/dns-query
https://doh.libredns.gr/dns-query
https://doh.libredns.gr/ads
https://dns.twnic.tw/dns-query
https://dns.switch.ch/dns-query
tls://dns.alidns.com
tls://sandbox.opendns.com
tls://p0.freedns.controld.com
tls://dot.sb
tls://dns.google
tls://dns.mullvad.net
tls://dns.nextdns.io
tls://dns.quad9.net
tls://dns11.quad9.net
tls://dot.libredns.gr'

# Effective extra list used by update_xray_dns
EXTRA_DNS_LIST="${XRAY_EXTRA_DNS_LIST:-$EXTRA_DNS_LIST_DEFAULT}"

# Detect dig feature support (+https, +tls) once per run
dns_detect_features() {
    if [ -n "$DNS_FEATURES_DETECTED" ]; then
        return 0
    fi
    help=$(dig -h 2>&1 || true)
    case "$help" in
        *" +https "*|*" +nohttps "*|*"https://"*) DIG_HAS_HTTPS=1 ;;
        *) DIG_HAS_HTTPS=0 ;;
    esac
    case "$help" in
        *" +tls "*|*" +notls "*|*"tls://"*) DIG_HAS_TLS=1 ;;
        *) DIG_HAS_TLS=0 ;;
    esac
    DNS_FEATURES_DETECTED=1
}

# Run a dig query and consider it successful if we get any A answers.
# Usage: _dns_dig_query <server_spec> <domain> [extra dig opts...]
_dns_dig_query() {
    server="$1"; domain="$2"; shift 2 || true
    out=$(dig +time=3 +tries=1 @"$server" "$domain" A +short "$@" 2>/dev/null | grep -Eo '(^| )([0-9]{1,3}\.){3}[0-9]{1,3}($| )' || true)
    [ -n "$out" ]
}

# Run a dig query and consider it successful if server replies (any status)
# Usage: _dns_dig_reply <server_spec> <domain> [extra dig opts...]
_dns_dig_reply() {
    server="$1"; domain="$2"; shift 2 || true
    out=$(dig +time=3 +tries=1 @"$server" "$domain" A "$@" 2>/dev/null || true)
    # Success if we see header/status from server (reply received)
    printf '%s' "$out" | grep -q -E '^;; (->>HEADER<<-|Got answer:)' && return 0
    # Explicit timeouts/no servers -> fail
    printf '%s' "$out" | grep -qi 'no servers could be reached' && return 1
    printf '%s' "$out" | grep -qi 'connection timed out' && return 1
    return 1
}

# Check a classic DNS server (UDP first, then TCP) on a host:port
_dns_check_udp_tcp() {
    host="$1"; port="$2"; domain="$3"
    # Prefer explicit -p to avoid '@host#port' incompatibilities
    out=$(dig +time=3 +tries=1 -p "$port" @"$host" "$domain" A +short 2>/dev/null | grep -Eo '(^| )([0-9]{1,3}\.){3}[0-9]{1,3}($| )' || true)
    [ -n "$out" ] && return 0
    out=$(dig +time=3 +tries=1 -p "$port" +tcp @"$host" "$domain" A +short 2>/dev/null | grep -Eo '(^| )([0-9]{1,3}\.){3}[0-9]{1,3}($| )' || true)
    [ -n "$out" ] && return 0
    return 1
}

# Same as _dns_check_udp_tcp but only requires a reply (any status)
_dns_check_udp_tcp_reply() {
    host="$1"; port="$2"; domain="$3"
    _dns_dig_reply "$host#${port}" "$domain" && return 0
    _dns_dig_reply "$host#${port}" "$domain" +tcp && return 0
    # Fallback with explicit -p, in case '@host#port' is not supported
    out=$(dig +time=3 +tries=1 -p "$port" @"$host" "$domain" A 2>/dev/null || true)
    printf '%s' "$out" | grep -q -E '^;; (->>HEADER<<-|Got answer:)' && return 0
    out=$(dig +time=3 +tries=1 -p "$port" +tcp @"$host" "$domain" A 2>/dev/null || true)
    printf '%s' "$out" | grep -q -E '^;; (->>HEADER<<-|Got answer:)' && return 0
    return 1
}

# HTTP JSON fallback for DoH endpoints (Cloudflare-style /dns-query?name=&type=)
_http_check_doh_json() {
    url="$1"; domain="$2"
    # Build query URL
    case "$url" in
        *\?*) q_url="${url}&name=${domain}&type=A" ;;
        *)     q_url="${url}?name=${domain}&type=A" ;;
    esac
    body=$(curl -fsS --connect-timeout 2 --max-time 4 -H 'accept: application/dns-json' "$q_url" 2>/dev/null || true)
    if [ -n "$body" ] && printf '%s' "$body" | jq -e '.Status==0 and (.Answer|type=="array") and ((.Answer|length)>0)' >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Check a DoH endpoint using dig's +https (BIND 9.18+)
_dns_check_doh() {
    url="$1"; domain="$2"
    [ "${DIG_HAS_HTTPS:-0}" = "1" ] || {
        log WARN "dig не поддерживает +https — пропускаю проверку DoH ($url)."
        return 1
    }
    _dns_dig_query "$url" "$domain" +https && return 0
    return 1
}

_dns_check_doh_reply() {
    url="$1"; domain="$2"
    [ "${DIG_HAS_HTTPS:-0}" = "1" ] || return 1
    _dns_dig_reply "$url" "$domain" +https && return 0
    return 1
}

# Check a DoT endpoint using dig's +tls (BIND 9.18+)
_dns_check_dot() {
    host="$1"; port="${2:-853}"; domain="$3"
    [ "${DIG_HAS_TLS:-0}" = "1" ] || {
        log WARN "dig не поддерживает +tls — пропускаю проверку DoT (tls://$host#$port)."
        return 1
    }
    _dns_dig_query "tls://$host#${port}" "$domain" +tls && return 0
    return 1
}

_dns_check_dot_reply() {
    host="$1"; port="${2:-853}"; domain="$3"
    [ "${DIG_HAS_TLS:-0}" = "1" ] || return 1
    _dns_dig_reply "tls://$host#${port}" "$domain" +tls && return 0
    return 1
}

# Decide how to probe a server based on address format and port.
# Arguments: <address> <port-or-empty> <test_domain>
dns_check_server() {
    address="$1"; port="$2"; test_domain="$3"; mode="${4:-records}"
    case "$address" in
        https://*)
            log INFO "Checking DoH DNS: $address"
            # Prefer native dig +https only if supported; otherwise use HTTP JSON without warnings
            if [ "${DIG_HAS_HTTPS:-0}" = "1" ]; then
                if [ "$mode" = "reply" ]; then
                    _dns_check_doh_reply "$address" "$test_domain" && return 0
                else
                    _dns_check_doh "$address" "$test_domain" && return 0
                fi
            fi
            # Fallback via HTTP JSON
            _http_check_doh_json "$address" "$test_domain" && return 0
            return 1
            ;;
        tls://*)
            host_port=${address#tls://}
            host=${host_port%%[:#]*}
            p=${host_port#*$host}
            p=${p##[:#]}
            [ -z "$p" ] && p=${port:-853}
            log INFO "Checking DoT DNS: tls://$host#$p"
            # Only attempt DoT probe if dig supports +tls
            if [ "${DIG_HAS_TLS:-0}" = "1" ]; then
                if [ "$mode" = "reply" ]; then
                    _dns_check_dot_reply "$host" "$p" "$test_domain"
                else
                    _dns_check_dot "$host" "$p" "$test_domain"
                fi
                return $?
            fi
            return $?
            ;;
        *)
            [ -z "$port" ] && port=53
            log INFO "Checking DNS: $address:$port (UDP/TCP)"
            if [ "$mode" = "reply" ]; then
                _dns_check_udp_tcp_reply "$address" "$port" "$test_domain"
            else
                _dns_check_udp_tcp "$address" "$port" "$test_domain"
            fi
            return $?
            ;;
    esac
}

# Build JSON server object via jq
# Usage: dns_build_server_json <address> [port] [skipFallback:true|false] [domains_json]
dns_build_server_json() {
    addr="$1"; prt="$2"; skip="${3:-false}"; domains_json="${4:-}"
    if [ -n "$prt" ]; then
        if [ -n "$domains_json" ]; then
            jq -nc \
               --arg addr "$addr" \
               --argjson port "$prt" \
               --argjson skip "$skip" \
               --argjson domains "$domains_json" \
               '{address:$addr, port:$port, skipFallback:$skip, domains:$domains}'
        else
            jq -nc \
               --arg addr "$addr" \
               --argjson port "$prt" \
               --argjson skip "$skip" \
               '{address:$addr, port:$port, skipFallback:$skip}'
        fi
    else
        if [ -n "$domains_json" ]; then
            jq -nc \
               --arg addr "$addr" \
               --argjson skip "$skip" \
               --argjson domains "$domains_json" \
               '{address:$addr, skipFallback:$skip, domains:$domains}'
        else
            jq -nc \
               --arg addr "$addr" \
               --argjson skip "$skip" \
               '{address:$addr, skipFallback:$skip}'
        fi
    fi
}

# Normalize address for comparison (trim trailing slash for DoH URLs)
_dns_norm_addr() {
    a="$1"
    case "$a" in
        https://*/)
            printf '%s' "${a%/}"
            ;;
        *)
            printf '%s' "$a"
            ;;
    esac
}

# Check if SERVERS_JSON already contains address
_servers_has_address() {
    addr="$1"
    printf '%s' "$SERVERS_JSON" | jq -e --arg a "$addr" 'map(select(.address==$a)) | length>0' >/dev/null 2>&1
}

# Update the .xraySetting.dns section in $XRAY_SETTINGS_JSON based on server availability
update_xray_dns() {
    log INFO "Проверка доступности DNS и обновление XRAY dns."

    dns_detect_features

    TEST_DOMAIN="${TEST_DNS_DOMAIN:-example.com}"
    SERVERS_JSON='[]'
    ADDED_LOCAL_ADGUARD=0

    add_server_if_ok() {
        addr="$1"; port="$2"; skip="$3"; domains_json="$4"; probe_domain="$5"; probe_mode="${6:-records}"
        d="${probe_domain:-$TEST_DOMAIN}"
        # If AdGuard already added, skip any additional servers
        if printf '%s' "$SERVERS_JSON" | jq -e 'any(.[]?; .address=="adguard")' >/dev/null 2>&1; then
            [ "$addr" = "adguard" ] || return 1
        fi
        if dns_check_server "$addr" "$port" "$d" "$probe_mode"; then
            entry=$(dns_build_server_json "$addr" "$port" "$skip" "$domains_json")
            SERVERS_JSON=$(printf '%s' "$SERVERS_JSON" | jq --argjson e "$entry" '. + [$e]')
            return 0
        fi
        return 1
    }

    # 1) tor-proxy for .onion (skipFallback=true)
    TD_ONION="${TEST_DNS_DOMAIN_ONION:-test.onion}"
    if add_server_if_ok "tor-proxy" 8853 true '["regexp:\\.[Oo][Nn][Ii][Oo][Nn]$"]' "$TD_ONION" reply; then
        log INFO "Добавлен DNS tor-proxy:8853 для .onion"
    else
        log WARN "tor-proxy:8853 недоступен — пропускаю."
    fi

    # 2) local AdGuard (port 53)
    if add_server_if_ok "adguard" 53 false ''; then
        log INFO "Добавлен DNS adguard:53"
        ADDED_LOCAL_ADGUARD=1
    else
        log WARN "adguard:53 недоступен — пропускаю."
    fi

    # 3) Extra DoH/DoT resolvers (skip quic://). Order as provided.
    # These act as additional fallbacks after adguard and Cloudflare.
    if [ "$ADDED_LOCAL_ADGUARD" != "1" ]; then
    printf '%s\n' "$EXTRA_DNS_LIST" | while IFS= read -r raw; do
        addr=$(printf '%s' "$raw" | tr -d '\r' | sed 's/^\s*//; s/\s*$//')
        [ -z "$addr" ] && continue
        case "$addr" in quic://*) continue ;; esac
        naddr=$(_dns_norm_addr "$addr")
        # Deduplicate by address
        if _servers_has_address "$naddr"; then
            continue
        fi
        if add_server_if_ok "$naddr" '' false ''; then
            log INFO "Добавлен дополнительный DNS: $naddr"
        fi
    done
    fi

    # If none available, do not touch existing dns
    if [ "$(printf '%s' "$SERVERS_JSON" | jq -r 'length')" -eq 0 ]; then
        log WARN "Нет доступных DNS — оставляю текущую конфигурацию без изменений."
        return 1
    fi

    # Merge with existing dns, preserving unknown fields and hosts; replace servers
    XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq \
        --argjson servers "$SERVERS_JSON" '
        .xraySetting.dns = (.xraySetting.dns // {}) |
        .xraySetting.dns.disableCache = (.xraySetting.dns.disableCache // false) |
        .xraySetting.dns.queryStrategy = (.xraySetting.dns.queryStrategy // "UseIP") |
        .xraySetting.dns.servers = $servers')

    # Optional overrides via env
    if [ -n "${XRAY_DNS_DISABLECACHE:-}" ]; then
        v=$(printf '%s' "$XRAY_DNS_DISABLECACHE" | tr '[:upper:]' '[:lower:]')
        case "$v" in
            1|true|yes|on) dc=true ;;
            0|false|no|off) dc=false ;;
            *) dc=false ;;
        esac
        XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --argjson dc "$dc" '.xraySetting.dns.disableCache=$dc')
    fi
    if [ -n "${XRAY_DNS_QUERY_STRATEGY:-}" ]; then
        XRAY_SETTINGS_JSON=$(printf '%s' "$XRAY_SETTINGS_JSON" | jq --arg qs "$XRAY_DNS_QUERY_STRATEGY" '.xraySetting.dns.queryStrategy=$qs')
    fi

    export XRAY_SETTINGS_JSON
    log INFO "DNS секция XRAY обновлена с учетом доступности серверов."
    return 0
}
