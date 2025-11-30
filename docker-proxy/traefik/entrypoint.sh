#!/bin/sh
set -eu -o pipefail

# =============================================================================
# КОНФИГУРАЦИЯ И ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ
# =============================================================================

# Настройки по умолчанию
readonly DEFAULT_LOGLEVEL="${LOGLEVEL:-INFO}"
readonly DEFAULT_RENDER_DELAY="${RENDER_DELAY:-2}"
readonly DEFAULT_CROWDSEC_TIMEOUT="${CROWDSEC_TIMEOUT:-60}"
readonly DEFAULT_PORT_CHECK_TIMEOUT="${PORT_CHECK_TIMEOUT:-15}"
readonly DEFAULT_HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
readonly DEFAULT_MAX_RETRIES="${MAX_RETRIES:-3}"
readonly DEFAULT_METRICS_ENABLED="${METRICS_ENABLED:-true}"

# Пути и директории
readonly SRC_DIR="/templates"
readonly DST_DIR="/dynamic"
readonly CONFIG_FILE="/etc/traefik/traefik.yml"
readonly ACME_FILE="/acme.json"
readonly TEMP_DIR="/tmp/traefik-templates"
readonly CACHE_DIR="/tmp/traefik-cache"
readonly METRICS_DIR="/tmp/traefik-metrics"

# Порты для проверки
readonly WEB_PORT="80"
readonly WEBSECURE_PORT="4443"
readonly L4_PORT="443"
readonly CROWDSEC_PORT="8080"

# Флаги состояния
readonly FLAG_INITIALIZED="/tmp/.traefik-initialized"
readonly FLAG_TEMPLATES_RENDERED="/tmp/.templates-rendered"

# =============================================================================
# УТИЛИТЫ И ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# =============================================================================

# Проверка наличия команды (POSIX совместимая)
have() {
    command -v "$1" >/dev/null 2>&1
}

# Получение текущего времени
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(date)"
}

# Проверка валидности уровня логирования
is_valid_log_level() {
    case "$1" in
        ERROR|WARN|INFO|DEBUG) return 0 ;;
        *) return 1 ;;
    esac
}

# Создание директорий с проверкой
ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            log_error "Failed to create directory: $dir"
            return 1
        }
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ФАЙЛАМИ
# =============================================================================

# Безопасное создание директории
safe_mkdir() {
    local dir="$1"
    local mode="${2:-755}"
    
    if [ ! -d "$dir" ]; then
        if mkdir -p "$dir" 2>/dev/null; then
            chmod "$mode" "$dir" 2>/dev/null || true
            return 0
        else
            return 1
        fi
    fi
    return 0
}

# Безопасное удаление файла/директории
safe_remove() {
    local path="$1"
    local force="${2:-false}"
    
    if [ -e "$path" ]; then
        if [ "$force" = "true" ]; then
            rm -rf "$path" 2>/dev/null || true
        else
            rm -f "$path" 2>/dev/null || true
        fi
    fi
}

