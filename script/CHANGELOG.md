# Журнал изменений установщика

## Unreleased

- Добавлен Stage 6 compose-фрагмент AmneziaWG, gated через `ENABLE_AMNEZIAWG=true`, с публикацией только `443/udp`.
- Добавлены defaults/env/summary для AmneziaWG без вывода приватных ключей и client configs.
- `doctor` проверяет владельца `443/udp`: до AmneziaWG порт должен быть свободен, после включения владельцем должен быть только `amneziawg`.
- Добавлен explicit purge-флаг `--purge-amneziawg-configs`; обычный uninstall сохраняет AmneziaWG server/client configs.

## 0.2.0 - 2026-05-09

- Добавлен versioned self-update: wizard предлагает обновление только при наличии более новой версии в выбранной ветке.
- Добавлен вывод описания изменений для версий выше текущей.
- Расширен `doctor`: проверяет команды, зависимости, состояние installer, Docker, Compose и контейнеры стека без изменения окружения.
- Обновлён wizard: потоковый вывод операций, ожидание Enter перед возвратом в меню, фильтрация лишнего compose-шума.
- Добавлены `uninstall`, финальный summary и mock-only проверки installer.
