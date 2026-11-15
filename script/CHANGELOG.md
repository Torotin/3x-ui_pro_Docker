# Журнал изменений установщика

## 0.7.9 - 2026-11-15

- APT: flock fallback for dpkg/apt locks when `fuser` is missing; do not create absent lock files.
- APT: never rewrite `security.ubuntu.com` when applying country/archive mirrors (classic + DEB822).
- APT: `force-confdef`/`force-confold` on install/upgrade; Release-timed Ubuntu mirror pick with curl timeouts.
- APT: Debian vs Ubuntu `unattended-upgrades` Allowed-Origins; drop duplicate real-path auto-install.
- Wizard: dark `NEWT_COLORS` theme for whiptail (honors preset env).
- Wizard: Quick Action `c` / `config` to edit required `install.env` variables (dirty save like toggles).
- Wizard: sequential menu keys 0–9 by display order; digit hotkeys + colored OK/FAIL badges in whiptail.
- SSH: rewrite `ssh.socket` ListenStream to `PORT_REMOTE_SSH` (`zz-3xui-port.conf`) so Port= in sshd_config is not ignored under socket activation.

## 0.7.8 - 2026-11-14

- Wizard: hybrid whiptail + ANSI text UI, step badges, Quick Actions (`auto`/`toggles`/`doctor`).
- Wizard: `install.sh wizard --yes|-y` skips non-destructive confirms; docker wipe always prompts.
- Wizard: feature toggles dirty-exit save-only; `WIZARD_UI=auto|whiptail|text`.

## 0.7.7 - 2026-11-13

- `dnscrypt`: после установки/reconfigure пишет `127.0.1.1 <hostname>` в `/etc/hosts`, если short-hostname отсутствует.
- Причина: `block_unqualified=true` в toml не отдаёт A/AAAA для имён без точки → `sudo: unable to resolve host` при пустом hosts.
- Doctor: проверка, что локальный hostname резолвится (hosts/getent).

## 0.7.6 - 2026-11-13

- `docker --destroy-docker-data`: перед purge останавливает `docker.socket`, затем `docker`, затем `containerd` (раньше socket оставался active и оставлял `overlay2/*/merged` busy).
- Перед `rm -rf /var/lib/docker|/var/lib/containerd` — lazy unmount дерева mounts; один retry при busy; иначе явный `die`.

## 0.7.5 - 2026-11-08

- `dnscrypt`: загрузка бинарника через GitHub Assets API (`Accept: application/octet-stream`) — обход 504 на `github.com/.../releases/download/...`.
- Fallback: browser URL с retry, зеркала `DNSCRYPT_DOWNLOAD_MIRRORS`, offline `--archive` / `DNSCRYPT_ARCHIVE_FILE`.
- Ясная ошибка с путём обхода, если все источники недоступны.

## 0.7.4 - 2026-10-31

- Wizard self-update check: если нет `git` (до шага apt) — явный skip вместо ложного «up to date» и ERROR по отсутствующему remote VERSION.
- `install_self_update_prepare`/`fetch_tree`: жёсткая проверка `git` и `script/VERSION` после clone; без `if ! (subshell)`, где bash глушит `set -e`.

## 0.7.3 - 2026-10-23

- Arcane path-prefix: семантические Traefik JS/HTML rewrites (без minify-имён), защита `arcane.yml` от Go-template в комментариях.
- Homepage: узкие NextAuth-пути вместо `PathPrefix(/api/auth)`, чтобы не перехватывать Arcane `/api/auth/login|me|…` (двойной Basic Auth).
- Регрессия: `tests/arcane/` + live probe; playbook `.project_context/04_playbooks/arcane_path_prefix.md`.

## 0.7.2 - 2026-10-18

- Dozzle заменён на Arcane (`07-arcane.yml`; legacy `07-dozzle.yml.disable`).

## 0.7.1 - 2026-10-16

- Финальный summary: UI Service URLs заканчиваются `/` (Homepage, 3X-UI, AdGuard, Arcane, Telemt, Mihomo), чтобы браузер не терял BasicAuth на 301.
- AdGuard DoH остаётся без trailing slash (exact `Path()` endpoint).

## 0.7.0 - 2026-10-16

- `run-compose.sh up`: по умолчанию `up -d --wait --wait-timeout` (`WAIT_TIMEOUT`, default `600`).
- Wizard compose: ticker «Compose step still running...» на время долгого `--wait`; фильтрация вывода — per-image pull, скрытие layer/timer/lock шума.
- Doctor inventory: `dockcheck` только при активном `01-dockcheck.yml/.yaml`; в базу добавлен `sub-json-processor`.
- Fail-fast в `install.sh`, если модуль doctor не экспортирует `install_doctor_command`.

## 0.6.0 - 2026-10-16

- Рефакторинг `doctor`: оркестрация в `script/modules/08_doctor.sh` (профили, фаза, severity, matrix, next-actions).
- Профили: `doctor` (full), `doctor host`, `doctor stack`; флаги `--verbose` и `--strict`.
- Severity: FAIL всегда ненулевой exit; WARN → exit 0, с `--strict` WARN → exit 1 и footer `doctor: FAILED`.
- Вывод: header (`profile` / `phase`), step matrix (`STEP STATUS SUMMARY NEXT`), next-actions, footer `doctor: OK|WARN|FAILED`.

## 0.5.0 - 2026-10-16

- Добавлен шаг `dnscrypt` (до `apt`): host DNS через DNSCrypt/DoH на `127.0.0.1:53`.
- Логика inlined в `script/modules/04_dnscrypt.sh`; по умолчанию latest с GitHub Releases (`--version` / `DNSCRYPT_VERSION` для pin).
- Wizard пункт `0`, doctor-проверки DNSCrypt, uninstall `--purge-dnscrypt`.

## 0.2.0 - 2026-05-09

- Добавлен versioned self-update: wizard предлагает обновление только при наличии более новой версии в выбранной ветке.
- Добавлен вывод описания изменений для версий выше текущей.
- Расширен `doctor`: проверяет команды, зависимости, состояние installer, Docker, Compose и контейнеры стека без изменения окружения.
- Обновлён wizard: потоковый вывод операций, ожидание Enter перед возвратом в меню, фильтрация лишнего compose-шума.
- Добавлены `uninstall`, финальный summary и mock-only проверки installer.
