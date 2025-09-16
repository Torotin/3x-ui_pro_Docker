#!/usr/bin/env sh
set -eu

# ——— Конфиг через ENV ———
: "${XUI_BIN_FOLDER:=/app/bin}"
: "${LOGLEVEL:=INFO}"
# Если задан URL_LIST_FILE, читаем оттуда; иначе — из переменной URL_LIST
: "${URL_LIST_FILE:=}"

# Список URL (каждая строка — либо URL, либо URL|имя_файла)
URL_LIST='https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.dat|zxc-rv-adlist.dat
https://github.com/jameszeroX/zkeen-ip/releases/latest/download/zkeenip.dat'

# ——— Функция логирования (ERROR, WARN, INFO, DEBUG) ———
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
        INFO)  color='\033[1;34m' ;;
        WARN*) color='\033[1;33m' ;;
        ERROR) color='\033[1;31m' ;;
        DEBUG) color='\033[1;36m' ;;
        *)     color='\033[0m' ;;
    esac
    reset='\033[0m'
    printf '%s %b%s%b - %s\n' \
        "$timestamp" "$color" "$level" "$reset" "$*" >&2
}

# ——— Выбор инструмента для скачивания ———
if command -v curl >/dev/null 2>&1; then
    DL_TOOL=curl
elif command -v wget >/dev/null 2>&1; then
    DL_TOOL=wget
else
    log ERROR "Нужен curl или wget — установите один из них."
    exit 1
fi

log INFO "Загрузка файлов в каталог: $XUI_BIN_FOLDER"
mkdir -p "$XUI_BIN_FOLDER"

# ——— Открываем поток с URL ———
if [ -n "$URL_LIST_FILE" ] && [ -f "$URL_LIST_FILE" ]; then
    log INFO "Читаем список из файла $URL_LIST_FILE"
    exec 3<"$URL_LIST_FILE"
else
    log INFO "Читаем список из встроенной переменной URL_LIST"
    exec 3<<EOF
$URL_LIST
EOF
fi

# ——— Основной цикл: читаем построчно, парсим, скачиваем ———
while IFS= read -r entry <&3; do
    # убираем пробелы по краям
    entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # пропускаем пустые строки и комменты
    case "$entry" in
        ''|\#*) continue ;;
    esac

    # Разбор: URL|имя или только URL
    case "$entry" in
        *\|*)
            url=${entry%%|*}
            fname=${entry#*|}
            ;;
        *)
            url=$entry
            fname=$(basename "${url%%\?*}")
            ;;
    esac

    dest="$XUI_BIN_FOLDER/$fname"
    log INFO "Скачиваю $url → $dest"

    if [ "$DL_TOOL" = "curl" ]; then
        curl -fSL -o "$dest" "$url" \
            || { log ERROR "Не удалось загрузить $url"; exit 1; }
    else
        wget -q -O "$dest" "$url" \
            || { log ERROR "Не удалось загрузить $url"; exit 1; }
    fi
done

log INFO "Все файлы успешно загружены."
