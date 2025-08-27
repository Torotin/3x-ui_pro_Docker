# **Install**

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Torotin/3x-ui_pro_Docker)

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/script"
INSTALL_SCRIPT="$TARGET_DIR/install.sh"
ETAG_FILE="$INSTALL_SCRIPT.etag"
URL="https://raw.githubusercontent.com/Torotin/3x-ui_pro_Docker/refs/heads/main/script/install.sh"

# Создаём каталог
sudo mkdir -p "$TARGET_DIR"

# Временный файл для возможного обновления
TMP="$(mktemp)"

# Пытаемся скачать, используя условный GET по ETag.
# Если файл не изменился, сервер вернёт 304 и тело не придёт.
HTTP_CODE="$(
  curl -sS -L -f \
    --etag-compare "$ETAG_FILE" \
    --etag-save "$ETAG_FILE" \
    --write-out '%{http_code}' \
    --output "$TMP" \
    "$URL"
)"

if [[ "$HTTP_CODE" == "304" ]]; then
  echo "install.sh уже актуален (304 Not Modified)."
  rm -f "$TMP"
else
  # Атомарно заменяем и выставляем права
  sudo install -m 0755 "$TMP" "$INSTALL_SCRIPT"
  rm -f "$TMP"
  echo "install.sh обновлён (HTTP $HTTP_CODE)."
fi

# Запуск
sudo "$INSTALL_SCRIPT"
```
