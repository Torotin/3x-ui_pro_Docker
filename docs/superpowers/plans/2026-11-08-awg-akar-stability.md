# AWG akar stability canary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On canary host `vps-intezio-akar`, retune AmneziaWG inbound id=5 to an AmneziaWG 3.1-hygiene profile (equal S, HP-compatible H, keepalive 25, cookies off) so prizrak healthchecks for `🇵🇱 amneziawg` stop flapping and real traffic stays up.

**Architecture:** One-shot live canary via panel inbound update (full `settings` echo to preserve keys) + prizrak provider refresh. No compose/port/backend change. Observation uses prizrak API `192.168.10.1:9090`. Rollback restores the pre-change `settings` backup.

**Tech Stack:** SSH host `vps-intezio-akar`; 3x-ui panel API (`/panel/api/inbounds/update/5`); sqlite/python for backup verify; prizrak-core REST API; bash/python operator scripts under `/tmp` (not committed secrets).

**Spec:** `docs/superpowers/specs/2026-11-08-awg-akar-stability-design.md`

## Global Constraints

- Canary host only: **`vps-intezio-akar`** (do not touch vdsina/streambase in this plan).
- Inbound: **id=5**, remark `🇵🇱 amneziawg`, port **443/udp**, protocol `amneziawg`.
- Never rotate **`HeaderProtectionKey`**, server keypair, or client keypairs/`allowedIPs` unless rollback of a failed key-corrupting update requires the backup.
- Always re-send stored `server.privateKey` / `server.publicKey` and every client peer credential on update.
- Never print PrivateKey, PSK, HeaderProtectionKey, or full `vpn://` / client conf in chat or commits.
- Target profile (verbatim from spec): `S1–S4=16`, `H1–H4=1/2/3/4`, `RandomTrailers=on`, `DisableCookies=off`, `Jc≈4`, `Jmin–Jmax≈50–120`, `ContentPaddingAddition≈0-16`, client `keepAlive=25`.
- Keep existing `I1` unless empty; never paste Amnezia docs demo CPS.
- `docs/` is gitignored — use `git add -f` for plan/evidence markdown commits.
- Success = **both** prizrak history stability **and** manual traffic smoke.

## File Structure

| Path | Responsibility |
|---|---|
| `/tmp/awg-akar-backup/` on akar (host) | Timestamped JSON backup of inbound settings + redacted snapshot |
| `/tmp/awg-akar-apply.py` (scp’d, not committed) | Read DB/API settings, patch profile, call panel update, verify publicKey unchanged |
| `/tmp/awg-akar-verify-server.sh` (scp’d) | Assert live server params + UDP 443 listen |
| Local `C:\Users\...\Temp\prizrak-awg-watch.py` | Poll provider `akar` / `🇵🇱 amneziawg` history |
| Local ops note (outside git; do not commit) | Sanitized before/after delays + checklist |
| `.project_context/02_state/last_changes.md` | One-line outcome after canary |

No production repo code changes are required for the canary itself. Encoding the profile into `build_amneziawg_settings_json` is **out of this plan** (follow-up after canary success).

---

### Task 1: Baseline + backup on akar

**Files:**
- Create on server: `/opt/docker-proxy/_backup/awg-akar-stability-<UTC>/inbound-5-settings.json`
- Create on server: `/opt/docker-proxy/_backup/awg-akar-stability-<UTC>/inbound-5-redacted.json`
- Create local (optional): capture prizrak history baseline into evidence draft

**Interfaces:**
- Produces: backup path env `AWG_BACKUP_DIR`; redacted param dump for chat/evidence
- Consumes: `vps-intezio-akar` SSH; docker `3x-ui` with `/etc/x-ui/x-ui.db`

- [ ] **Step 1: Capture prizrak baseline (local LAN)**

```powershell
python - <<'PY'
import json, urllib.request
BASE="http://192.168.10.1:9090"
prov=json.load(urllib.request.urlopen(BASE+"/providers/proxies", timeout=15))["providers"]["akar"]
node=next(p for p in prov["proxies"] if p.get("name")=="🇵🇱 amneziawg")
print("alive", node.get("alive"))
for h in (node.get("history") or [])[-12:]:
    print(h.get("time"), h.get("delay"))
PY
```

Expected: alternating non-zero and `0` delays (current flap). Save output for evidence.

- [ ] **Step 2: Write and scp backup script**

Create `C:\Users\torotin\AppData\Local\Temp\awg-akar-backup.sh` (LF) with:

