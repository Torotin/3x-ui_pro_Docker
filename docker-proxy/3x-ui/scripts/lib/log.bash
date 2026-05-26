#!/usr/bin/env bash

LOGLEVEL=${LOGLEVEL:-INFO}

# Преобразует текстовый уровень лога в число для сравнения порога вывода.
log_level_num() {
	case "${1^^}" in
	ERROR) printf '1' ;;
	WARN | WARNING) printf '2' ;;
	INFO) printf '3' ;;
	DEBUG) printf '4' ;;
	*) printf '3' ;;
	esac
}

# Маскирует типовые секреты, чтобы они не попадали в диагностические сообщения.
redact_secrets() {
	local input=$*
	printf '%s' "$input" |
		sed -E \
			-e 's/([Pp]assword=)[^[:space:]]+/\1***REDACTED***/g' \
			-e 's/([Tt]oken=)[^[:space:]]+/\1***REDACTED***/g' \
			-e 's/([Cc]ookie: )[^\r\n]+/\1***REDACTED***/g' \
			-e 's/([Cc]ookie=)[^[:space:]]+/\1***REDACTED***/g' \
			-e 's/([Pp]rivate[Kk]ey[":= ]+)[^,"[:space:]]+/\1***REDACTED***/g' \
			-e 's/([Ss]ecret[Kk]ey[":= ]+)[^,"[:space:]]+/\1***REDACTED***/g'
}

# Печатает сообщение разрешенного уровня с временем и цветовой меткой.
log() {
	local level=${1:-INFO}
	shift || true
	local current active timestamp message color reset
	current=$(log_level_num "$level")
	active=$(log_level_num "$LOGLEVEL")
	((current <= active)) || return 0

	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	message=$(redact_secrets "$*")
	reset='\033[0m'
	case "${level^^}" in
	ERROR) color='\033[1;31m' ;;
	WARN | WARNING) color='\033[1;33m' ;;
	DEBUG) color='\033[1;36m' ;;
	*) color='\033[1;34m' ;;
	esac
	printf '%s %b%s%b - %s\n' "$timestamp" "$color" "${level^^}" "$reset" "$message" >&2
}

# Завершает сценарий после записи критической ошибки в журнал.
die() {
	log ERROR "$*"
	exit 1
}
