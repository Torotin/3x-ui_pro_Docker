#!/usr/bin/env bash
# Wait until DNS A (and AAAA in dual mode) match the host public addresses.
# Usage: dns_check.sh [--once] [domain ...]
# Env: WEBDOMAIN, PUBLIC_IPV4, PUBLIC_IPV6, HOST_IP_MODE; or install-state/.env files.
#      DNS_CHECK_ONCE=1 — один проход без ожидания; DNS_CHECK_INTERVAL — пауза (сек).
# Without --once, later cycles re-check only resolvers that failed previously.

set -u

ONCE=false
if [[ "${1:-}" == "--once" ]]; then
	ONCE=true
	shift
fi
if [[ "${DNS_CHECK_ONCE:-0}" == "1" ]]; then
	ONCE=true
fi

clear 2>/dev/null || true

command -v dig >/dev/null || {
	echo "❌ Требуется утилита 'dig'. Установите пакет 'dnsutils' или 'bind-tools'."
	exit 1
}
command -v curl >/dev/null || {
	echo "❌ Требуется 'curl'. Установите через apt, apk или другой пакетный менеджер."
	exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_ipv4() {
	[[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
	local ip="${1:-}"
	[[ "$ip" == *:* ]] && ! is_ipv4 "$ip"
}

# Prefer compressed lowercase form when python3 is available.
normalize_ip() {
	local ip="${1:-}"
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]).compressed)' "$ip" 2>/dev/null && return 0
	fi
	printf '%s\n' "${ip,,}"
}

ip_equal() {
	local a b
	a="$(normalize_ip "$1")"
	b="$(normalize_ip "$2")"
	[[ -n "$a" && -n "$b" && "$a" == "$b" ]]
}

fetch_public_ipv4() {
	local url ip
	local -a urls=(
		"https://api.ipify.org"
		"https://ipv4.icanhazip.com"
		"https://ifconfig.me/ip"
	)
	for url in "${urls[@]}"; do
		ip="$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
		if is_ipv4 "$ip"; then
			printf '%s\n' "$ip"
			return 0
		fi
	done
	return 1
}

fetch_public_ipv6() {
	local url ip
	local -a urls=(
		"https://api64.ipify.org"
		"https://ipv6.icanhazip.com"
		"https://ifconfig.me/ip"
	)
	for url in "${urls[@]}"; do
		ip="$(curl -6 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
		if is_ipv6 "$ip"; then
			printf '%s\n' "$ip"
			return 0
		fi
	done
	return 1
}

load_env_files() {
	local candidate real loaded_key
	local -A seen=()
	local -a candidates=(
		"${INSTALL_ENV_FILE:-}"
		"$SCRIPT_DIR/../install-state/install.env"
		"/opt/script/install-state/install.env"
		"$SCRIPT_DIR/../../docker-proxy/compose.d/.env"
		"/opt/docker-proxy/compose.d/.env"
		"$PWD/install.env"
		"$PWD/.env"
		"install.env"
	)
	for candidate in "${candidates[@]}"; do
		[[ -n "$candidate" && -f "$candidate" ]] || continue
		real="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
		loaded_key="$real"
		[[ -n "${seen[$loaded_key]:-}" ]] && continue
		seen[$loaded_key]=1
		# install.env may contain `$` in secrets; never source under `set -u`.
		set +u
		set -a
		# shellcheck disable=SC1090
		source "$candidate"
		set +a
		set -u
		echo "📄 Загружен env: $candidate"
	done
}

load_env_files

DOMAINS=()
if [[ -n "${WEBDOMAIN:-}" ]]; then
	DOMAINS+=("$WEBDOMAIN")