```bash
#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date -u +%Y%m%d%H%M%S)
DIR=/opt/docker-proxy/_backup/awg-akar-stability-$STAMP
mkdir -p "$DIR"
TMP=/tmp/x-ui-awg-backup.db
docker cp 3x-ui:/etc/x-ui/x-ui.db "$TMP"
python3 - <<PY
import json, sqlite3
from pathlib import Path
backup_dir = Path("$DIR")
con = sqlite3.connect("$TMP")
con.row_factory = sqlite3.Row
row = con.execute(
    "select id, remark, port, protocol, enable, settings from inbounds where id=5"
).fetchone()
assert row is not None
assert row["protocol"] == "amneziawg" and int(row["port"]) == 443 and int(row["enable"]) == 1
settings = json.loads(row["settings"])
(backup_dir / "inbound-5-settings.json").write_text(
    json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
srv = dict(settings.get("server") or {})
for k in list(srv):
    if "key" in k.lower() or "secret" in k.lower():
        v = srv[k]
        srv[k] = f"<redacted len={len(str(v))}>" if v else v
red = {
    "remark": row["remark"],
    "clients_count": len(settings.get("clients") or []),
    "server": srv,
    "client_emails": [c.get("email") for c in (settings.get("clients") or [])],
    "client_keepAlives": [c.get("keepAlive") for c in (settings.get("clients") or [])],
}
(backup_dir / "inbound-5-redacted.json").write_text(
    json.dumps(red, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print("backup_dir=", backup_dir)
print(json.dumps(red, ensure_ascii=False, indent=2))
PY
echo "AWG_BACKUP_DIR=$DIR"
```

Deploy:

```powershell
# normalize LF then:
scp -o BatchMode=yes $env:TEMP\awg-akar-backup.sh vps-intezio-akar:/tmp/awg-akar-backup.sh
ssh -o BatchMode=yes vps-intezio-akar 'sudo bash /tmp/awg-akar-backup.sh'
```

Expected: prints `backup_dir=...`, redacted server params with unequal S and `keepAlive` null/missing, `protocol amneziawg`.

- [ ] **Step 3: Record backup path**

Save `AWG_BACKUP_DIR` from step 2 output into the session notes / evidence file header. Do not commit the full settings JSON.

- [ ] **Step 4: Commit evidence stub only if desired**

Optional — skip if no repo evidence yet. Otherwise create sanitized stub and `git add -f`.

---

### Task 2: Apply target profile via panel API (akar)

**Files:**
- Create/scp: `/tmp/awg-akar-apply.py` on akar
- Modify live: panel inbound id=5 `settings` (via API)
- Read: `/opt/docker-proxy/_backup/awg-akar-stability-*/inbound-5-settings.json`

**Interfaces:**
- Consumes: backup settings JSON; panel cookie/CSRF or `XUI_API_TOKEN` inside container network
- Produces: updated inbound; exit non-zero if `server.publicKey` changed

- [ ] **Step 1: Author apply script with hard safety checks**

`/tmp/awg-akar-apply.py` must:

1. Load backup settings from `AWG_BACKUP_DIR/inbound-5-settings.json` (or live DB if backup path passed).
2. Deep-copy `settings`.
3. Patch `settings["server"]` fields (keep all keys not listed):

```python
TARGET = {
    "s1": 16, "s2": 16, "s3": 16, "s4": 16,
    "h1": "1", "h2": "2", "h3": "3", "h4": "4",
    "jc": 4, "jmin": 50, "jmax": 120,
    "randomTrailers": True,
    "disableCookies": False,
    "contentPaddingAddition": "0-16",
}
# Do NOT touch headerProtectionKey / privateKey / publicKey
# Keep i1 if present; if missing set "<r 55>" only as last resort (prefer keep)
```

4. For each client in `settings["clients"]`, set `keepAlive` to integer `25` without removing other fields.
5. Assert before POST:
   - `server.privateKey` and `server.publicKey` non-empty
   - every client has `privateKey`, `publicKey`, and non-empty `allowedIPs`
6. Build full inbound update body from `GET /panel/api/inbounds/get/5` (or list), replace only `settings` with the patched object (as nested object or JSON string — match what this panel version accepts; prefer nested object).
7. `POST /panel/api/inbounds/update/5` with CSRF session login if `XUI_API_TOKEN` empty (same pattern as prior akar attach scripts: `/csrf-token` + `/login` + cookie jar).
8. Re-fetch inbound; assert `server.publicKey` **identical** to pre-update; assert S equal 16; assert each client `keepAlive==25`.

