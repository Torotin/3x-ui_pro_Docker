#!/bin/sh
#
# Traefik ACME Exporter — минималистичный и надёжный экспорт PEM-сертификатов.
#
# Что делает:
#   • следит за изменениями acme.json через inotifywait
#   • извлекает все сертификаты всех resolvers
#   • создаёт файлы:
#         <domain>-cert.pem
#         <domain>-key.pem
#         <domain>-fullchain.pem
#   • wildcard-домены → wildcard-example.com
#   • atomic update через *.tmp → безопасное обновление
#   • удаляет старые PEM, которых нет в acme.json
#   • пишет health.json со статусами:
#         INIT     — старт контейнера
#         IDLE     — heartbeat (ожидание)
#         OK       — сертификаты обновлены
#         WARN     — сертификатов нет
#         ERROR    — acme.json повреждён
#   • проверка "жив ли процесс" через /proc/<pid>
#
# Диагностика health.json:
#   status:
#     INIT   — норма после старта
#     IDLE   — норма при отсутствии событий
#     OK     — успешная обработка сертификатов
#     WARN   — acme.json валидный, но пустой
#     ERROR  — bad acme.json (повреждён)
#
#   process:
#     running — контейнер работает корректно
#     dead    — скрипт или shell умер (анормально)
#
# События обновления:
#   • heartbeat — раз в heartbeat_interval секунд
#   • изменение acme.json — немедленная обработка
#

apk add --no-cache jq inotify-tools coreutils >/dev/null
echo "[Exporter] Started"

# Подстраховка: ждём, пока Docker примонтирует volume /export
while [ ! -d /export ]; do
    echo "[Exporter] Waiting for /export to be mounted..."
    sleep 0.2
done

# PID основного shell-процесса контейнера
echo $$ > /export/exporter.pid

last_update=0
debounce=3

# heartbeat (IDLE) каждые N секунд
heartbeat_interval=60   # 1 минута
last_heartbeat=0

# Приведение wildcard-доменов к безопасному имени
sanitize_domain() {
    echo "$1" | sed 's/^\*\./wildcard-/'
}

# Проверка "жив ли" основной процесс (BusyBox-safe)
check_process() {
    pid=$(cat /export/exporter.pid 2>/dev/null)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        echo "running"
    else
        echo "dead"
    fi
}

# Запись статуса container → health.json
write_health() {
    status="$1"
    msg="$2"
    process_status=$(check_process)

    cat > /export/health.json <<EOF
{
  "status": "$status",
  "process": "$process_status",
  "updated": $(date +%s),
  "message": "$msg"
}
EOF

    echo "[Exporter] Health updated: $status - $msg"
}

# Первичная инициализация
write_health_init() {
    process_status=$(check_process)

    cat > /export/health.json <<EOF
{
  "status": "INIT",
  "process": "$process_status",
  "updated": $(date +%s),
  "message": "Exporter started, waiting for acme.json changes"
}
EOF

    echo "[Exporter] Health initialized"
}

# heartbeat — выставляется, если долго нет событий от ACME
write_heartbeat() {
    write_health "IDLE" "Heartbeat"
}

# Атомарное обновление целевых PEM-файлов
update_file() {
    src_tmp="$1"
    dest="$2"

    case "$src_tmp" in
        *-key.pem.tmp)
            chmod 600 "$src_tmp" 2>/dev/null
            ;;
    esac

    # Первый экспорт
    if [ ! -f "$dest" ]; then
        mv "$src_tmp" "$dest"
        case "$dest" in *-key.pem) chmod 600 "$dest" ;; esac
        echo "[Exporter] Created $dest"
        return
    fi

    # Проверка изменения файла по хешу
    old_hash=$(sha256sum "$dest" | awk '{print $1}')
    new_hash=$(sha256sum "$src_tmp" | awk '{print $1}')

    if [ "$old_hash" = "$new_hash" ]; then
        rm -f "$src_tmp"
        echo "[Exporter] Skipped $dest (unchanged)"
        return
    fi

    # Обновление
    mv "$src_tmp" "$dest"
    case "$dest" in *-key.pem) chmod 600 "$dest" ;; esac
    echo "[Exporter] Updated $dest"
}