# Атомарное копирование файла
atomic_copy() {
    local src="$1"
    local dst="$2"
    local tmp_dst="${dst}.tmp.$$"
    
    if [ ! -f "$src" ]; then
        return 1
    fi
    
    if cp "$src" "$tmp_dst" 2>/dev/null; then
        if mv "$tmp_dst" "$dst" 2>/dev/null; then
            return 0
        else
            rm -f "$tmp_dst" 2>/dev/null || true
            return 1
        fi
    else
        rm -f "$tmp_dst" 2>/dev/null || true
        return 1
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С СЕТЬЮ
# =============================================================================

# Проверка доступности хоста
check_host() {
    local host="$1"
    local timeout="${2:-5}"
    
    if have ping; then
        ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
    elif have nc; then
        nc -z -w "$timeout" "$host" 80 >/dev/null 2>&1
    else
        return 1
    fi
}

# Получение IP адреса
get_ip() {
    local host="$1"
    
    if have nslookup; then
        nslookup "$host" 2>/dev/null | grep -E '^Name:' -A1 | tail -1 | awk '{print $2}'
    elif have dig; then
        dig +short "$host" 2>/dev/null | head -1
    else
        echo "$host"
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ПРОЦЕССАМИ
# =============================================================================

# Проверка существования процесса
process_exists() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Безопасная остановка процесса
safe_kill() {
    local pid="$1"
    local signal="${2:-TERM}"
    local timeout="${3:-30}"
    
    if ! process_exists "$pid"; then
        return 0
    fi
    
    kill -"$signal" "$pid" 2>/dev/null || return 1
    
    local count=0
    while [ $count -lt $timeout ] && process_exists "$pid"; do
        sleep 1
        count=$((count + 1))
    done
    
    if process_exists "$pid"; then
        if [ "$signal" != "KILL" ]; then
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        fi
        return 1
    fi
    
    return 0
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С КОНФИГУРАЦИЕЙ
# =============================================================================

# Валидация YAML файла
validate_yaml() {
    local file="$1"
    
    if have yq; then
        yq eval '.' "$file" >/dev/null 2>&1
    elif have python3; then
        python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null
    else
        # Базовая проверка синтаксиса
        grep -q '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:' "$file" 2>/dev/null
    fi
}

# Получение значения из конфигурации
get_config_value() {
    local file="$1"
    local key="$2"
    
    if have yq; then
        yq eval ".$key" "$file" 2>/dev/null
    elif have python3; then
        python3 -c "
import yaml
try:
    with open('$file') as f:
        config = yaml.safe_load(f)
    print(config.get('$key', ''))
except:
    pass
" 2>/dev/null
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ МОНИТОРИНГА
# =============================================================================

# Получение использования памяти
get_memory_usage() {
    if [ -f /proc/meminfo ]; then
        awk '/MemTotal/ {total=$2} /MemAvailable/ {avail=$2} END {printf "%.1f%%", (total-avail)/total*100}' /proc/meminfo 2>/dev/null
    elif have free; then
        free | awk 'NR==2{printf "%.1f%%", $3/$2*100}' 2>/dev/null
    else
        echo "unknown"
    fi
}

# Получение загрузки CPU
get_cpu_usage() {
    if [ -f /proc/loadavg ]; then
        awk '{print $1}' /proc/loadavg 2>/dev/null
    elif have uptime; then
        uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' 2>/dev/null
    else
        echo "unknown"
    fi
}

# Получение информации о диске
get_disk_usage() {
    local path="${1:-/}"
    
    if have df; then
        df -h "$path" | awk 'NR==2{print $5}' 2>/dev/null
    else
        echo "unknown"
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ВРЕМЕНЕМ
# =============================================================================

# Получение времени в различных форматах
get_time() {
    local format="${1:-%Y-%m-%d %H:%M:%S}"
    date "+$format" 2>/dev/null || date 2>/dev/null
}

# Проверка истечения времени
time_expired() {
    local start_time="$1"
    local timeout="$2"
    local current_time
    current_time=$(date +%s 2>/dev/null || echo 0)
    
    [ $((current_time - start_time)) -ge $timeout ]
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ХЕШАМИ
# =============================================================================

# Получение хеша файла (универсальная функция)
get_file_hash() {
    local file="$1"
    local algorithm="${2:-sha256}"
    
    case "$algorithm" in
        sha256)
            if have sha256sum; then
                sha256sum "$file" | awk '{print $1}'
            elif have sha256; then
                sha256 -q "$file"
            else
                return 1
            fi
            ;;
        md5)
            if have md5sum; then
                md5sum "$file" | awk '{print $1}'
            elif have md5; then
                md5 -q "$file"
            else
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# Сравнение хешей файлов
compare_file_hashes() {
    local file1="$1"
    local file2="$2"
    local algorithm="${3:-sha256}"
    
    local hash1 hash2
    hash1=$(get_file_hash "$file1" "$algorithm")
    hash2=$(get_file_hash "$file2" "$algorithm")
    
    [ "$hash1" = "$hash2" ] && [ -n "$hash1" ]
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ПЕРЕМЕННЫМИ ОКРУЖЕНИЯ
# =============================================================================

# Безопасное получение переменной окружения
get_env() {
    local var="$1"
    local default="$2"
    eval "echo \${$var:-$default}"
}

# Установка переменной окружения с проверкой
set_env() {
    local var="$1"
    local value="$2"
    local export_flag="${3:-true}"
    
    if [ "$export_flag" = "true" ]; then
        export "$var=$value"
    else
        eval "$var=$value"
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С JSON
# =============================================================================

# Парсинг JSON (если доступен jq)
parse_json() {
    local json="$1"
    local key="$2"
    
    if have jq; then
        echo "$json" | jq -r ".$key" 2>/dev/null
    elif have python3; then
        echo "$json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('$key', ''))
except:
    pass
" 2>/dev/null
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ЛОГАМИ
# =============================================================================

# Ротация логов
rotate_log() {
    local log_file="$1"
    local max_size="${2:-10485760}"  # 10MB по умолчанию
    local max_files="${3:-5}"
    
    if [ -f "$log_file" ]; then
        local file_size
        file_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        
        if [ $file_size -gt $max_size ]; then
            # Ротация файлов
            local i=$max_files
            while [ $i -gt 1 ]; do
                local old_file="${log_file}.$((i-1))"
                local new_file="${log_file}.$i"
                [ -f "$old_file" ] && mv "$old_file" "$new_file" 2>/dev/null || true
                i=$((i - 1))
            done
            
            # Перемещение текущего файла
            mv "$log_file" "${log_file}.1" 2>/dev/null || true
            touch "$log_file" 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С СИГНАЛАМИ
# =============================================================================

# Установка обработчика сигнала
set_signal_handler() {
    local signal="$1"
    local handler="$2"
    
    trap "$handler" "$signal"
}

# Отправка сигнала процессу
send_signal() {
    local pid="$1"
    local signal="$2"
    
    if process_exists "$pid"; then
        kill -"$signal" "$pid" 2>/dev/null
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С ТЕМПЕРАТУРОЙ
# =============================================================================

# Получение температуры CPU (если доступно)
get_cpu_temp() {
    local temp_file="/sys/class/thermal/thermal_zone0/temp"
    
    if [ -f "$temp_file" ]; then
        local temp_millicelsius
        temp_millicelsius=$(cat "$temp_file" 2>/dev/null)
        if [ -n "$temp_millicelsius" ]; then
            echo "scale=1; $temp_millicelsius / 1000" | bc 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# =============================================================================
# УТИЛИТЫ ДЛЯ РАБОТЫ С СЕТЕВЫМИ ИНТЕРФЕЙСАМИ
# =============================================================================

# Получение списка сетевых интерфейсов
get_network_interfaces() {
    if [ -d /sys/class/net ]; then
        ls /sys/class/net 2>/dev/null | grep -v lo
    elif have ip; then
        ip link show 2>/dev/null | grep -E '^[0-9]+:' | awk -F: '{print $2}' | tr -d ' '
    else
        echo "unknown"
    fi
}

# Получение статистики сетевого интерфейса
get_interface_stats() {
    local interface="$1"
    local stat_file="/sys/class/net/$interface/statistics"
    
    if [ -d "$stat_file" ]; then
        {
            echo "rx_bytes: $(cat $stat_file/rx_bytes 2>/dev/null || echo 0)"
            echo "tx_bytes: $(cat $stat_file/tx_bytes 2>/dev/null || echo 0)"
            echo "rx_packets: $(cat $stat_file/rx_packets 2>/dev/null || echo 0)"
            echo "tx_packets: $(cat $stat_file/tx_packets 2>/dev/null || echo 0)"
        }
    else
        echo "interface not found"
    fi
}

# =============================================================================
# СИСТЕМА ЛОГИРОВАНИЯ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Кэш для уровней логирования
_log_level_cache=""
_log_priority_cache="3"

# Инициализация кэша логирования
init_log_cache() {
    case "$DEFAULT_LOGLEVEL" in
        ERROR) _log_priority_cache=1 ;;
        WARN)  _log_priority_cache=2 ;;
        INFO)  _log_priority_cache=3 ;;
        DEBUG) _log_priority_cache=4 ;;
        *)     _log_priority_cache=3 ;;
    esac
}

# Оптимизированная система логирования
log() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local timestamp
    
    # Валидация уровня логирования
    if ! is_valid_log_level "$level"; then
        level="INFO"
    fi
    
    # Определение приоритета и цвета
    local pri color
    case "$level" in
        ERROR) pri=1; color='\033[1;31m' ;;
        WARN)  pri=2; color='\033[1;33m' ;;
        INFO)  pri=3; color='\033[1;34m' ;;
        DEBUG) pri=4; color='\033[1;36m' ;;
        *)     pri=3; color='\033[0m' ;;
    esac
    
    # Вывод только если уровень достаточный
    if [ "$pri" -le "$_log_priority_cache" ]; then
        timestamp=$(get_timestamp)
        printf '%s %b%s%b - %s\n' "$timestamp" "$color" "$level" '\033[0m' "$message" >&2
    fi
}

