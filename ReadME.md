# 3x-ui_pro_Docker — Установка и использование

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Torotin/3x-ui_pro_Docker)

**3x-ui_pro_Docker** — окружение для прокси на базе Docker с поддержкой Traefik, Caddy и 3x-ui.  
Собственные Docker-образы для этого проекта собираются в [AutoDockerBuilder](https://github.com/Torotin/AutoDockerBuilder).


## Быстрый старт

Скрипт загрузит актуальную версию `install.sh` с кешированием по ETag и запустит установщик.

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/script"
INSTALL_SCRIPT="$TARGET_DIR/install.sh"
ETAG_FILE="$INSTALL_SCRIPT.etag"
URL="https://raw.githubusercontent.com/Torotin/3x-ui_pro_Docker/refs/heads/main/script/install.sh"

# Создать каталог назначения
sudo mkdir -p "$TARGET_DIR"

# Временный файл для загрузки
TMP="$(mktemp)"

# Загрузка с учётом ETag (304 — без изменений)
HTTP_CODE="$(
  curl -sS -L -f \
    --etag-compare "$ETAG_FILE" \
    --etag-save "$ETAG_FILE" \
    --write-out '%{http_code}' \
    --output "$TMP" \
    "$URL"
)"

if [[ "$HTTP_CODE" == "304" ]]; then
  echo "install.sh не изменился (304 Not Modified)."
  rm -f "$TMP"
else
  # Установить права и поместить файл в целевой каталог
  sudo install -m 0755 "$TMP" "$INSTALL_SCRIPT"
  rm -f "$TMP"
  echo "install.sh обновлён (HTTP $HTTP_CODE)."
fi

# Запуск установщика
sudo "$INSTALL_SCRIPT"
```

## Требования

- Root-доступ и bash-окружение (Debian/Ubuntu совместимые).
- Доступ в интернет (загрузка шаблонов и модулей из GitHub).
- Docker/Docker Compose будут установлены скриптом при необходимости.

## Меню установщика

После запуска вы увидите меню шагов. Их можно выбирать по одному или диапазонами (например, `1,3 5 7` или `1-6`). Основные шаги:

- 1: System update — обновление системы
- 2: Docker. (Re)Install — установка/переустановка Docker и сети `traefik-proxy`
- 3: Docker. Generate docker dir — создание каталога `/opt/docker-proxy` и загрузка файлов
- 4: Docker. Generate docker env-file — генерация `/opt/docker-proxy/.env`
- 5: Create user — создание системного пользователя
- 6: Configure firewall — настройка firewall
- 7: Configure SSH — настройка SSH
- 8: Network optimization — оптимизация сетевых параметров
- 9: Docker. Run Compose — запуск `docker compose up -d`
- 10: Final message — итоговая сводка
- x: Exit — выход
- r: Reboot — перезагрузка

## Какие переменные запрашивает install.sh

Скрипт автоматически определяет часть параметров и запрашивает только ключевые данные. Ниже — все возможные запросы и поведение по умолчанию.

- WEBDOMAIN: домен для публикации сервисов. Запрашивается обязательно («Enter domain (WEBDOMAIN)»).
- USER_SSH: имя системного пользователя. Предлагается ввести («Enter username (USER_SSH)»); при пропуске — генерируется случайно.
- PASS_SSH: пароль системного пользователя. Предлагается ввести («Enter password (PASS_SSH)»); при пропуске — генерируется случайно.
- SSH_PBK: публичный SSH‑ключ (строка вида `ssh-ed25519 ...`). Предлагается ввести («Enter public key (SSH_PBK)»); при пропуске — оставляется пустым, будет сгенерирована локальная пара ED25519, а её публичный ключ добавлен в `authorized_keys`.
- USER_WEB: имя для базовой HTTP‑аутентификации (например, для панелей). Предлагается ввести («Enter username (USER_WEB)»); при пропуске — генерируется случайно. Если указали `USER_WEB`, обязательно укажите и `PASS_WEB`.
- PASS_WEB: пароль для базовой HTTP‑аутентификации. Предлагается ввести («Enter password (PASS_WEB)»); при пропуске — генерируется случайно. Используется для формирования `HT_PASS_ENCODED` (Apache htpasswd).

Что происходит автоматически:

- PUBLIC_IPV4/PUBLIC_IPV6: определяются автоматически. Если IPv6 недоступен/некорректен, подставляется IPv4.
- Все переменные, начинающиеся на `PORT_`: случайные свободные порты (диапазон ~20000–65000).
- Все переменные, начинающиеся на `URI_`: случайные безопасные URI‑фрагменты.
- CROWDSEC_API_KEY_*: случайные ключи 32–48 символов.
- HT_PASS_ENCODED: вычисляется автоматически из `USER_WEB`/`PASS_WEB` (если оба заданы).

Подсказка: можно переопределить значения через окружение перед запуском, например: `WEBDOMAIN=example.com USER_SSH=alice PASS_SSH='S3curePass' sudo ./install.sh`.

## Куда записываются параметры

- Файл окружения установщика: `install.env` рядом с `install.sh`.
- Docker Compose окружение: `/opt/docker-proxy/.env`.
- Compose файл: `/opt/docker-proxy/compose.yml`.

## Обновление/повторный запуск

Перезапуск вышеуказанного «Быстрый старт» блока проверит ETag и скачает новую версию только при изменении. Повторный запуск `install.sh` позволяет выбрать нужные шаги повторно (например, только генерацию `.env` и рестарт Compose).

## Примечания безопасности

- Рекомендуется указать собственный `SSH_PBK` (ваш публичный ключ) и сменить сгенерированные пароли после установки.
- Если задаёте `USER_WEB`, обязательно задайте и `PASS_WEB`, иначе htpasswd не будет сгенерирован.