fi
if [[ $# -gt 0 ]]; then
	DOMAINS+=("$@")
fi
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
	echo "❌ Не заданы домены для проверки."
	echo "Вы можете:"
	echo "  - указать домены как аргументы: $0 example.com"
	echo "  - или задать WEBDOMAIN в install.env / compose .env"
	exit 1
fi

NAMESERVERS=(
	"1.1.1.1:Cloudflare"
	"1.0.0.1:Cloudflare-2"
	"8.8.8.8:Google"
	"8.8.4.4:Google-2"
	"9.9.9.9:Quad9"
	"149.112.112.112:Quad9-2"
	"208.67.222.222:OpenDNS"
	"208.67.220.220:OpenDNS-2"
	"94.140.14.14:AdGuard"
	"94.140.15.15:AdGuard-2"
	"185.228.168.9:CleanBrowsing"
	"185.228.169.9:CleanBrowsing-2"
	"84.200.69.80:DNSWatch"
	"84.200.70.40:DNSWatch-2"
	"91.239.100.100:UncensoredDNS"
	"89.233.43.71:UncensoredDNS-2"
	"8.26.56.26:Comodo"
	"8.20.247.20:Comodo-2"
	"4.2.2.1:Level3"
	"4.2.2.2:Level3-2"
	"77.88.8.8:Yandex"
	"77.88.8.1:Yandex-2"
)

INTERVAL="${DNS_CHECK_INTERVAL:-15}"

# Resolve expected addresses. Never let curl Happy-Eyeballs put IPv6 into EXPECT_IPV4.
EXPECT_IPV4="${PUBLIC_IPV4:-}"
if ! is_ipv4 "$EXPECT_IPV4"; then
	if [[ -n "$EXPECT_IPV4" ]]; then
		echo "⚠️ PUBLIC_IPV4='$EXPECT_IPV4' не похож на IPv4 — переопределяю через curl -4."
	fi
	EXPECT_IPV4="$(fetch_public_ipv4 || true)"
fi
if ! is_ipv4 "$EXPECT_IPV4"; then
	echo "❌ Не удалось получить внешний IPv4 сервера."
	exit 1
fi

EXPECT_IPV6="${PUBLIC_IPV6:-}"
# Reject legacy poison where v6 was copied from v4.
if is_ipv4 "$EXPECT_IPV6"; then
	EXPECT_IPV6=""
fi
if [[ -n "$EXPECT_IPV6" ]] && ! is_ipv6 "$EXPECT_IPV6"; then
	echo "⚠️ PUBLIC_IPV6='$EXPECT_IPV6' не похож на IPv6 — сбрасываю."
	EXPECT_IPV6=""
fi

HOST_IP_MODE="${HOST_IP_MODE:-}"
case "${HOST_IP_MODE,,}" in
dual | both) HOST_IP_MODE=dual ;;
ipv4 | v4 | "") HOST_IP_MODE=ipv4 ;;
*)
	# Unknown value: derive from addresses.
	HOST_IP_MODE=ipv4
	;;
esac

CHECK_AAAA=false
if [[ "$HOST_IP_MODE" == "dual" ]]; then
	CHECK_AAAA=true
	if [[ -z "$EXPECT_IPV6" ]]; then
		EXPECT_IPV6="$(fetch_public_ipv6 || true)"
	fi
	if ! is_ipv6 "$EXPECT_IPV6"; then
		echo "❌ HOST_IP_MODE=dual, но внешний IPv6 не определён (PUBLIC_IPV6 / curl -6)."
		exit 1
	fi
elif is_ipv6 "$EXPECT_IPV6"; then
	# PUBLIC_IPV6 set without dual mode → still verify AAAA when explicitly configured.
	CHECK_AAAA=true
	HOST_IP_MODE=dual
fi

echo "🌐 Режим: $HOST_IP_MODE"
echo "🌐 Ожидаемый IPv4 (A): $EXPECT_IPV4"
if $CHECK_AAAA; then
	echo "🌐 Ожидаемый IPv6 (AAAA): $EXPECT_IPV6"
	echo "Ожидание совпадения DNS A и AAAA для: ${DOMAINS[*]}"
else
	echo "Ожидание совпадения DNS A для: ${DOMAINS[*]}"
fi
echo

