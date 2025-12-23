#!/bin/bash
set -e

log() {
    level=$1; shift
    level=$(printf '%s' "$level" | tr -d '[:space:]')
    [ -z "$level" ] && level=INFO
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        ERROR) current=1 ;; WARN*) current=2 ;; INFO) current=3 ;; DEBUG) current=4 ;; *) current=3 ;; 
    esac
    case "$LOGLEVEL" in
        ERROR) active=1 ;; WARN*) active=2 ;; INFO) active=3 ;; DEBUG) active=4 ;; *) active=3 ;; 
    esac
    [ "$current" -gt "$active" ] && return
    case "$level" in
        INFO)   color='\033[1;34m' ;; WARN*)  color='\033[1;33m' ;; ERROR) color='\033[1;31m' ;; DEBUG) color='\033[1;36m' ;; *) color='\033[0m' ;; 
    esac
    reset='\033[0m'
    printf '%s %b%s%b - %s\n' \
        "$timestamp" "$color" "$level" "$reset" "$*" >&2
}

arch=$(uname -m)
case "$arch" in
    x86_64)
        ARCH="64"
        FNAME="amd64"
        ;;
    aarch64)
        ARCH="arm64-v8a"
        FNAME="arm64"
        ;;
    armv7l)
        ARCH="arm32-v7a"
        FNAME="arm"
        ;;
    *)
        log INFO "Неизвестная архитектура: $arch"
        exit 1
        ;;
esac

xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
xray_zip="Xray-linux-${ARCH}.zip"
target_dir="${XUI_BIN_FOLDER:-/app/bin}"
target_file="${target_dir}/xray-linux-${FNAME}"

# Используем временный каталог
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

log INFO "Загрузка: $xray_url"
wget -O "$tmpdir/$xray_zip" "$xray_url"

log INFO "Распаковка: $xray_zip"
cd "$tmpdir"
unzip -q "$xray_zip"

rm -f "$xray_zip" geoip.dat geosite.dat

if [ ! -f xray ]; then
    log INFO "Ошибка: бинарный файл 'xray' не найден после распаковки."
    exit 1
fi

mkdir -p "$target_dir"

# Кладём с заменой
mv -f xray "$target_file"
chmod +x "$target_file"
log INFO "Готово. Бинарник: $target_file"
