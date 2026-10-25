#!/usr/bin/env bash
# Live smoke for Xray admin plane on streambase (run on server or via SSH).
set -Eeuo pipefail

WEBDOMAIN="${WEBDOMAIN:?set WEBDOMAIN}"
PORT_LOCAL_ADMIN="${PORT_LOCAL_ADMIN:-9443}"
SUB_PATH="${URI_SUB_PATH:?set URI_SUB_PATH}"

echo "== break-glass localhost admin (expect 401 without auth) =="
for host in arcane homepage adguard traefik lampac-admin; do
  code=$(curl -k -sS -o /dev/null -w "%{http_code}" -H "Host: ${host}.${WEBDOMAIN}" \
    "https://127.0.0.1:${PORT_LOCAL_ADMIN}/" || true)
  echo "${host}: ${code}"
done
code=$(curl -k -sS -o /dev/null -w "%{http_code}" -H "Host: 3x-ui.${WEBDOMAIN}" \
  "https://127.0.0.1:${PORT_LOCAL_ADMIN}/${URI_PANEL_PATH:-panel}/" || true)
echo "3x-ui: ${code}"

echo "== public sub smoke =="
curl -fsS -o /dev/null -w "sub:%{http_code}\n" "https://${WEBDOMAIN}${SUB_PATH}" || \
  curl -k -fsS -o /dev/null -w "sub:%{http_code}\n" "https://${WEBDOMAIN}${SUB_PATH}"

echo "== public negative (old Arcane path should not be Arcane UI) =="
curl -k -sS -o /dev/null -w "old-arcane:%{http_code}\n" "https://${WEBDOMAIN}/${URI_ARCANE:-arcane}/" || true

echo "probe-live done"
