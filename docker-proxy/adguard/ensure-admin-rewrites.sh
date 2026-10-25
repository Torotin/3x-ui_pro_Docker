#!/usr/bin/env bash
# Idempotent AdGuard DNS rewrites for private admin Hosts → Traefik 172.18.0.6
# Surgical edit of filtering.rewrites — does not rewrite the whole YAML file.
set -Eeuo pipefail

WEBDOMAIN="${WEBDOMAIN:?WEBDOMAIN required}"
ANSWER="${ADMIN_REWRITE_ANSWER:-172.18.0.6}"
CONF="${ADGUARD_CONF:-}"
if [[ -z "$CONF" ]]; then
  if [[ -f /opt/adguardhome/conf/AdGuardHome.yaml ]]; then
    CONF=/opt/adguardhome/conf/AdGuardHome.yaml
  else
    CONF="$(cd "$(dirname "$0")" && pwd)/conf/AdGuardHome.yaml"
  fi
fi
[[ -f "$CONF" ]] || { echo "AdGuardHome.yaml not found: $CONF" >&2; exit 1; }

HOSTS=(
  "arcane.${WEBDOMAIN}"
  "homepage.${WEBDOMAIN}"
  "adguard.${WEBDOMAIN}"
  "3x-ui.${WEBDOMAIN}"
  "traefik.${WEBDOMAIN}"
  "lampac-admin.${WEBDOMAIN}"
)

need_write=0
work=$(mktemp)
trap 'rm -f "$work" "$work".stripped' EXIT
cp "$CONF" "$work"

# Drop any existing entries for our admin FQDNs (IPv4/IPv6) so we can re-add cleanly.
python3 - "$work" "${HOSTS[@]}" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
hosts = set(sys.argv[2:])
lines = path.read_text(encoding="utf-8").splitlines(True)
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    if stripped.startswith("- domain:"):
        domain = stripped.split(":", 1)[1].strip()
        if domain in hosts:
            # skip domain line and following answer line(s) belonging to this entry
            i += 1
            while i < len(lines) and lines[i].lstrip().startswith("answer:"):
                i += 1
            continue
    out.append(line)
    i += 1
path.write_text("".join(out), encoding="utf-8")
PY

# Insert six rewrites immediately before safe_fs_patterns under filtering.
block=""
for host in "${HOSTS[@]}"; do
  block+="    - domain: ${host}"$'\n'
  block+="      answer: ${ANSWER}"$'\n'
done

python3 - "$work" "$block" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
block = sys.argv[2]
text = path.read_text(encoding="utf-8")
needle = "  safe_fs_patterns:"
if needle not in text:
    raise SystemExit("safe_fs_patterns marker not found")
if all(h in text for h in ("arcane.", "lampac-admin.")):
    # already present from a previous partial run — still rewrite below
    pass
path.write_text(text.replace(needle, block + needle, 1), encoding="utf-8")
PY

if ! cmp -s "$CONF" "$work"; then
  cp "$work" "$CONF"
  echo "updated admin rewrites in $CONF → $ANSWER"
  need_write=1
else
  echo "admin rewrites already correct in $CONF"
fi
exit 0
