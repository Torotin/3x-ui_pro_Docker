# 3x-ui_pro_Docker — краткий мануал

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Torotin/3x-ui_pro_Docker)

Готовое Docker‑окружение для прокси/панелей: Traefik, 3x-ui (Xray), Caddy, AdGuard, CrowdSec, Lampac, Homepage и вспомогательные модули. Собственные образы собираются в [AutoDockerBuilder](https://github.com/Torotin/AutoDockerBuilder).

## Быстрый старт (загрузить установщик из GitHub)

Скрипт ниже скачает свежий `install.sh` с кешированием по ETag и запустит его.

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/script"
INSTALL_SCRIPT="$TARGET_DIR/install.sh"
ETAG_FILE="$INSTALL_SCRIPT.etag"
URL="https://raw.githubusercontent.com/Torotin/3x-ui_pro_Docker/refs/heads/main/script/install.sh"

sudo mkdir -p "$TARGET_DIR"
TMP="$(mktemp)"

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
  sudo install -m 0755 "$TMP" "$INSTALL_SCRIPT"
  rm -f "$TMP"
  echo "install.sh обновлён (HTTP $HTTP_CODE)."
fi

sudo "$INSTALL_SCRIPT"
```

## Что разворачивается (без sub2sing)

- **Traefik** — фронтовый reverse‑proxy и ACME, терминирует TLS, маршрутизирует HTTP/S к сервисам.
- **Caddy** — вспомогательный веб‑сервер (статика/проксирование бэкендов).
- **3x-ui + Xray core** — панель управления и сам Xray, автоконфиг инбаундов.
- **AdGuard Home** — DNS‑фильтрация и блокировка рекламы/трекеров.
- **CrowdSec** — анализ логов/поведенческая защита; может выдавать bouncer‑решения.
- **Lampac** — медиаменеджер/доп. сервис (работает через общий Traefik).
- **Homepage** — дашборд для быстрых ссылок на сервисы/статус.
- **WARP helper** — регистрация WireGuard‑ключей и outbound’ов Cloudflare WARP (для Xray).
- **Поддержка**: автообновление GeoIP/GeoSite, скрипты оптимизации сети, резервные модули AfterStart.

## Как работают сервисы

- **Traefik**: вход 80/443, умеет HTTP‑01/ALPN для сертификатов, имеет dashboard (можно скрыть/закрыть по BasicAuth). Маршруты на 3x-ui, Caddy, AdGuard, Homepage и др.
- **3x-ui**: панель на кастомном домене/портах из `.env`, API используется модулями AfterStart. Запускает Xray и управляет инбаундами.
- **Xray (core)**: конфиг собирается и обновляется модулями; поддерживает PQ‑ключи (ML‑KEM‑768) для VLESS; может перезапускаться через API или локальный бинарник.
- **AdGuard Home**: DNS‑сервер с веб‑панелью, фильтры по спискам, статистика запросов.
- **Caddy**: может подхватывать статический контент/прокси; служит «тихим» бэкендом для маскировки.
- **CrowdSec**: читает логи (Traefik/SSH и т.п.), применяет решения (ban/allow); API‑ключи формируются установщиком.
- **Lampac**: отдельный сервис под медиа/интеграции (доступ через Traefik).
- **Homepage**: стартовая страница с ссылками на панели и статусом сервисов.
- **WARP helper**: генерирует WireGuard‑ключи, добавляет outbounds/balancer в Xray при необходимости.

## Какие инбаунды создаёт 3x-ui (по AfterStart)

1) **VLESS TCP Reality (Vision + PQ)**  
   - Протокол: `vless`  
   - Transport: `tcp` + Reality, fingerprint `chrome`, target Traefik (`traefik:<порт>`).  
   - Шифрование: ML‑KEM‑768 (Post‑Quantum) decryption/encryption, `selectedAuth` проставляется автоматически.  
   - ShortIds генерируются; mldsa65 можно включить переменной `USE_MLDSA65=true`.  
   - Клиенты: flow `xtls-rprx-vision-udp443`, UUID генерируется.  

2) **VLESS XHTTP (маскировка под HTTP)**  
   - Протокол: `vless`, `network: xhttp`, `security: none`.  
   - Host/path берутся из переменных (`WEBDOMAIN`, `URI_VLESS_XHTTP`).  
   - Заголовки имитируют nginx (`Server`, `Content-Type`, CORS, keep-alive).  
   - Ограничения: `scMaxBufferedPosts=50`, `scMaxEachPostBytes=5000000`, `scStreamUpServerSecs=5-20`, `noSSEHeader=true`, `xPaddingBytes=100-1000`, режим `packet-up`.  
   - Подтягивает VLESS PQ‑пары через `getNewVlessEnc`, проставляет `selectedAuth`.  

Порты инбаундов задаются в `.env` (переменные `PORT_LOCAL_VISION`, `PORT_LOCAL_XHTTP` или аналогичные). Подписки/JSON‑эндпоинты формируются 3x-ui согласно basePath и subPath из `.env`.

## Требования

- Root и bash (Debian/Ubuntu‑совместимые).
- Доступ в интернет для загрузки шаблонов/модулей/образов.
- Docker и Docker Compose устанавливаются скриптом при отсутствии.

## Шаги установщика (меню)

Шаги выбираются числом или диапазоном (`1,3 5 7`, `1-6`):

1. System update  
2. Docker. (Re)Install (сеть `traefik-proxy`)  
3. Docker. Generate docker dir (`/opt/docker-proxy`, загрузка файлов)  
4. Docker. Generate docker env-file (`/opt/docker-proxy/.env`)  
5. Create user  
6. Configure firewall  
7. Configure SSH  
8. Network optimization  
9. Docker. Run Compose (`docker compose up -d`)  
10. Final message  
`x` — Exit, `r` — Reboot  

## Какие переменные спрашивает install.sh

Спрашиваются только ключевые значения, остальное генерируется:

- `WEBDOMAIN` — домен (обязательно).  
- `USER_SSH` / `PASS_SSH` — учётка системы (можно пропустить, будет сгенерировано).  
- `SSH_PBK` — ваш публичный ключ (ED25519/RSA). Если пусто — генерится новый ключ.  
- `USER_WEB` / `PASS_WEB` — BasicAuth для панелей (если указали логин, задайте и пароль).  

Автоматически:

- `PUBLIC_IPV4/6` — определяются; при проблемах с IPv6 берётся IPv4.  
- Все `PORT_*` — свободные порты (≈20000–65000).  
- Все `URI_*` — случайные безопасные URI.  
- `CROWDSEC_API_KEY_*` — случайные ключи 32–48 символов.  
- `HT_PASS_ENCODED` — htpasswd из `USER_WEB/PASS_WEB`.  

Переменные можно задать заранее:  
`WEBDOMAIN=example.com USER_SSH=alice PASS_SSH='S3cure' sudo ./install.sh`

## Куда пишутся параметры

- `install.env` — рядом с `install.sh`.  
- `/opt/docker-proxy/.env` — окружение для Compose.  
- `/opt/docker-proxy/compose.yml` + `compose.d/*.yml` — сервисы.  

## Повторный запуск/обновление

Повторный запуск блока «Быстрый старт» скачает новый `install.sh` только при изменении ETag. Сам установщик можно запускать повторно для отдельных шагов (например, регенерация `.env` и `docker compose up -d`).

## Безопасность

- Укажите свой `SSH_PBK`, смените сгенерированные пароли после установки.  
- Если задаёте `USER_WEB`, обязательно задайте и `PASS_WEB`, иначе htpasswd не будет создан.  
- Traefik dashboard/Caddy/3x-ui лучше закрывать BasicAuth/файрволом и использовать HTTPS.  
