# 3x-ui_pro_Docker — краткий мануал

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Torotin/3x-ui_pro_Docker)

Готовое Docker‑окружение для прокси/панелей: Traefik, 3x-ui (Xray), Caddy, AdGuard, CrowdSec, Lampac, Homepage и вспомогательные модули. Собственные образы собираются в [AutoDockerBuilder](https://github.com/Torotin/AutoDockerBuilder).

## Быстрый старт

```bash
git clone https://github.com/Torotin/3x-ui_pro_Docker.git
cd 3x-ui_pro_Docker
sudo script/install.sh doctor
sudo script/install.sh wizard
```

Установщик больше не является single-file bootstrap. Официальный путь запуска — из клона репозитория. Обновление скриптов выполняется явно:

```bash
sudo script/install.sh self-update --branch main --check
sudo script/install.sh self-update --branch main --yes
```

Wizard при старте проверяет возможность обновления и предлагает выполнить `self-update`, но не применяет изменения молча.

## Что разворачивается

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

1) **VLESS TCP Reality (Vision)**  
   - Протокол: `vless`  
   - Transport: `tcp` + Reality, fingerprint `chrome`, target Traefik (`traefik:<порт>`).  
   - PQ (ML‑KEM‑768) опционально: включается `USE_VLESS_PQ=true` (по умолчанию включено, decryption/encryption=`none`).  
   - mldsa65 для Reality также опционально: `USE_MLDSA65=true` (по умолчанию выключено).  
   - ShortIds генерируются; клиенты: flow `xtls-rprx-vision-udp443`, UUID генерируется.  

2) **VLESS XHTTP (маскировка под HTTP)**  
   - Протокол: `vless`, `network: xhttp`, `security: none`.  
   - Host/path берутся из переменных (`WEBDOMAIN`, `URI_VLESS_XHTTP`).  
   - Заголовки имитируют nginx (`Server`, `Content-Type`, CORS, keep-alive).  
   - Ограничения: `scMaxBufferedPosts=50`, `scMaxEachPostBytes=5000000`, `scStreamUpServerSecs=5-20`, `noSSEHeader=true`, `xPaddingBytes=100-1000`, режим `packet-up`.  
   - PQ для VLESS опционально тем же флагом `USE_VLESS_PQ` (по умолчанию выключено).  

Порты инбаундов задаются в `.env` (переменные `PORT_LOCAL_VISION`, `PORT_LOCAL_XHTTP` или аналогичные). Подписки/JSON‑эндпоинты формируются 3x-ui согласно basePath и subPath из `.env`.

## Требования

- Debian/Ubuntu, root и bash.
- systemd и apt.
- Доступ в интернет для загрузки образов и обновления из выбранной git-ветки.

## Команды установщика

```bash
script/install.sh doctor
script/install.sh wizard
script/install.sh run apt --apply --yes
script/install.sh run env compose
script/install.sh run docker --destroy-docker-data
script/install.sh run firewall --apply --yes
script/install.sh run ssh --apply --yes
script/install.sh run network --apply --yes
script/install.sh self-update --branch main --check
script/install.sh uninstall --plan
```

Доступные шаги для `run`: `apt`, `env`, `docker`, `user`, `firewall`, `ssh`, `network`, `compose`, `final`, `uninstall`.

Разрушительные действия требуют явного opt-in:

- Docker cleanup/reinstall: `--destroy-docker-data`.
- APT mirror/update, firewall/SSH/network apply: `--apply --yes` для неинтерактивного запуска.
- Удаление проекта: сначала `uninstall --plan`, затем `uninstall --apply --yes` и отдельные purge-флаги для системных изменений.

## Удаление с сервера

Сначала посмотрите план без изменений:

```bash
sudo script/install.sh uninstall --plan
```

Базовое применение останавливает compose stack через `compose.d/run-compose.sh down --remove-orphans`:

```bash
sudo script/install.sh uninstall --apply --yes
```

Дополнительные очистки включаются отдельно:

```bash
sudo script/install.sh uninstall --apply --yes \
  --purge-docker-data \
  --purge-docker-engine \
  --purge-firewall \
  --purge-ssh \
  --purge-network \
  --remove-project-root
```

Что делают purge-флаги:

- `--purge-docker-data` — добавляет compose `down --volumes --rmi local`, prune Docker volumes/networks с label проекта и удаление внешних сетей `traefik-proxy`/`dns-net`, если они свободны.
- `--purge-docker-engine` — дополнительно удаляет Docker engine packages и каталоги `/var/lib/docker`, `/var/lib/containerd`.
- `--purge-firewall` — удаляет известные правила UFW для `PORT_REMOTE_*`, `80/tcp`, `443/tcp`, `443/udp`; глобальный `ufw reset` не выполняется.
- `--purge-ssh` — восстанавливает последний backup `sshd_config` из `install-state/backups`, проверяет `sshd -t` и перезапускает SSH.
- `--purge-network` — восстанавливает backup `/etc/sysctl.d/99-xray.conf` или удаляет файл установщика, затем перезагружает sysctl.
- `--remove-project-root` — удаляет каталог проекта из `INSTALL_ROOT` после остальных шагов.

## Какие переменные спрашивает install.sh

Спрашиваются только ключевые значения, остальное генерируется:

- `WEBDOMAIN` — домен (обязательно).  
- `USER_SSH` / `PASS_SSH` — учётка системы (обязательно).
- `SSH_PBK` — ваш публичный ключ (ED25519/RSA), необязательно.
- `USER_WEB` / `PASS_WEB` — BasicAuth для панелей (обязательно).

Автоматически:

- `PUBLIC_IPV4/6` — определяются; при проблемах с IPv6 берётся IPv4.  
- Все `PORT_*` — свободные порты (≈20000–65000).  
- Все `URI_*` — случайные безопасные URI.  
- `CROWDSEC_API_KEY_*` — случайные ключи 32–48 символов.  
- `HT_PASS_ENCODED` — htpasswd из `USER_WEB/PASS_WEB`.  

Переменные можно задать заранее:  
`WEBDOMAIN=example.com USER_SSH=alice PASS_SSH='S3cure' sudo script/install.sh run env`

## Куда пишутся параметры

- `/opt/script/install-state/install.env` — состояние установщика.
- `/opt/docker-proxy/compose.d/.env` — окружение для Compose.
- `/opt/docker-proxy/compose.yml` + `compose.d/*.yml` — сервисы.

## Повторный запуск/обновление

Повторный запуск выполняется через `script/install.sh run <step...>`. Ветка для обновлений сохраняется в локальном state-файле установщика и может быть переопределена через `--branch`.

Локальная разработка и тесты установщика используют mock-режим и не должны вызывать реальные `apt`, `docker`, `ufw`, `iptables`, `systemctl`, `sshd`, `modprobe`, `sysctl -p`, `useradd`, `chpasswd` или писать в `/etc`, `/opt`, `/var/lib`. Боевое тестирование выполняется только на сервере.

## Безопасность

- Укажите свой `SSH_PBK`, смените сгенерированные пароли после установки.  
- Если задаёте `USER_WEB`, обязательно задайте и `PASS_WEB`, иначе htpasswd не будет создан.  
- Traefik dashboard/Caddy/3x-ui лучше закрывать BasicAuth/файрволом и использовать HTTPS.  