# Извлечение всех Certificates из acme.json со всех resolvers
extract_certificates() {
    jq -c '
        .. |
        objects |
        select(has("Certificates")) |
        .Certificates // empty
    ' /acme.json
}

# Чистим PEM, которые больше не присутствуют в acme.json
cleanup_old_files() {
    current_domains="$1"

    # Если файлов нет — пропускаем
    set -- /export/*.pem
    [ "$1" = "/export/*.pem" ] && return

    for f in /export/*.pem; do
        base=$(basename "$f")
        domain_in_file=$(echo "$base" | sed 's/-\(cert\|key\|fullchain\)\.pem$//')

        echo "$current_domains" | grep -qx "$domain_in_file" || {
            rm -f "/export/${domain_in_file}-cert.pem" \
                  "/export/${domain_in_file}-key.pem" \
                  "/export/${domain_in_file}-fullchain.pem"
            echo "[Exporter] Removed stale PEM for $domain_in_file"
        }
    done
}

# --- INIT ---
write_health_init

# --- MAIN LOOP ---
while true; do
    now=$(date +%s)

    # Heartbeat если давно нет активности
    if [ $((now - last_heartbeat)) -ge $heartbeat_interval ]; then
        write_heartbeat
        last_heartbeat=$now
    fi

    # Ждём изменения acme.json
    inotifywait -e close_write /acme.json >/dev/null 2>&1

    # Debounce обновлений (случаются burst-записи)
    now=$(date +%s)
    if [ $((now - last_update)) -lt $debounce ]; then
        echo "[Exporter] Debounced"
        continue
    fi
    last_update=$now

    echo "[Exporter] Detected acme.json update..."

    all=$(extract_certificates | jq -s 'add')

    # Проверка корректности JSON
    if ! echo "$all" | jq empty 2>/dev/null; then
        write_health "ERROR" "Invalid acme.json format"
        echo "[Exporter] Bad acme.json"
        continue
    fi

    count=$(echo "$all" | jq 'length')

    if [ "$count" -eq 0 ]; then
        write_health "WARN" "No certificates found"
        echo "[Exporter] No certificates found"
        continue
    fi

    processed_domains=""

    # Обработка каждого сертификата
    for i in $(seq 0 $((count - 1))); do
        raw_domain=$(echo "$all" | jq -r ".[$i].domain.main")
        domain=$(sanitize_domain "$raw_domain")

        cert_tmp="/export/$domain-cert.pem.tmp"
        key_tmp="/export/$domain-key.pem.tmp"
        full_tmp="/export/$domain-fullchain.pem.tmp"

        cert="/export/$domain-cert.pem"
        key="/export/$domain-key.pem"
        full="/export/$domain-fullchain.pem"

        # Заполняем PEM (с атрибутами key)
        echo "$all" | jq -r ".[$i].certificate" | base64 -d > "$cert_tmp"
        echo "$all" | jq -r ".[$i].key"         | base64 -d > "$key_tmp"

        # Fullchain = cert + issuer + chain[]
        {
            echo "$all" | jq -r ".[$i].certificate"       | base64 -d
            echo "$all" | jq -r ".[$i].issuerCertificate" | base64 -d
            echo "$all" | jq -r ".[$i].chain[]?"          2>/dev/null | base64 -d
        } > "$full_tmp"

        update_file "$cert_tmp" "$cert"
        update_file "$key_tmp"  "$key"
        update_file "$full_tmp" "$full"

        processed_domains="$processed_domains
$domain"

        echo "[Exporter] Processed $domain"
    done

    cleanup_old_files "$processed_domains"

    write_health "OK" "Processed $count certificates"

    echo "[Exporter] Done"
done