check_record() {
	local domain="$1" rr="$2" expect="$3" ns="$4" dns_name="$5"
	local -a answers=()
	local answer match=false

	case "$rr" in
	A)
		mapfile -t answers < <(
			dig +time=2 +tries=1 +short @"$ns" "$domain" A 2>/dev/null |
				grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
		)
		;;
	AAAA)
		# Only accept bare IPv6 tokens — dig stderr/timeout text also contains ':'.
		mapfile -t answers < <(
			dig +time=2 +tries=1 +short @"$ns" "$domain" AAAA 2>/dev/null |
				grep -E '^[0-9a-fA-F:]+$' | grep -E ':' || true
		)
		;;
	*)
		echo "❌ Внутренняя ошибка: неизвестный тип $rr"
		return 1
		;;
	esac

	if [[ ${#answers[@]} -eq 0 ]]; then
		echo "❌ [$dns_name / $ns] $domain — $rr не найдена (нет ответа или резолвер недоступен)."
		return 1
	fi

	for answer in "${answers[@]}"; do
		if ip_equal "$answer" "$expect"; then
			match=true
			break
		fi
	done

	if $match; then
		echo "✅ [$dns_name / $ns] $domain — $rr совпадает: ${answers[*]}"
		return 0
	fi

	echo "⚠️ [$dns_name / $ns] $domain — $rr не совпадает: ${answers[*]} ≠ $expect"
	return 1
}

# Work items: domain|rr|expect|ns|dns_name
declare -a PENDING=()

build_pending_all() {
	local domain entry ns dns_name
	PENDING=()
	for domain in "${DOMAINS[@]}"; do
		for entry in "${NAMESERVERS[@]}"; do
			IFS=':' read -r ns dns_name <<<"$entry"
			PENDING+=("${domain}|A|${EXPECT_IPV4}|${ns}|${dns_name}")
			if $CHECK_AAAA; then
				PENDING+=("${domain}|AAAA|${EXPECT_IPV6}|${ns}|${dns_name}")
			fi
		done
	done
}

run_pending_cycle() {
	local -a still_pending=()
	local item domain rr expect ns dns_name
	local prev_domain="" prev_rr=""
	local ok_count=0 fail_count=0

	for item in "${PENDING[@]}"; do
		IFS='|' read -r domain rr expect ns dns_name <<<"$item"

		if [[ "$domain" != "$prev_domain" ]]; then
			echo "🔍 Проверка домена: $domain"
			prev_domain="$domain"
			prev_rr=""
		fi
		if [[ "$rr" != "$prev_rr" ]]; then
			if [[ "$rr" == "A" ]]; then
				echo "— DNS A (IPv4 → $EXPECT_IPV4)"
			else
				echo "— DNS AAAA (IPv6 → $EXPECT_IPV6)"
			fi
			prev_rr="$rr"
		fi

		if check_record "$domain" "$rr" "$expect" "$ns" "$dns_name"; then
			ok_count=$((ok_count + 1))
		else
			still_pending+=("$item")
			fail_count=$((fail_count + 1))
		fi
	done

	PENDING=("${still_pending[@]+"${still_pending[@]}"}")
	echo
	echo "📊 В этом цикле: OK=$ok_count, осталось=$fail_count"
}

build_pending_all
cycle=1

while true; do
	total=${#PENDING[@]}
	if ((cycle == 1)); then
		echo "▶️ Цикл $cycle: полная проверка ($total проверок)"
	else
		echo "▶️ Цикл $cycle: только несовпавшие ($total проверок)"
	fi
	echo

	run_pending_cycle

	if [[ ${#PENDING[@]} -eq 0 ]]; then
		if $CHECK_AAAA; then
			echo "✅ Все DNS A/AAAA записи соответствуют публичным IPv4/IPv6 на всех указанных резолверах."
		else
			echo "✅ Все DNS A-записи соответствуют публичному IPv4 на всех указанных резолверах."
		fi
		exit 0
	fi

	if $ONCE; then
		echo "❌ DNS ещё не сошёлся (режим --once)."
		if $CHECK_AAAA; then
			echo "   dual: нужна и A=$EXPECT_IPV4, и AAAA=$EXPECT_IPV6"
		fi
		exit 1
	fi

	echo "⏳ Повтор через $INTERVAL с: осталось ${#PENDING[@]} резолвер(ов)/записей."
	echo "   (совпавшие больше не трогаем; dual требует и A, и AAAA)"
	sleep "$INTERVAL"
	cycle=$((cycle + 1))
done
