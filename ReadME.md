# 3x-ui_pro_Docker

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Torotin/3x-ui_pro_Docker)

`3x-ui_pro_Docker` — готовый Docker Compose стек для развертывания прокси-инфраструктуры вокруг Traefik, 3x-ui/Xray, AdGuard Home, CrowdSec, Caddy, Homepage, Lampac, WARP/usque и TOR helper-сервисов.

Репозиторий содержит сам стек, installer CLI/wizard, шаблоны окружения и тесты для безопасной локальной разработки. Собственные образы проекта собираются в [AutoDockerBuilder](https://github.com/Torotin/AutoDockerBuilder).

## Поддерживаемая платформа

- Debian/Ubuntu.
- `systemd` и `apt`.
- Docker Engine с Compose plugin.
- Root/sudo доступ на сервере для установки пакетов, Docker, firewall, SSH и sysctl-настроек.
- Локальная разработка installer выполняется только через mock/fake окружение.

## Быстрый старт

### Вариант 1: через wizard

```bash
cd /srv
git clone https://github.com/Torotin/3x-ui_pro_Docker.git
cd 3x-ui_pro_Docker

# Необязательно: каталог Docker-стека можно выбрать любой абсолютный путь.
export INSTALL_ROOT=/srv/docker-proxy

sudo script/install.sh doctor
sudo script/install.sh wizard
sudo script/install.sh doctor
```

### Вариант 2: командами без wizard

Перед batch-запуском задайте обязательные значения. `SSH_PBK` необязателен: если ключ задан, SSH будет настроен на public key auth; если не задан, будет включен password auth.

```bash
set -e

cd /srv
git clone https://github.com/Torotin/3x-ui_pro_Docker.git
cd 3x-ui_pro_Docker

chmod +x script/install.sh

export INSTALL_ROOT=/srv/docker-proxy
export WEBDOMAIN=example.com
export USER_SSH=deployer
export PASS_SSH='change-me'
export USER_WEB=admin
export PASS_WEB='change-me'
export PORT_REMOTE_SSH=22022

# Optional: public key for USER_SSH. If unset, installer keeps password auth.
export SSH_PBK='ssh-ed25519 ...'

sudo -E script/install.sh doctor
sudo -E script/install.sh run apt --apply --yes
sudo -E script/install.sh run env
sudo -E script/install.sh run docker --destroy-docker-data
sudo -E script/install.sh run user
sudo -E script/install.sh run firewall ssh network --apply --yes
sudo -E script/install.sh run compose
sudo -E script/install.sh run final
sudo -E script/install.sh doctor

# For detailed successful checks:
sudo -E script/install.sh doctor --verbose
```

Installer хранится отдельно от Docker-стека:

- `3x-ui_pro_Docker/script` — installer, модули, шаблоны, state, logs, summary.
- `INSTALL_ROOT` — рабочий каталог Docker Compose стека и runtime-данных сервисов. По умолчанию `/opt/docker-proxy`, но можно использовать любой абсолютный путь, например `/srv/docker-proxy`.

## Команды installer

```bash
script/install.sh doctor
script/install.sh wizard
script/install.sh run <step...> [--destroy-docker-data] [--apply] [--yes]
script/install.sh self-update [--branch <branch>] [--check] [--yes] [--force]
script/install.sh uninstall [--plan|--apply --yes]
```

Доступные шаги:

```bash
apt env docker user firewall ssh network compose final uninstall
```

Назначение основных команд:

- `doctor` — read-only диагностика ОС, команд, зависимостей, state, Docker, Compose и контейнеров.
- `wizard` — интерактивная установка с numbered menu и потоковым выводом операций.
- `run` — batch-запуск шагов.
- `self-update` — обновление installer из выбранной git-ветки по версии.
- `uninstall` — план или выполнение удаления проекта.

## Установка через wizard

Wizard запрашивает обязательные значения:

- `WEBDOMAIN` — домен.
- `USER_SSH` / `PASS_SSH` — системный пользователь.
- `USER_WEB` / `PASS_WEB` — BasicAuth для web-панелей.
- `SSH_PBK` — публичный SSH ключ, необязательно.

Если `SSH_PBK` задан, SSH переводится в режим public key auth. Если ключ не задан, включается password auth.

Остальные значения генерируются автоматически:

- публичные IPv4/IPv6;
- локальные и внешние порты;
- приватные URI для web-панелей;
- CrowdSec API keys;
- htpasswd hash для BasicAuth;
- AdGuard admin hash.

## Обновление installer

Installer обновляется явно из выбранной ветки:

```bash
sudo script/install.sh self-update --branch main --check
sudo script/install.sh self-update --branch main --yes
```

Версия installer хранится в `script/VERSION`, описание изменений — в `script/CHANGELOG.md`.

Поведение update:

- `--check` сравнивает локальную версию с версией в выбранной ветке.
- Если remote версия новее, выводится диапазон `local -> remote` и changelog только для версий выше текущей.
- Если версия не новее, выводится `self-update: up to date`.
- `--yes` применяет обновление только при наличии более новой версии.
- `--force` принудительно применяет обновление даже при равной или меньшей remote версии.

Wizard при старте автоматически проверяет обновление. Предложение обновиться показывается только если в репозитории есть версия выше локальной.

## Что разворачивается

- **Traefik** — HTTP router для ACME на `80/tcp` и внутреннего HTTPS `websecure :4443`.
- **3x-ui + Xray** — панель и runtime-автоматизация Xray desired state.
- **AdGuard Home** — DNS/DoH и web-панель.
- **CrowdSec** — анализ логов и bouncer-интеграция.
- **Caddy** — fallback/error backend и вспомогательная статика.
- **Homepage** — dashboard со ссылками на сервисы.
- **Lampac** — публичный browser front/fallback за цепочкой Xray → Traefik.
- **AmneziaWG** — опциональный Stage 6 UDP VPN на публичном `443/udp`.
- **WARP/usque/TOR** — proxy helper-сервисы для маршрутизации.
- **Dockcheck/logrotate** — эксплуатационные сервисы для обновлений и логов.

Compose fragments находятся в `docker-proxy/compose.d`. Host paths в них задаются относительно каталога `compose.d`, чтобы стек не зависел от хардкода `/opt/docker-proxy`.

Clean install использует staged-модель публичных портов: `80/tcp` публикует только Traefik для ACME HTTP-01 и безопасного redirect, `443/tcp` публикует 3x-ui/Xray REALITY, а Traefik `websecure :4443` остаётся только внутри Docker network. Browser HTTPS идёт по цепочке `client -> Xray 443/tcp -> REALITY self-steal/fallback -> Traefik :4443 -> Host router -> Lampac/admin service`.

Traefik dashboard, 3x-ui, AdGuard, Dozzle, Homepage и Lampac admin не имеют прямых published ports и не используют отдельные поддомены. Доступ к админкам публикуется только как HTTPS path-routes на основном `${WEBDOMAIN}` в формате `https://${WEBDOMAIN}/${SUMMARY_URL_*}` и защищается BasicAuth, CrowdSec middleware, rate-limit и security/noindex headers. Root-domain Lampac front и frontend API `/reqinfo` и `/testaccsdb` не защищаются BasicAuth, но sensitive paths Lampac (`/admin`, `/adminpanel`, `/stats`, `/weblog`) закрываются admin middleware.

Не открывайте наружу `4443`, `9118`, panel ports, metrics ports или CrowdSec ports. До включения отдельного AmneziaWG stage `443/udp` должен оставаться свободным; Traefik HTTP/3 и UDP entrypoints отключены.

## Stage 6: AmneziaWG

AmneziaWG включается только через `ENABLE_AMNEZIAWG=true`. До этого `run-compose.sh` исключает `15-amneziawg.yml`, а `doctor` ожидает, что публичный `443/udp` свободен. После включения единственным владельцем `443/udp` должен быть контейнер `amneziawg`; Traefik по-прежнему публикует только `80/tcp`, без HTTP/3 и без UDP.

Используемый image по умолчанию: `amneziavpn/amneziawg-go:0.2.17`. Он выбран из официального Docker Hub namespace `amneziavpn` и исходников `amnezia-vpn/amneziawg-go`; `latest` в production-конфигурации не используется. Обновление image выполняется явной сменой `AMNEZIAWG_IMAGE` после проверки runtime-модели.

Runtime-модель:

- Docker bridge networking, без подключения к `traefik-proxy` или `dns-net`.
- `/dev/net/tun` и capability `NET_ADMIN`.
- `privileged: true` не используется по умолчанию.
- `no-new-privileges=true` включён; если конкретный host/image докажет несовместимость с поднятием interface/NAT, отключение должно быть отдельным осознанным изменением.
- IPv4 egress включён через NAT. `AMNEZIAWG_NAT_BACKEND=auto` предпочитает `nft`, если он доступен в контейнере, иначе принимает только `iptables-nft`; legacy iptables не используется молча.
- IPv6 выключен по умолчанию (`AMNEZIAWG_IPV6_ENABLE=false`) и считается неподтверждённым до отдельной WAN-проверки.

Основные переменные:

- `ENABLE_AMNEZIAWG=false`
- `AMNEZIAWG_IMAGE=amneziavpn/amneziawg-go:0.2.17`
- `AMNEZIAWG_LISTEN_PORT=443`
- `AMNEZIAWG_INTERNAL_PORT=51820`
- `AMNEZIAWG_SERVER_ADDRESS=10.66.66.1/24`
- `AMNEZIAWG_CLIENT_IPV4_PREFIX=10.66.66`
- `AMNEZIAWG_CLIENT_COUNT=1`
- `AMNEZIAWG_CLIENT_DNS=1.1.1.1,8.8.8.8`
- `AMNEZIAWG_ENDPOINT_HOST=${WEBDOMAIN}`
- `AMNEZIAWG_MTU=1420`
- `AMNEZIAWG_NAT_BACKEND=auto`
- `AMNEZIAWG_JC=4`, `AMNEZIAWG_JMIN=64`, `AMNEZIAWG_JMAX=128`
- `AMNEZIAWG_S1=0`, `AMNEZIAWG_S2=0`, `AMNEZIAWG_H1=1`, `AMNEZIAWG_H2=2`, `AMNEZIAWG_H3=3`, `AMNEZIAWG_H4=4`

Client config создаётся в `$INSTALL_ROOT/amneziawg/clients/client1.conf`. Summary и логи печатают только путь к файлу, без приватных ключей, preshared keys или содержимого client config. Каталоги `server/`, `clients/`, `runtime/` имеют права `0700`, конфиги и ключи `0600`; они добавлены в `.gitignore`.

Удаление по умолчанию сохраняет AmneziaWG configs. Для удаления sensitive configs нужен явный флаг:

```bash
sudo script/install.sh uninstall --apply --yes --purge-amneziawg-configs
```

## Безопасность и destructive actions

Destructive и host-mutating действия требуют явного opt-in:

- APT mirror/update: `run apt --apply --yes`.
- Docker wipe/reinstall: `run docker --destroy-docker-data`.
- Firewall apply: `run firewall --apply --yes`.
- SSH apply: `run ssh --apply --yes`.
- Network/sysctl apply: `run network --apply --yes`.
- Uninstall purge: отдельные `--purge-*` флаги.

SSH apply логирует выбранный auth mode, пользователя, порт, backup, systemd unit, результат `sshd -t`, reload/restart и проверку listening port. Сначала применяется `systemctl reload`, restart используется только если reload не поднял новый порт или сервис требует полного перезапуска.

`doctor` не меняет окружение. Его можно запускать для диагностики до и после установки.

## Удаление

План без изменений:

```bash
sudo script/install.sh uninstall --plan
```

Остановка compose stack:

```bash
sudo script/install.sh uninstall --apply --yes
```

Полная очистка выбирается явно:

```bash
sudo script/install.sh uninstall --apply --yes \
  --purge-docker-data \
  --purge-docker-engine \
  --purge-firewall \
  --purge-ssh \
  --purge-network \
  --remove-project-root
```

Флаги удаления:

- `--purge-docker-data` — удаление compose volumes/images проекта и свободных внешних сетей.
- `--purge-docker-engine` — удаление Docker packages и `/var/lib/docker`, `/var/lib/containerd`.
- `--purge-firewall` — удаление известных UFW правил проекта без глобального `ufw reset`.
- `--purge-ssh` — восстановление backup `sshd_config`, проверка и reload/restart SSH.
- `--purge-network` — восстановление или удаление installer sysctl файла.
- `--purge-amneziawg-configs` — удаление `$INSTALL_ROOT/amneziawg/server` и `$INSTALL_ROOT/amneziawg/clients`; обычный uninstall их сохраняет.
- `--remove-project-root` — удаление `INSTALL_ROOT`.

## Файлы состояния

- `script/install-state/install.env` — состояние installer рядом с текущим `script/install.sh`, если `INSTALL_STATE_DIR` не переопределен.
- `$INSTALL_ROOT/compose.d/.env` — окружение Compose.
- `script/install-state/install.summary` — финальное резюме установки.
- `script/install-state/commands.log` — команды, прошедшие через runner.
- `script/install-state/install.log` — лог installer.

Для нестандартного размещения можно задать:

```bash
export INSTALL_ROOT=/srv/docker-proxy
export INSTALL_STATE_DIR=/srv/3x-ui-installer-state
```

## Локальная разработка и проверки

Installer локально тестируется только через mock/fake state dirs:

```bash
bash tests/install-scripts/run.sh
bash -n script/install.sh script/modules/*.sh script/check/*.sh
shellcheck -x -S warning script/install.sh script/modules/*.sh script/check/*.sh
```

Compose runner:

```bash
bash tests/run-compose/test_run_compose.bash
bash tests/run-compose/test_compose_startup_chain.bash
```

3x-ui runtime:

```bash
bash tests/3x-ui-scripts/run.sh
```

Общая проверка whitespace:

```bash
git diff --check
```

Локальные тесты installer не должны вызывать реальные `apt`, `docker`, `ufw`, `iptables`, `systemctl`, `sshd`, `modprobe`, `sysctl -p`, `useradd`, `chpasswd` и не должны писать в `/etc`, `/opt`, `/var/lib`.

## Серверная проверка

Минимальные тесты после установки:

```bash
sudo -E script/install.sh doctor
sudo -E "$INSTALL_ROOT/compose.d/run-compose.sh" validate
sudo -E "$INSTALL_ROOT/compose.d/run-compose.sh" up
sudo -E script/install.sh run final
```

Конкретный SSH endpoint тестового сервера не фиксируется в README или проектном контексте: он передается только на время серверной приемки.
