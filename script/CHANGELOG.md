# Журнал изменений установщика

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