# Специализированные функции логирования
log_error() { log ERROR "$@"; }
log_warn()  { log WARN "$@"; }
log_info()  { log INFO "$@"; }
log_debug() { log DEBUG "$@"; }

# =============================================================================
# СИСТЕМА ИНИЦИАЛИЗАЦИИ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Вывод информации о системе
log_system_info() {
    log_info "=== SYSTEM INFORMATION ==="
    log_info "Entrypoint started (PID: $$)"
    log_info "User: $(id -u 2>/dev/null):$(id -g 2>/dev/null) $(id -un 2>/dev/null || echo unknown)/$(id -gn 2>/dev/null || echo unknown)"
    log_info "Kernel: $(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
    
    if [ -f /etc/alpine-release ]; then
        log_info "Alpine: $(cat /etc/alpine-release)"
    fi
    
    log_info "Configuration: $CONFIG_FILE | ACME: $ACME_FILE | Templates: $SRC_DIR -> $DST_DIR"
    log_info "Settings: LOGLEVEL=$DEFAULT_LOGLEVEL RENDER_DELAY=$DEFAULT_RENDER_DELAY TZ=${TZ:-unset}"
    log_info "=========================="
}

# Проверка и установка зависимостей (Alpine оптимизированная)
install_dependencies() {
    if ! have apk; then
        log_debug "apk not available, skipping dependency installation"
        return 0
    fi
    
    log_info "Checking dependencies..."
    
    # Карта cmd:pkg для Alpine Linux
    pkgs_map="envsubst:gettext inotifywait:inotify-tools nc:netcat-openbsd sha256sum:coreutils"
    missing_pkgs=""
    
    for pair in $pkgs_map; do
        cmd="${pair%%:*}"
        pkg="${pair#*:}"
        if ! have "$cmd"; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done
    
    # Установка недостающих пакетов
    if [ -n "${missing_pkgs# }" ]; then
        log_info "Installing missing packages:${missing_pkgs}"
        if ! apk add --no-cache $missing_pkgs; then
            log_error "Failed to install packages:${missing_pkgs}"
            return 1
        fi
        log_info "Successfully installed packages:${missing_pkgs}"
    else
        log_debug "All required packages are already installed"
    fi
}

# Проверка Traefik с кэшированием
check_traefik() {
    if [ -f "$FLAG_INITIALIZED" ]; then
        log_debug "Traefik already checked"
        return 0
    fi
    
    log_info "Checking Traefik installation..."
    
    if ! have traefik; then
        log_error "Traefik binary not found in PATH"
        return 1
    fi
    
    local traefik_path
    traefik_path=$(command -v traefik)
    log_info "Traefik binary: $traefik_path"
    
    # Получение версии Traefik
    local version_output
    if version_output=$(traefik version 2>/dev/null || traefik --version 2>/dev/null); then
        echo "$version_output" | sed 's/^/    /' | while read -r line; do
            log_debug "$line"
        done
    else
        log_warn "Could not determine Traefik version"
    fi
    
    # Создание флага инициализации
    touch "$FLAG_INITIALIZED"
}

