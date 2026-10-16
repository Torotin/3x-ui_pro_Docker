# Журнал изменений установщика

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
