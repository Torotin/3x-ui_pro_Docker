#!/usr/bin/env sh
# POSIX‑совместимый скрипт для массового скачивания файлов с кастомными именами
set -eu

# ----------------------------
# Функция логирования (уровни: ERROR, WARN, INFO, DEBUG)
log() {
    level=$1; shift
    level=$(printf '%s' "$level" | tr -d '[:space:]')
    [ -z "$level" ] && level=INFO
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        ERROR) current=1 ;; WARN*) current=2 ;; INFO) current=3 ;; DEBUG) current=4 ;; *) current=3 ;; 
    esac
    case "${LOGLEVEL:-INFO}" in
        ERROR) active=1 ;; WARN*) active=2 ;; INFO) active=3 ;; DEBUG) active=4 ;; *) active=3 ;; 
    esac
    [ "$current" -gt "$active" ] && return
    case "$level" in
        INFO)   color='\033[1;34m' ;; WARN*)  color='\033[1;33m' ;;
        ERROR)  color='\033[1;31m' ;; DEBUG) color='\033[1;36m' ;; *) color='\033[0m' ;;
    esac
    reset='\033[0m'
    printf '%s %b%s%b - %s\n' \
        "$timestamp" "$color" "$level" "$reset" "$*" >&2
}
# ----------------------------

# Каталог для скачивания (можно переопределить извне)
target_dir="${XUI_BIN_FOLDER:-/app/bin}"

# Список для скачивания (каждая строка: URL или URL|имя_файла)
URL_LIST='
https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat|zxc-rv-adlist.dat
https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat
'

# Выбор инструмента для скачивания
if command -v curl >/dev/null 2>&1; then
    DL_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    DL_TOOL="wget"
else
    log ERROR "Не найден ни curl, ни wget. Установите один из них."
    exit 1
fi

log INFO "Начинаем загрузку в каталог: $target_dir"
mkdir -p "$target_dir"

# Читаем список построчно без создания подпроцессов
while IFS= read -r entry; do
    # пропускаем пустые или комментированные строки
    [ -z "${entry%%"#"*}" ] && continue
    entry=${entry%%\#*}   # удалим всё после "#"
    entry=${entry%%[ 	]} # обрежем возможные пробелы в конце
    [ -z "$entry" ] && continue

    # Разбор: URL|имя или только URL
    case "$entry" in
        *\|*) 
            url="${entry%%|*}"
            fname="${entry#*|}"
            ;;
        *)
            url="$entry"
            # на случай URL с query-параметрами
            fname=$(basename "${url%%\?*}")
            ;;
    esac

    dest="$target_dir/$fname"
    log INFO "Скачиваю $url → $dest"
    if [ "$DL_TOOL" = "curl" ]; then
        curl -fSL -o "$dest" "$url"
    else
        wget -q -O "$dest" "$url"
    fi
done <<EOF
$URL_LIST
EOF

log INFO "Все файлы успешно скачаны."