# =============================================================================
# СИСТЕМА РЕНДЕРИНГА ШАБЛОНОВ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Кэширование хешей файлов
_hash_cache_file="$CACHE_DIR/template_hashes"

# Инициализация кэша
init_cache() {
    ensure_dir "$CACHE_DIR" || return 1
    [ -f "$_hash_cache_file" ] || touch "$_hash_cache_file"
}

# Получение хеша файла
get_file_hash() {
    local file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have md5sum; then
        md5sum "$file" | awk '{print $1}'
    else
        # Fallback: размер + время модификации
        stat -c "%s-%Y" "$file" 2>/dev/null || echo "unknown"
    fi
}

# Проверка изменений в шаблонах
templates_changed() {
    changed=0
    
    for template_file in "$SRC_DIR"/*.yml; do
        [ -e "$template_file" ] || continue
        
        basename_file=$(basename "$template_file")
        current_hash=$(get_file_hash "$template_file")
        
        # Проверка кэша
        cached_hash=$(grep "^$basename_file:" "$_hash_cache_file" 2>/dev/null | cut -d: -f2)
        
        # Файл изменился, если хеш отличается или файл новый (нет в кэше)
        if [ "$current_hash" != "$cached_hash" ] || [ -z "$cached_hash" ]; then
            if [ -z "$cached_hash" ]; then
                log_info "New template detected: $basename_file (hash: $current_hash)"
            else
                log_info "Template changed: $basename_file (hash: $current_hash)"
            fi
            changed=1
        else
            log_debug "Template unchanged: $basename_file"
        fi
    done
    
    return $changed
}

# Атомарный рендеринг шаблонов с оптимизацией
render_templates() {
    src="$SRC_DIR"
    dst="$DST_DIR"
    tmp_dir=$(mktemp -d "$TEMP_DIR.XXXXXX")
    
    log_info "Rendering templates from $src to $dst..."
    
    # Проверка существования исходной директории
    if [ ! -d "$src" ]; then
        log_error "Source directory $src does not exist"
        return 1
    fi
    
    # Принудительное логирование для диагностики
    log_info "Forcing template render regardless of change detection"
    
    # Рендеринг всех YAML файлов
    rendered_count=0
    failed_count=0
    
    for template_file in "$src"/*.yml; do
        [ -e "$template_file" ] || continue
        
        basename_file=$(basename "$template_file")
        output_file="$tmp_dir/$basename_file"
        
        log_info "Processing template: $basename_file"
        
        # Рендеринг с обработкой ошибок
        if envsubst <"$template_file" >"$output_file" 2>/dev/null; then
            rendered_count=$((rendered_count + 1))
            log_info "Rendered: $basename_file"
            
            # Обновление кэша хешей
            file_hash=$(get_file_hash "$template_file")
            grep -v "^$basename_file:" "$_hash_cache_file" > "$_hash_cache_file.tmp" 2>/dev/null || true
            echo "$basename_file:$file_hash" >> "$_hash_cache_file.tmp"
            mv "$_hash_cache_file.tmp" "$_hash_cache_file"
        else
            failed_count=$((failed_count + 1))
            log_error "Failed to render template: $template_file"
        fi
    done
    
    if [ $failed_count -gt 0 ]; then
        log_error "Failed to render $failed_count template(s)"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Атомарное обновление целевой директории
    log_debug "Updating dynamic directory atomically..."
    
    # Создание целевой директории
    log_info "Creating dynamic directory: $dst"
    ensure_dir "$dst" || {
        log_error "Failed to create dynamic directory: $dst"
        return 1
    }
    log_info "Dynamic directory created successfully: $dst"
    
    # Удаление старых файлов
    find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    
    # Перемещение новых файлов
    log_info "Moving $rendered_count rendered files to destination..."
    if [ $rendered_count -gt 0 ]; then
        mv -f "$tmp_dir"/* "$dst"/ 2>/dev/null || {
            log_error "Failed to move rendered files to $dst"
            rm -rf "$tmp_dir"
            return 1
        }
        log_info "Successfully moved rendered files to $dst"
    else
        log_warn "No files were rendered, nothing to move"
    fi
    
    # Очистка временной директории
    rmdir "$tmp_dir" 2>/dev/null || true
    
    # Создание флага успешного рендеринга
    touch "$FLAG_TEMPLATES_RENDERED"
    
    log_info "Successfully rendered $rendered_count template(s)"
}

# Синхронизация файлов (удаление orphaned файлов)
sync_dynamic_files() {
    local src="$SRC_DIR"
    local dst="$DST_DIR"
    
    if [ ! -d "$dst" ]; then
        log_debug "Dynamic directory does not exist, nothing to sync"
        return 0
    fi
    
    log_debug "Syncing dynamic files (removing orphaned files)..."
    local removed_count=0
    
    for dst_file in "$dst"/*.yml; do
        [ -e "$dst_file" ] || continue
        local basename_dst
        basename_dst=$(basename "$dst_file")
        local src_file="$src/$basename_dst"
        
        if [ ! -f "$src_file" ]; then
            log_info "Removing orphaned file: $basename_dst"
            rm -f "$dst_file"
            removed_count=$((removed_count + 1))
        fi
    done
    
    if [ $removed_count -gt 0 ]; then
        log_info "Removed $removed_count orphaned file(s)"
    else
        log_debug "No orphaned files found"
    fi
}

# =============================================================================
# СИСТЕМА МОНИТОРИНГА И HEALTH CHECKS (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Проверка доступности порта с оптимизацией
check_port() {
    local host="${1:-127.0.0.1}"
    local port="$2"
    local label="${3:-$host:$port}"
    local timeout="${4:-$DEFAULT_PORT_CHECK_TIMEOUT}"
    local retries="${5:-$DEFAULT_MAX_RETRIES}"
    
    log_debug "Checking $label (timeout: ${timeout}s, retries: $retries)..."
    
    local attempt=0
    while [ $attempt -lt $retries ]; do
        local i=0
        while [ $i -lt $timeout ]; do
            if nc -z "$host" "$port" 2>/dev/null; then
                log_info "✓ $label is accessible (attempt $((attempt + 1))/$retries)"
                return 0
            fi
            sleep 1
            i=$((i + 1))
        done
        
        attempt=$((attempt + 1))
        if [ $attempt -lt $retries ]; then
            log_debug "Retrying $label check (attempt $((attempt + 1))/$retries)..."
            sleep 2
        fi
    done
    
    log_warn "✗ $label not accessible after $retries attempts"
    return 1
}

# Проверка всех необходимых портов
check_all_ports() {
    log_info "Checking port availability..."
    
    local failed_checks=0
    local total_checks=0
    
    # Список портов для проверки
    {
        echo "$WEB_PORT entryPoint web"
        echo "$WEBSECURE_PORT entryPoint websecure"
        echo "$L4_PORT entryPoint l4"
    } | while read -r port l1 l2; do
        total_checks=$((total_checks + 1))
        label="$l1 $l2"
        if ! check_port "127.0.0.1" "$port" "$label" 5 2; then
            failed_checks=$((failed_checks + 1))
        fi
    done
    
    if [ "${failed_checks:-0}" -eq 0 ]; then
        log_info "All port checks passed ($total_checks/$total_checks)"
    else
        log_warn "${failed_checks:-0} port check(s) failed ($total_checks total)"
    fi
}

# Ожидание CrowdSec с улучшенной логикой
wait_for_crowdsec() {
    log_info "Waiting for CrowdSec on port $CROWDSEC_PORT..."
    
    local timeout="$DEFAULT_CROWDSEC_TIMEOUT"
    local i=0
    
    while [ $i -lt $timeout ]; do
        if check_port "crowdsec" "$CROWDSEC_PORT" "CrowdSec" 1 1; then
            log_info "CrowdSec is ready"
            return 0
        fi
        
        sleep 1
        i=$((i + 1))
        
        # Прогресс каждые 10 секунд
        if [ $((i % 10)) -eq 0 ]; then
            log_info "Still waiting for CrowdSec... (${i}/${timeout}s)"
        fi
    done
    
    log_error "CrowdSec did not start within ${timeout}s"
    return 1
}

# =============================================================================
# СИСТЕМА УПРАВЛЕНИЯ ПРОЦЕССАМИ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Глобальные переменные для процессов
watcher_pid=""
timer_pid=""
traefik_pid=""
metrics_monitor_pid=""
traefik_restart_count=0

# Централизованная очистка ресурсов
cleanup() {
    log_info "Initiating graceful shutdown..."
    
    # Остановка мониторинга метрик
    if [ -n "$metrics_monitor_pid" ] && process_exists "$metrics_monitor_pid"; then
        log_debug "Stopping metrics monitor (PID: $metrics_monitor_pid)"
        kill "$metrics_monitor_pid" 2>/dev/null || true
        metrics_monitor_pid=""
    fi
    
    # Остановка таймера
    if [ -n "$timer_pid" ] && process_exists "$timer_pid"; then
        log_debug "Stopping timer process (PID: $timer_pid)"
        kill "$timer_pid" 2>/dev/null || true
        timer_pid=""
    fi
    
    # Остановка watcher
    if [ -n "$watcher_pid" ] && process_exists "$watcher_pid"; then
        log_debug "Stopping watcher process (PID: $watcher_pid)"
        kill "$watcher_pid" 2>/dev/null || true
        watcher_pid=""
    fi
    
    # Остановка Traefik
    if [ -n "$traefik_pid" ] && process_exists "$traefik_pid"; then
        log_info "Stopping Traefik process (PID: $traefik_pid)"
        kill -TERM "$traefik_pid" 2>/dev/null || true
        
        # Ожидание graceful shutdown
        local wait_count=0
        while [ $wait_count -lt 30 ] && process_exists "$traefik_pid"; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        # Принудительная остановка если необходимо
        if process_exists "$traefik_pid"; then
            log_warn "Traefik did not stop gracefully, forcing termination"
            kill -KILL "$traefik_pid" 2>/dev/null || true
        fi
        
        traefik_pid=""
    fi
    
    # Очистка временных файлов
    rm -f "$FLAG_INITIALIZED" "$FLAG_TEMPLATES_RENDERED" 2>/dev/null || true
    rm -rf "$TEMP_DIR"* 2>/dev/null || true
    
    log_info "Cleanup completed"
    exit 0
}

# Обработчик ошибок
on_error() {
    local line_number="${1:-unknown}"
    local exit_code="${2:-$?}"
    log_error "Entrypoint failed at line $line_number with exit code $exit_code"
    cleanup
}

# Установка обработчиков сигналов
setup_signal_handlers() {
    trap 'cleanup' INT TERM
    trap 'on_error $LINENO $?' ERR
}

# =============================================================================
# СИСТЕМА WATCHER ДЛЯ ШАБЛОНОВ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Запуск watcher для шаблонов
start_template_watcher() {
    log_info "Starting template watcher..."
    
    # Проверка наличия inotifywait
    if ! have inotifywait; then
        log_error "inotifywait not available, cannot start template watcher"
        return 1
    fi
    
    # Запуск watcher в фоновом режиме
    (
        inotifywait -qm -e create,close_write,delete,move --format '%e %f' "$SRC_DIR" 2>/dev/null | \
        while read -r event file; do
            log_info "Template change detected: $file (event: $event)"
            
            # Остановка предыдущего таймера
            if [ -n "$timer_pid" ] && process_exists "$timer_pid"; then
                kill "$timer_pid" 2>/dev/null || true
            fi
            
            # Запуск нового таймера с debounce
            (
                sleep "$DEFAULT_RENDER_DELAY"
                log_info "Debounce elapsed, re-rendering templates (triggered by: $file)"
                
                # Обработка удаления файла
                if echo "$event" | grep -q "DELETE\|MOVED_FROM"; then
                    local dst_file="$DST_DIR/$file"
                    if [ -f "$dst_file" ]; then
                        rm -f "$dst_file"
                        log_info "Deleted rendered file: $file"
                    else
                        log_debug "Rendered file $file was already deleted"
                    fi
                else
                    # Обычный рендеринг
                    if render_templates; then
                        if [ -f "$DST_DIR/$file" ]; then
                            log_info "===== BEGIN rendered $file ====="
                            sed 's/^/    /' "$DST_DIR/$file"
                            log_info "=====  END  rendered $file ====="
                        else
                            log_warn "Rendered file $file not found in $DST_DIR"
                        fi
                    else
                        log_error "Failed to re-render templates"
                    fi
                fi
            ) &
            timer_pid=$!
        done
    ) &
    watcher_pid=$!

    log_info "Template watcher started (PID: $watcher_pid)"
}

# =============================================================================
# СИСТЕМА ЗАПУСКА TRAEFIK (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Подготовка ACME файла
prepare_acme_file() {
    log_info "Preparing ACME file..."
    
    if [ ! -f "$ACME_FILE" ]; then
        log_warn "ACME file $ACME_FILE does not exist, creating empty file"
        touch "$ACME_FILE"
    fi
    
    # Установка правильных прав доступа
    if ! chmod 600 "$ACME_FILE"; then
        log_warn "Failed to set permissions on $ACME_FILE"
    fi
    
    # Вывод информации о файле
    if have ls; then
        log_debug "ACME file info:"
        ls -l "$ACME_FILE" | sed 's/^/    /'
    fi
}

# Проверка конфигурационного файла
validate_config_file() {
    log_info "Validating configuration file..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file $CONFIG_FILE not found"
        return 1
    fi
    
    # Проверка хеша файла
    if have sha256sum; then
        local config_hash
        config_hash=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
        log_info "Configuration file SHA256: $config_hash"
    fi
    
    # Базовая проверка синтаксиса YAML
    if have yq; then
        if yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
            log_info "Configuration file syntax is valid"
        else
            log_error "Configuration file has invalid syntax"
            return 1
        fi
    else
        log_warn "yq not available, skipping syntax validation"
    fi
}

# Запуск Traefik
start_traefik() {
    log_info "Starting Traefik..."
    
    # Подготовка к запуску
    prepare_acme_file
    validate_config_file || return 1
    
    # Запуск Traefik в фоновом режиме
    log_info "Executing: traefik --configFile=$CONFIG_FILE"
    traefik --configFile="$CONFIG_FILE" &
    traefik_pid=$!
    
    log_info "Traefik started (PID: $traefik_pid)"
    
    # Проверка успешного запуска
    sleep 2
    if ! process_exists "$traefik_pid"; then
        log_error "Traefik process died immediately after startup"
        return 1
    fi
    
    log_info "Traefik is running successfully"
}

# =============================================================================
# СИСТЕМА МОНИТОРИНГА СЕТИ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Вывод информации о сетевых соединениях
show_network_info() {
    log_info "Network information:"
    
    if have ss; then
        log_debug "Listening sockets (ss):"
        ss -ltnup 2>/dev/null | sed 's/^/    /' || log_warn "Could not get socket information"
    elif have netstat; then
        log_debug "Listening sockets (netstat):"
        netstat -tuln 2>/dev/null | sed 's/^/    /' || log_warn "Could not get socket information"
    else
        log_warn "Neither ss nor netstat available for network information"
    fi
}

# =============================================================================
# СИСТЕМА МЕТРИК И МОНИТОРИНГА
# =============================================================================

# Конфигурация метрик
readonly METRICS_FILE="$METRICS_DIR/metrics.json"
readonly METRICS_INTERVAL="${METRICS_INTERVAL:-30}"

# Инициализация системы метрик
init_metrics() {
    mkdir -p "$METRICS_DIR"
    
    # Создание начального файла метрик
    local start_time
    start_time=$(date +%s 2>/dev/null || echo "0")
    cat > "$METRICS_FILE" << EOF
{
    "start_time": "$start_time",
    "version": "3.0.0",
    "metrics": {
        "system": {},
        "traefik": {},
        "templates": {},
        "network": {}
    }
}
EOF
}

# Получение системных метрик
get_system_metrics() {
    local timestamp
    timestamp=$(date +%s 2>/dev/null || echo "0")
    
    cat << EOF
{
    "timestamp": $timestamp,
    "memory_usage": "$(get_memory_usage)",
    "cpu_load": "$(get_cpu_usage)",
    "disk_usage": "$(get_disk_usage /)",
    "uptime": "$(cat /proc/uptime 2>/dev/null | awk '{print $1}' || echo 0)",
    "processes": $(ps aux 2>/dev/null | wc -l || echo 0),
    "load_average": "$(cat /proc/loadavg 2>/dev/null | awk '{print $1","$2","$3}' || echo "0,0,0")"
}
EOF
}

# Получение метрик сети
get_network_metrics() {
    local timestamp
    timestamp=$(date +%s 2>/dev/null || echo "0")
    
    cat << EOF
{
    "timestamp": $timestamp,
    "interfaces": "$(get_network_interfaces | tr '\n' ',' | sed 's/,$//')",
    "connections": $(ss -s 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 0),
    "listening_ports": $(ss -ln 2>/dev/null | grep -c LISTEN || echo 0)
}
EOF
}

# Получение метрик Traefik
get_traefik_metrics() {
    local timestamp
    timestamp=$(date +%s 2>/dev/null || echo "0")
    
    # Проверка статуса Traefik
    local traefik_status="unknown"
    local traefik_uptime="0"
    local traefik_memory="0"
    
    if [ -n "$traefik_pid" ] && process_exists "$traefik_pid"; then
        traefik_status="running"
        if [ -f /proc/$traefik_pid/stat ]; then
            traefik_uptime=$(awk '{print int(($22)/100)}' /proc/$traefik_pid/stat 2>/dev/null || echo 0)
            traefik_memory=$(awk '{print $23}' /proc/$traefik_pid/stat 2>/dev/null || echo 0)
        fi
    else
        traefik_status="stopped"
    fi
    
    cat << EOF
{
    "timestamp": $timestamp,
    "status": "$traefik_status",
    "pid": ${traefik_pid:-0},
    "uptime": $traefik_uptime,
    "memory_kb": $traefik_memory,
    "restart_count": ${traefik_restart_count:-0}
}
EOF
}

# Получение метрик шаблонов
get_template_metrics() {
    local timestamp
    timestamp=$(date +%s 2>/dev/null || echo "0")
    
    local template_count=0
    local rendered_count=0
    local last_render_time="0"
    
    # Подсчет шаблонов
    if [ -d "$SRC_DIR" ]; then
        template_count=$(find "$SRC_DIR" -name "*.yml" -type f 2>/dev/null | wc -l)
    fi
    
    # Подсчет отрендеренных файлов
    if [ -d "$DST_DIR" ]; then
        rendered_count=$(find "$DST_DIR" -name "*.yml" -type f 2>/dev/null | wc -l)
    fi
    
    # Время последнего рендеринга
    if [ -f "$FLAG_TEMPLATES_RENDERED" ]; then
        last_render_time=$(stat -c %Y "$FLAG_TEMPLATES_RENDERED" 2>/dev/null || echo 0)
    fi
    
    cat << EOF
{
    "timestamp": $timestamp,
    "template_count": $template_count,
    "rendered_count": $rendered_count,
    "last_render_time": $last_render_time,
    "render_success_rate": $((rendered_count * 100 / (template_count + 1)))
}
EOF
}

# Сбор всех метрик
collect_metrics() {
    local timestamp
    timestamp=$(date +%s 2>/dev/null || echo "0")
    
    # Создание временного файла для метрик
    local temp_file="$METRICS_DIR/metrics.tmp"
    
    cat > "$temp_file" << EOF
{
    "timestamp": $timestamp,
    "system": $(get_system_metrics),
    "network": $(get_network_metrics),
    "traefik": $(get_traefik_metrics),
    "templates": $(get_template_metrics)
}
EOF
    
    # Атомарное обновление файла метрик
    if [ -f "$temp_file" ]; then
        mv "$temp_file" "$METRICS_FILE"
    fi
}

# Запуск мониторинга метрик
start_metrics_monitor() {
    log_info "Starting metrics monitoring..."
    
    (
        while true; do
            collect_metrics
            sleep "$METRICS_INTERVAL"
        done
    ) &
    
    metrics_monitor_pid=$!
    log_info "Metrics monitor started (PID: $metrics_monitor_pid)"
}

# Проверка пороговых значений
check_thresholds() {
    local memory_usage
    memory_usage=$(get_memory_usage | sed 's/%//')
    local cpu_load
    cpu_load=$(get_cpu_usage)
    
    # Проверка использования памяти
    if [ "${memory_usage%.*}" -gt 90 ]; then
        log_warn "High memory usage: ${memory_usage}%"
    fi
    
    # Проверка загрузки CPU
    if [ "${cpu_load%.*}" -gt 5 ]; then
        log_warn "High CPU load: $cpu_load"
    fi
    
    # Проверка статуса Traefik
    if [ -n "$traefik_pid" ] && ! process_exists "$traefik_pid"; then
        log_error "Traefik process is not running"
        return 1
    fi
}

# Генерация отчета о состоянии
generate_status_report() {
    log_info "=== STATUS REPORT ==="
    
    # Системная информация
    log_info "System:"
    log_info "  Memory: $(get_memory_usage)"
    log_info "  CPU Load: $(get_cpu_usage)"
    log_info "  Disk: $(get_disk_usage /)"
    
    # Сетевая информация
    log_info "Network:"
    log_info "  Interfaces: $(get_network_interfaces | tr '\n' ' ')"
    log_info "  Connections: $(ss -s 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 0)"
    
    # Статус Traefik
    log_info "Traefik:"
    if [ -n "$traefik_pid" ] && process_exists "$traefik_pid"; then
        log_info "  Status: Running (PID: $traefik_pid)"
        log_info "  Memory: $(awk '{print $23}' /proc/$traefik_pid/stat 2>/dev/null || echo 0) KB"
    else
        log_info "  Status: Stopped"
    fi
    
    # Шаблоны
    log_info "Templates:"
    log_info "  Source: $(find "$SRC_DIR" -name "*.yml" 2>/dev/null | wc -l) files"
    log_info "  Rendered: $(find "$DST_DIR" -name "*.yml" 2>/dev/null | wc -l) files"
    
    log_info "=================="
}

# Проверка здоровья системы
health_check() {
    local status="healthy"
    local issues=""
    
    # Проверка памяти
    local memory_usage
    memory_usage=$(get_memory_usage | sed 's/%//')
    if [ "${memory_usage%.*}" -gt 95 ]; then
        status="unhealthy"
        issues="$issues high_memory_usage"
    fi
    
    # Проверка Traefik
    if [ -n "$traefik_pid" ] && ! process_exists "$traefik_pid"; then
        status="unhealthy"
        issues="$issues traefik_down"
    fi
    
    # Проверка шаблонов
    if [ ! -d "$DST_DIR" ] || [ -z "$(find "$DST_DIR" -name "*.yml" 2>/dev/null)" ]; then
        status="degraded"
        issues="$issues no_templates"
    fi
    
    echo "{\"status\":\"$status\",\"issues\":\"$issues\"}"
}

# =============================================================================
# ОСНОВНАЯ ФУНКЦИЯ (ОПТИМИЗИРОВАННАЯ)
# =============================================================================

# Главная функция
main() {
    # Инициализация логирования в самом начале
    init_log_cache
    
    log_info "=== TRAEFIK ENTRYPOINT STARTED ==="
    
    # Инициализация
    log_system_info
    setup_signal_handlers
    init_cache
    
    # Инициализация метрик
    if [ "$DEFAULT_METRICS_ENABLED" = "true" ]; then
        init_metrics
        start_metrics_monitor
    fi
    
    # Проверка зависимостей
    install_dependencies || {
        log_error "Failed to install dependencies"
        exit 1
    }
    
    # Проверка Traefik
    check_traefik || {
        log_error "Traefik check failed"
        exit 1
    }
    
    # Ожидание CrowdSec
    wait_for_crowdsec || {
        log_error "CrowdSec is not available"
        exit 1
    }
    
    # Создание директории /dynamic если она не существует
    ensure_dir "$DST_DIR" || {
        log_error "Failed to create dynamic directory: $DST_DIR"
        exit 1
    }
    
    # Первоначальный рендеринг шаблонов
    render_templates || {
        log_error "Failed to render initial templates"
        exit 1
    }
    
    # Синхронизация файлов (удаление orphaned файлов)
    sync_dynamic_files
    
    # Запуск watcher для шаблонов
    start_template_watcher || {
        log_error "Failed to start template watcher"
        exit 1
    }
    
    # Проверка существования директории /dynamic
    if [ ! -d "$DST_DIR" ]; then
        log_error "Dynamic directory $DST_DIR does not exist"
        exit 1
    fi
    
    # Запуск Traefik
    start_traefik || {
        log_error "Failed to start Traefik"
        exit 1
    }
    
    # Проверка портов
    check_all_ports
    
    # Вывод сетевой информации
    show_network_info
    
    # Генерация отчета о состоянии
    generate_status_report
    
    log_info "=== TRAEFIK ENTRYPOINT INITIALIZATION COMPLETE ==="
    
    # Ожидание завершения Traefik
    if [ -n "$traefik_pid" ]; then
        log_info "Waiting for Traefik process (PID: $traefik_pid)..."
        wait "$traefik_pid"
        local exit_code=$?
        log_info "Traefik process exited with code: $exit_code"
        exit $exit_code
    else
        log_error "Traefik process not found"
        exit 1
    fi
}

# Запуск основной функции
main "$@"