Auth inside container (preferred):

```bash
docker exec 3x-ui sh -c 'wget -qO- http://127.0.0.1:2053/...' 
# OR curl to panel listen from compose; discover port from 3x-ui.env WEB_BASE / PANEL
```

If panel is only on docker network, run python **on the host** targeting `http://127.0.0.1:<published_panel_port>` or `docker exec` with scripts mounted at `/tmp`.

- [ ] **Step 2: Dry-run print redacted diff**

Run apply with `--dry-run` that prints only changed server keys + keepAlive list:

```text
s1: 28 -> 16
s2: 102 -> 16
...
disableCookies: True -> False
keepAlive emails: all -> 25
publicKey: unchanged
```

Expected: matches target table; no key material printed.

- [ ] **Step 3: Apply for real**

```bash
sudo AWG_BACKUP_DIR=/opt/docker-proxy/_backup/awg-akar-stability-XXXX \
  python3 /tmp/awg-akar-apply.py --apply
```

Expected: `ok publicKey_unchanged=1 keepAlive_all=25 S=[16,16,16,16]`

- [ ] **Step 4: Commit nothing from this task** (live-only). If a reusable script is later added under `docker-proxy/3x-ui/scripts/`, that is a separate follow-up plan.

---

### Task 3: Server-side verify + listen check

**Files:**
- Create/scp: `/tmp/awg-akar-verify-server.sh`

**Interfaces:**
- Consumes: live `x-ui.db` / inbound get
- Produces: pass/fail exit code

- [ ] **Step 1: Verify script**

```bash
#!/usr/bin/env bash
set -euo pipefail
docker cp 3x-ui:/etc/x-ui/x-ui.db /tmp/x-ui-awg-v.db
python3 - <<'PY'
import json, sqlite3
con=sqlite3.connect('/tmp/x-ui-awg-v.db'); con.row_factory=sqlite3.Row
row=con.execute("select settings,enable,port,protocol from inbounds where id=5").fetchone()
assert row['protocol']=='amneziawg' and int(row['enable'])==1 and int(row['port'])==443
s=json.loads(row['settings']); srv=s['server']
Ss=[srv['s1'],srv['s2'],srv['s3'],srv['s4']]
assert Ss==[16,16,16,16], Ss
assert [str(srv['h1']),str(srv['h2']),str(srv['h3']),str(srv['h4'])]==['1','2','3','4']
assert srv.get('randomTrailers') in (True, 'on', 'true', 1)
assert srv.get('disableCookies') in (False, 'off', 'false', 0)
assert int(srv.get('jc'))==4
assert int(srv.get('jmin'))==50 and int(srv.get('jmax'))==120
assert srv.get('headerProtectionKey'), 'HP key missing'
for c in s['clients']:
    assert int(c.get('keepAlive') or 0)==25, c.get('email')
print('server_verify_ok')
PY
ss -ulnp | grep -E ':443\b' || docker exec 3x-ui sh -c 'ss -ulnp | grep 443 || netstat -ulnp | grep 443'
```

- [ ] **Step 2: Run verify**

```powershell
scp ... vps-intezio-akar:/tmp/awg-akar-verify-server.sh
ssh vps-intezio-akar 'sudo bash /tmp/awg-akar-verify-server.sh'
```

Expected: `server_verify_ok` and a UDP 443 listener related to 3x-ui/awg.

- [ ] **Step 3: If verify fails hard (publicKey changed)**

Immediately run rollback Task 6 before touching prizrak.

---

### Task 4: Refresh prizrak provider `akar` + short API check

**Files:**
- Local watcher script against `http://192.168.10.1:9090`

**Interfaces:**
- Consumes: prizrak API (no auth observed on LAN)
- Produces: updatedAt bump; fresh delay samples

- [ ] **Step 1: Note provider updatedAt before refresh**

```python
import json, urllib.request
p=json.load(urllib.request.urlopen("http://192.168.10.1:9090/providers/proxies"))["providers"]["akar"]
print(p.get("updatedAt"))
```

- [ ] **Step 2: Refresh provider**

```powershell
Invoke-WebRequest -Method PUT -Uri "http://192.168.10.1:9090/providers/proxies/akar" -UseBasicParsing
```

Expected: HTTP 204/empty success. Re-read `updatedAt` — must change.

