#!/bin/bash
clear

# Проверка утилит
command -v dig >/dev/null || {
	echo "❌ Требуется утилита 'dig'. Установите пакет 'dnsutils' или 'bind-tools'."
	exit 1
}
command -v curl >/dev/null || {
	echo "❌ Требуется 'curl'. Установите через apt, apk или другой пакетный менеджер."
	exit 1
}

# Загрузка .env, если он есть
ENV_FILE="install.env"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
fi

# Получение доменов
DOMAINS=()

# 1. Из переменной WEBDOMAIN из .env
if [[ -n "${WEBDOMAIN:-}" ]]; then
	DOMAINS+=("$WEBDOMAIN")
fi

# 2. Из аргументов, если есть
if [[ $# -gt 0 ]]; then
	DOMAINS+=("$@")
fi

# 3. Если доменов всё ещё нет — ошибка
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
	echo "❌ Не заданы домены для проверки."
	echo "Вы можете:"
	echo "  - указать домены как аргументы: ./script.sh example.com"
	echo "  - или задать переменную WEBDOMAIN в .env файле"
	exit 1
fi

NAMESERVERS=(
	# Cloudflare
	"1.1.1.1:Cloudflare"
	"1.0.0.1:Cloudflare-2"

	# Google
	"8.8.8.8:Google"
	"8.8.4.4:Google-2"

	# Quad9
	"9.9.9.9:Quad9"
	"149.112.112.112:Quad9-2"

	# OpenDNS (Cisco)
	"208.67.222.222:OpenDNS"
	"208.67.220.220:OpenDNS-2"

	# AdGuard DNS
	"94.140.14.14:AdGuard"
	"94.140.15.15:AdGuard-2"

	# CleanBrowsing
	"185.228.168.9:CleanBrowsing"
	"185.228.169.9:CleanBrowsing-2"

	# DNS.WATCH (Germany)
	"84.200.69.80:DNSWatch"
	"84.200.70.40:DNSWatch-2"

	# UncensoredDNS (Denmark)
	"91.239.100.100:UncensoredDNS"
	"89.233.43.71:UncensoredDNS-2"

	# Comodo Secure DNS
	"8.26.56.26:Comodo"
	"8.20.247.20:Comodo-2"

	# Level3 / Lumen
	"4.2.2.1:Level3"
	"4.2.2.2:Level3-2"

	# --- РФ сегмент ---

	# Яндекс DNS
	"77.88.8.8:Yandex"
	"77.88.8.1:Yandex-2"

	# Ростелеком (часто используется как ISP DNS)
	# "194.85.92.10:Rostelecom"
	# "194.85.92.20:Rostelecom-2"

	# МГТС / МТС (вариативно, но часто доступны)
	# "212.1.224.6:MTS"
	# "212.1.244.6:MTS-2"
)

INTERVAL=15 # секунд между проверками

CHECK_AAAA=false
if [[ -n "${PUBLIC_IPV6:-}" ]]; then
	CHECK_AAAA=true
fi

# Ожидаемый IPv4: из env или curl
if [[ -n "${PUBLIC_IPV4:-}" ]]; then
	EXPECT_IPV4=$PUBLIC_IPV4
else
	EXPECT_IPV4=$(curl -s ifconfig.me)
	if [[ -z "$EXPECT_IPV4" ]]; then
		echo "❌ Не удалось получить внешний IPv4 сервера."
		exit 1
	fi
fi

echo "🌐 Ожидаемый IPv4 сервера: $EXPECT_IPV4"
if $CHECK_AAAA; then
	echo "🌐 Ожидаемый IPv6 сервера: $PUBLIC_IPV6"
	echo "Ожидание совпадения DNS A и AAAA доменов: ${DOMAINS[*]}"
else
	echo "Ожидание совпадения DNS A-записей доменов с IPv4: ${DOMAINS[*]}"
fi
echo

while true; do
	all_matched=true

	for domain in "${DOMAINS[@]}"; do
		echo "🔍 Проверка домена: $domain"

		for entry in "${NAMESERVERS[@]}"; do
			IFS=':' read -r ns dns_name <<<"$entry"
			mapfile -t ips < <(dig +short @"$ns" "$domain" A | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')

			if [[ ${#ips[@]} -eq 0 ]]; then
				echo "❌ [$dns_name / $ns] $domain — A-запись не найдена или ошибка связи."
				all_matched=false
			else
				match=false
				for ip in "${ips[@]}"; do
					if [[ "$ip" == "$EXPECT_IPV4" ]]; then
						match=true
						break
					fi
				done

				if $match; then
					echo "✅ [$dns_name / $ns] $domain — A совпадает: ${ips[*]}"
				else
					echo "⚠️ [$dns_name / $ns] $domain — A не совпадает: ${ips[*]} ≠ $EXPECT_IPV4"
					all_matched=false
				fi
			fi
		done

		if $CHECK_AAAA; then
			for entry in "${NAMESERVERS[@]}"; do
				IFS=':' read -r ns dns_name <<<"$entry"
				mapfile -t v6s < <(dig +short @"$ns" "$domain" AAAA | grep -E ':')

				if [[ ${#v6s[@]} -eq 0 ]]; then
					echo "❌ [$dns_name / $ns] $domain — AAAA-запись не найдена или ошибка связи."
					all_matched=false
				else
					match=false
					for ip in "${v6s[@]}"; do
						if [[ "${ip,,}" == "${PUBLIC_IPV6,,}" ]]; then
							match=true
							break
						fi
					done

					if $match; then
						echo "✅ [$dns_name / $ns] $domain — AAAA совпадает: ${v6s[*]}"
					else
						echo "⚠️ [$dns_name / $ns] $domain — AAAA не совпадает: ${v6s[*]} ≠ $PUBLIC_IPV6"
						all_matched=false
					fi
				fi
			done
		fi

		echo
	done

	if $all_matched; then
		if $CHECK_AAAA; then
			echo "✅ Все DNS A/AAAA записи соответствуют текущим публичным IP на всех указанных серверах."
		else
			echo "✅ Все DNS A-записи соответствуют текущему IPv4 на всех указанных серверах."
		fi
		break
	fi

	echo "⏳ Повторная проверка через $INTERVAL секунд..."
	sleep "$INTERVAL"
done
