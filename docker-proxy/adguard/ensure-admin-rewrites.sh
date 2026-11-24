#!/bin/sh
# Idempotent AdGuard DNS rewrites for private admin Hosts → Traefik 172.18.0.6
# POSIX sh + python3. Surgical edit of filtering.rewrites.
set -eu

WEBDOMAIN="${WEBDOMAIN:?WEBDOMAIN required}"
ANSWER="${ADMIN_REWRITE_ANSWER:-172.18.0.6}"
CONF="${ADGUARD_CONF:-}"
if [ -z "$CONF" ]; then
  if [ -f /opt/adguardhome/conf/AdGuardHome.yaml ]; then
    CONF=/opt/adguardhome/conf/AdGuardHome.yaml
  else
    CONF="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/conf/AdGuardHome.yaml"
  fi
fi
[ -f "$CONF" ] || { echo "AdGuardHome.yaml not found: $CONF" >&2; exit 1; }

export WEBDOMAIN ANSWER CONF
python3 - <<'PY'
import os
from pathlib import Path

webdomain = os.environ["WEBDOMAIN"]
answer = os.environ["ANSWER"]
path = Path(os.environ["CONF"])
hosts = [
    f"arcane.{webdomain}",
    f"homepage.{webdomain}",
    f"adguard.{webdomain}",
    f"3x-ui.{webdomain}",
    f"traefik.{webdomain}",
    f"lampac-admin.{webdomain}",
    f"telemt.{webdomain}",
]
host_set = set(hosts)
lines = path.read_text(encoding="utf-8").splitlines(True)
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    if stripped.startswith("- domain:"):
        domain = stripped.split(":", 1)[1].strip()
        if domain in host_set:
            i += 1
            # Skip existing answer/enabled lines for this domain block.
            while i < len(lines) and lines[i].lstrip().startswith(("answer:", "enabled:")):
                i += 1
            continue
    out.append(line)
    i += 1

block = "".join(
    f"    - domain: {h}\n      answer: {answer}\n      enabled: true\n" for h in hosts
)
text = "".join(out)
needle = "  safe_fs_patterns:"
if needle not in text:
    raise SystemExit("safe_fs_patterns marker not found")
# Avoid duplicating if already present with correct answer + enabled
already = all(
    (
        f"- domain: {h}" in text
        and f"answer: {answer}" in text
        and "enabled: true" in text
    )
    for h in hosts
)
if already:
    # still ensure answers match by rewrite pass above + reinsert
    pass
new_text = text.replace(needle, block + needle, 1)
if new_text != path.read_text(encoding="utf-8"):
    path.write_text(new_text, encoding="utf-8")
    print(f"updated admin rewrites in {path} → {answer}")
else:
    print(f"admin rewrites already correct in {path}")
PY
