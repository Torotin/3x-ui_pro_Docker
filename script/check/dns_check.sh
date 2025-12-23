#!/bin/bash
clear

# Проверка утилит
command -v dig >/dev/null || { echo "❌ Требуется утилита 'dig'. Установите пакет 'dnsutils' или 'bind-tools'."; exit 1; }
command -v curl >/dev/null || { echo "❌ Требуется 'curl'. Установите через apt, apk или другой пакетный менеджер."; exit 1; }

# Загрузка .env, если он есть
ENV_FILE="install.env"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

# Получение доменов
DOMAINS=()

# 1. Из переменной WEBDOMAIN из .env
if [[ -n "${WEBDOMAIN:-}" ]]; then
  DOMAINS+=($WEBDOMAIN)
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
  "1.1.1.1:Cloudflare"
  "1.0.0.1:Cloudflare-2"
  "8.8.8.8:Google"
  "8.8.4.4:Google-2"
  "9.9.9.9:Quad9"
  "149.112.112.112:Quad9-2"
)

INTERVAL=15  # секунд между проверками

# Получение текущего внешнего IP
CURRENT_IP=$(curl -s ifconfig.me)

if [[ -z "$CURRENT_IP" ]]; then
  echo "❌ Не удалось получить внешний IP сервера."
  exit 1
fi

echo "🌐 Текущий внешний IP сервера: $CURRENT_IP"
echo "Ожидание совпадения DNS-записей доменов с этим IP: ${DOMAINS[*]}"
echo

while true; do
  all_matched=true

    for domain in "${DOMAINS[@]}"; do
    echo "🔍 Проверка домена: $domain"

    for entry in "${NAMESERVERS[@]}"; do
      IFS=':' read -r ns dns_name <<< "$entry"
      ips=($(dig +short @"$ns" "$domain" A | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'))

      if [[ ${#ips[@]} -eq 0 ]]; then
        echo "❌ [$dns_name / $ns] $domain — A-запись не найдена или ошибка связи."
        all_matched=false
      else
        match=false
        for ip in "${ips[@]}"; do
          if [[ "$ip" == "$CURRENT_IP" ]]; then
            match=true
            break
          fi
        done

        if $match; then
          echo "✅ [$dns_name / $ns] $domain — IP совпадает: ${ips[*]}"
        else
          echo "⚠️ [$dns_name / $ns] $domain — IP не совпадает: ${ips[*]} ≠ $CURRENT_IP"
          all_matched=false
        fi
      fi
    done

    echo
  done


  if $all_matched; then
    echo "✅ Все DNS-записи соответствуют текущему IP на всех указанных серверах."
    break
  fi

  echo "⏳ Повторная проверка через $INTERVAL секунд..."
  sleep "$INTERVAL"
done