- [ ] **Step 3: Trigger healthcheck samples**

Prefer provider healthcheck if exposed:

```powershell
# Try (may 404 on this build):
Invoke-WebRequest "http://192.168.10.1:9090/providers/proxies/akar/healthcheck" -UseBasicParsing
```

Also hit group delay for `AWG_AUTO`:

```powershell
$url = [uri]::EscapeDataString("https://www.gstatic.com/generate_204")
Invoke-RestMethod "http://192.168.10.1:9090/group/AWG_AUTO/delay?url=$url&timeout=5000"
```

Expected: JSON including `🇵🇱 amneziawg` with numeric delay (possibly still warming).

- [ ] **Step 4: Confirm node history moves**

Re-list last 5 history entries for `🇵🇱 amneziawg`. Expect fewer immediate zeros after 2–3 intervals; do not declare success yet (needs Task 5 window).

---

### Task 5: Observation window + manual smoke

**Files:**
- Update: local ops note only (do not commit evidence files)

**Interfaces:**
- Consumes: prizrak history over 30–60 minutes; operator manual traffic result

- [ ] **Step 1: Poll every 5 minutes for ≥30 minutes**

```python
# loop: print time, delay, alive for 🇵🇱 amneziawg
# success heuristic for this task gate:
#   in the last 6 samples, at most 1 zero, and all non-zero delays < 200
```

- [ ] **Step 2: Manual smoke**

On a client using prizrak/`AWG_AUTO` or forced `🇵🇱 amneziawg`: open HTTPS sites for several minutes; note stalls. Record pass/fail in evidence (no secrets).

- [ ] **Step 3: Regression glance**

Check one VLESS node from provider `akar` still has healthy delays (non-AWG).

- [ ] **Step 4: Write sanitized evidence**

Keep a local ops note (outside git) with before/after delay tables (numbers only), profile summary (no keys), smoke result, backup dir name. Do not add evidence files to the repository.

---

### Task 6: Rollback procedure (ready before/when failing)

**Files:**
- Create/scp: `/tmp/awg-akar-rollback.py` (restore from `AWG_BACKUP_DIR`)

**Interfaces:**
- Consumes: `inbound-5-settings.json` backup
- Produces: restored inbound + provider refresh

- [ ] **Step 1: Rollback script**

Load backup settings verbatim; POST update/5 with full inbound shell; assert publicKey equals backup; refresh prizrak provider `akar`.

- [ ] **Step 2: Execute only if**

- publicKey changed unexpectedly, or
- observation fails badly / DPI breakage after cookies off, or
- operator aborts canary

- [ ] **Step 3: Partial rollback option**

If only DPI worsens: set `disableCookies=true` keeping equal S + keepalive; refresh provider; re-observe 15 minutes before full backup restore.

---

### Task 7: Project context + plan status

**Files:**
- Modify: `.project_context/02_state/last_changes.md`
- Modify: `.project_context/02_state/current_state.md` (akar AWG note)
- Modify: `.project_context/03_agent_memory/lessons_learned.md` (trailers+unequal S; missing keepAlive)

- [ ] **Step 1: Update context with canary outcome**

One short paragraph: profile applied or rolled back; prizrak delay summary; next step (promote to vdsina/streambase or iterate).

- [ ] **Step 2: Commit context if workspace tracks it**

```powershell
git add .project_context/02_state/last_changes.md .project_context/02_state/current_state.md .project_context/03_agent_memory/lessons_learned.md
git commit -m "docs(context): akar AWG stability canary outcome"
```

Skip if `.project_context` is intentionally untracked.

---

## Spec coverage (self-review)

| Spec requirement | Task |
|---|---|
| Canary only akar | Global + Tasks 1–5 |
| Equal S=16, H=1..4, trailers on, cookies off, junk/padding, keepAlive 25 | Task 2 |
| Preserve HP key + peer keys | Task 2 asserts + Task 6 |
| Backup before change | Task 1 |
| Prizrak provider refresh | Task 4 |
| API history + manual traffic success | Task 5 |
| Rollback | Task 6 |
| No vdsina/streambase in this change set | Global Constraints |
| Evidence / lessons | Tasks 5, 7 |

## Placeholder scan

No TBD/TODO left in steps; commands and target constants are concrete. Panel listen/auth discovery is spelled as an implementer action inside Task 2 (inspect `3x-ui.env` / compose publish) rather than a vague “handle auth”.
