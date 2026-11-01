# Xray Admin Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move listed admin UIs off public `WEBDOMAIN`/`websecure` onto Traefik entrypoint `admin` with self-signed TLS and Hostnames `*.${WEBDOMAIN}`, reachable only via personal Xray (+ AdGuard rewrite), without breaking the live Xray subscription.

**Architecture:** Traefik private `admin` (:9443, docker-internal + `127.0.0.1` publish for break-glass) terminates self-signed HTTPS. Six Host routers at `/` (Lampac admin keeps path set). Xray desired-state routes those FQDNs to `traefik:9443`. AdGuard rewrites the six names to Traefik `172.18.0.6`. No Tailscale. Basic Auth stays; CrowdSec bouncer omitted on admin chains.

**Tech Stack:** Docker Compose, Traefik v3, Xray desired-state (3x-ui scripts), AdGuard Home rewrites, bash tests, SSH `vps-vdsok-streambase-torotin`.

**Spec:** `docs/superpowers/specs/2026-10-25-xray-admin-access-design.md`

## Global Constraints

- Branch: `feat/xray-admin-access` (base `ca445fb` / `dev`).
- Live server: SSH `vps-vdsok-streambase-torotin`; **destructive actions allowed**.
- **Hard:** subscription URLs/paths (`URI_SUB_PATH`, `URI_JSON_PATH`, `URI_CLASH_PATH`, `WEBDOMAIN`, xhttp/grpc) must keep working — smoke sub before/after every change that touches `12-3x-ui.yml` or public Traefik.
- Admin Hosts (not in public DNS):
  - `arcane.${WEBDOMAIN}`
  - `homepage.${WEBDOMAIN}`
  - `adguard.${WEBDOMAIN}`
  - `3x-ui.${WEBDOMAIN}`
  - `traefik.${WEBDOMAIN}`
  - `lampac-admin.${WEBDOMAIN}`
- Entrypoint `admin`: port `PORT_LOCAL_ADMIN` default `9443`; listen `:9443` in-container; host publish **only** `127.0.0.1:${PORT_LOCAL_ADMIN}:9443`.
- TLS: Traefik default/self-signed on `admin` (`tls: {}` / router `tls=true`, **no** `certresolver=le`). Browser warnings OK.
- AdGuard rewrite target: Traefik IPv4 `172.18.0.6` (compose fixed address).
- Xray outbound tag: `admin-traefik` → freedom TCP `traefik:9443` (browser does TLS; sniffing uses SNI/Host).
- Keep Basic Auth (`HT_PASS_ENCODED`). No `bouncer@file` on new admin chains in v1.
- `docs/` is gitignored — force-add plans/specs when committing them; prefer commits of tracked code/tests/skills.
- Do not change Mihomo/Telemt admin exposure in this plan.
- Remove any live Tailscale leftovers on the server as part of rollout (compose/env/container).

## File map

| File | Role |
|---|---|
| `tests/xray-admin/test_admin_isolation.bash` | Static asserts: no public admin routers; `admin` entrypoint; sub/DoH remain; no Tailscale compose |
| `tests/xray-admin/run.sh` | Suite entry |
| `tests/xray-admin/probe-live.sh` | Live smoke on streambase |
| `docker-proxy/traefik/traefik.yml` | Entrypoint `admin` `:9443` + `http.tls: {}` |
| `docker-proxy/compose.d/06-traefik.yml` | Publish `127.0.0.1:9443`, healthcheck, dashboard → `Host(traefik.${WEBDOMAIN})` on `admin` |
| `docker-proxy/compose.d/07-arcane.yml` | Public routers removed; `admin` Host root; `APP_URL` |
| `docker-proxy/traefik/dynamic/arcane.yml` | Disable/simplify path-prefix body rewrite once Arcane is root on private Host |
| `docker-proxy/compose.d/13-homepage.yml` | Public routers removed; `admin` Host |
| `docker-proxy/homepage/settings.yaml` + `services.yaml` | Base/links → `https://<svc>.${WEBDOMAIN}` |
| `docker-proxy/compose.d/10-adguard.yml` | Panel → `admin` Host; DoH stays `websecure` |
| `docker-proxy/adguard/ensure-admin-rewrites.sh` (or equivalent) | Idempotent six rewrites → `172.18.0.6` |
| `docker-proxy/compose.d/12-3x-ui.yml` | Panel → `3x-ui.${WEBDOMAIN}` on `admin`; **keep** sub/xhttp/grpc on `websecure` |
| `docker-proxy/compose.d/14-lampac.yml` | sensitive/auth → `lampac-admin.${WEBDOMAIN}` on `admin` |
| `docker-proxy/3x-ui/scripts/lib/json_state.bash` (+ caller) | Managed routing + outbound `admin-traefik` |
| `script/template/docker.env.template` (+ install env if needed) | `PORT_LOCAL_ADMIN=9443` |
| `.agents/skill/{traefik,arcane,homepage,adguard,3x-ui,lampac,compose-stack,3x-ui-pro-docker}/` | Route docs update; **no** Tailscale skill |

## Resolved design choices

1. Port/bind: `9443` / `127.0.0.1` publish only.
2. AdGuard → `172.18.0.6`; Xray domain route still authoritative when sniffing is on.
3. CrowdSec bouncer: omit on admin chains.
4. Live order: smoke sub → remove Tailscale leftovers → land `admin` entrypoint → migrate routers service-by-service with sub smoke → AdGuard rewrites → Xray routes → full probe.

---

### Task 1: Static isolation test harness (TDD)

**Files:**
- Create: `tests/xray-admin/run.sh`
- Create: `tests/xray-admin/test_admin_isolation.bash`
- Test: `tests/xray-admin/run.sh`

**Interfaces:**
- Produces: `bash tests/xray-admin/run.sh` exit 0 when asserts pass
- Consumes: `docker-proxy/compose.d/*.yml`, `docker-proxy/traefik/traefik.yml`

- [ ] **Step 1: Write failing tests**

Create `tests/xray-admin/test_admin_isolation.bash`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE="$ROOT_DIR/docker-proxy/compose.d"
TRAEFIK_YML="$ROOT_DIR/docker-proxy/traefik/traefik.yml"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

test_admin_entrypoint_exists() {
  grep -qE '^[[:space:]]*admin:' "$TRAEFIK_YML" || fail "entrypoint admin missing in traefik.yml"
  grep -qE 'address:[[:space:]]*":9443"' "$TRAEFIK_YML" \
    || grep -qE "address:[[:space:]]*':9443'" "$TRAEFIK_YML" \
    || fail "admin entrypoint must listen on :9443"
  pass "admin entrypoint present on :9443"
}

test_no_public_admin_entrypoints() {
  local patterns=(
    'routers.arcane-ui.entrypoints=websecure'
    'routers.homepage-router.entrypoints=websecure'
    'routers.adguard-panel.entrypoints=websecure'
    'routers.3xui-panel.entrypoints=websecure'
    'routers.traefik-dashboard-prefixed.entrypoints=websecure'
    'routers.lampac-sensitive.entrypoints=websecure'
  )
  local p
  for p in "${patterns[@]}"; do
    if grep -R -n --fixed-strings "$p" "$COMPOSE"/*.yml >/dev/null 2>&1; then
      fail "public admin still on websecure: $p"
    fi
  done
  pass "listed admin routers not on websecure"
}

test_subscription_and_doh_remain_public() {
  grep -n 'routers.3xui-sub.entrypoints=websecure' "$COMPOSE/12-3x-ui.yml" >/dev/null \
    || fail "3xui-sub must stay on websecure"
  grep -n 'routers.adguard-doh.entrypoints=websecure' "$COMPOSE/10-adguard.yml" >/dev/null \
    || fail "adguard-doh must stay on websecure"
  pass "sub + DoH remain public"
}

test_no_tailscale_compose() {
  if ls "$COMPOSE"/17-tailscale.yml >/dev/null 2>&1; then
    fail "17-tailscale.yml must not exist"
  fi
  if grep -R -n -i 'tailscale' "$COMPOSE"/*.yml >/dev/null 2>&1; then
    fail "compose.d must not reference tailscale"
  fi
  pass "no Tailscale compose"
}

test_admin_entrypoint_exists
test_no_public_admin_entrypoints
test_subscription_and_doh_remain_public
test_no_tailscale_compose
```

Create `tests/xray-admin/run.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$DIR/test_admin_isolation.bash"
```

- [ ] **Step 2: Run suite — expect FAIL**

Run: `bash tests/xray-admin/run.sh`  
Expected: FAIL on missing `admin` entrypoint and/or public admin still on `websecure`.

- [ ] **Step 3: Commit harness**

```bash
git add tests/xray-admin/run.sh tests/xray-admin/test_admin_isolation.bash
git commit -m "test(xray-admin): add static isolation harness for admin plane"
```

---

### Task 2: Traefik `admin` entrypoint + localhost publish

**Files:**
- Modify: `docker-proxy/traefik/traefik.yml`
- Modify: `docker-proxy/compose.d/06-traefik.yml` (ports + healthcheck only in this task)
- Modify: `script/template/docker.env.template` (add `PORT_LOCAL_ADMIN=9443`)
- Test: `tests/xray-admin/run.sh` (partial: entrypoint assert may pass; public-admin asserts still fail until later tasks)

**Interfaces:**
- Produces: Traefik listens on `:9443` with default TLS; host `127.0.0.1:9443→9443`
- Consumes: none

- [ ] **Step 1: Add entrypoint to `traefik.yml`**

Under `entryPoints:`, after `websecure`, add:

```yaml
  admin:
    address: ":9443"
    http:
      tls: {}
    transport:
      respondingTimeouts:
        readTimeout: 0s
        writeTimeout: 0s
        idleTimeout: 0s
```

Do **not** add ACME for this entrypoint.

- [ ] **Step 2: Publish localhost + healthcheck in `06-traefik.yml`**

In `ports:` add (keep existing `80:80`):

```yaml
      - "127.0.0.1:${PORT_LOCAL_ADMIN:-9443}:9443"
```

Update healthcheck to also require `nc -z 127.0.0.1 9443`.

- [ ] **Step 3: Env template**

In `script/template/docker.env.template` near other `PORT_LOCAL_*`:

```bash
PORT_LOCAL_ADMIN=9443
```

Mirror in `script/template/install.env.template` if that file lists Traefik ports.

- [ ] **Step 4: Validate compose locally**

Run: `bash docker-proxy/compose.d/run-compose.sh validate` (or project’s documented validate)  
Expected: config OK (or documented mock-safe equivalent).

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/traefik/traefik.yml docker-proxy/compose.d/06-traefik.yml script/template/docker.env.template script/template/install.env.template
git commit -m "feat(traefik): add private admin entrypoint :9443 with self-signed TLS"
```

---

### Task 3: Traefik dashboard → `traefik.${WEBDOMAIN}` on `admin`

**Files:**
- Modify: `docker-proxy/compose.d/06-traefik.yml` (dashboard/metrics/api routers)
- Test: isolation harness (dashboard pattern must leave `websecure`)

**Interfaces:**
- Produces: routers `Host(\`traefik.${WEBDOMAIN}\`)` + path `/dashboard` `/api` on `entrypoints=admin`, `tls=true`, **no** `certresolver=le`
- Consumes: Task 2 entrypoint

- [ ] **Step 1: Replace public dashboard routers**

Remove `websecure` + `tls.certresolver=le` dashboard/metrics/api-root/manifest routers tied to `Host(\`${WEBDOMAIN}\`)`.

Add (adjust names to match existing middleware reuse; strip-prefix path-compat can be dropped if serving at Traefik default `/dashboard/`):

```yaml
      - traefik.http.middlewares.admin-dash-chain.chain.middlewares=basic-auth,rate-limit,admin-security-headers@file,compress
      - traefik.http.routers.traefik-dashboard.rule=Host(`traefik.${WEBDOMAIN}`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      - traefik.http.routers.traefik-dashboard.entrypoints=admin
      - traefik.http.routers.traefik-dashboard.middlewares=admin-dash-chain
      - traefik.http.routers.traefik-dashboard.service=api@internal
      - traefik.http.routers.traefik-dashboard.tls=true
      - traefik.http.routers.traefik-dashboard.priority=100
```

Ensure no remaining `traefik-dashboard-*.entrypoints=websecure` or root `PathPrefix(\`/api\`)` on `WEBDOMAIN` for the dashboard.

- [ ] **Step 2: Run isolation test**

Run: `bash tests/xray-admin/run.sh`  
Expected: still FAIL overall until other services migrate; `traefik-dashboard-prefixed` pattern must PASS (absent).

- [ ] **Step 3: Commit**

```bash
git add docker-proxy/compose.d/06-traefik.yml
git commit -m "feat(traefik): move dashboard to traefik.${WEBDOMAIN} on admin plane"
```

---

### Task 4: Arcane → `arcane.${WEBDOMAIN}` on `admin`

**Files:**
- Modify: `docker-proxy/compose.d/07-arcane.yml`
- Modify: `docker-proxy/traefik/dynamic/arcane.yml` (disable public path rewrites or reduce to no-op safe for root Host)
- Test: `tests/arcane/test_arcane_traefik.bash` + isolation harness

**Interfaces:**
- Produces: single (or small set) Host router on `admin` at `/`; `APP_URL=https://arcane.${WEBDOMAIN}`
- Consumes: Task 2

- [ ] **Step 1: Failing expectation**

Confirm current `07-arcane.yml` still has `entrypoints=websecure` for UI — isolation test fails on `arcane-ui`.

- [ ] **Step 2: Migrate labels**

Set:

```yaml
      - APP_URL=https://arcane.${WEBDOMAIN}
```

Replace public path-prefix / root-exception routers with:

```yaml
      - traefik.http.middlewares.arcane-admin-chain.chain.middlewares=basic-auth,rate-limit,admin-security-headers@file,compress
      - traefik.http.routers.arcane-ui.rule=Host(`arcane.${WEBDOMAIN}`)
      - traefik.http.routers.arcane-ui.entrypoints=admin
      - traefik.http.routers.arcane-ui.middlewares=arcane-admin-chain
      - traefik.http.routers.arcane-ui.service=arcane-svc
      - traefik.http.routers.arcane-ui.tls=true
      - traefik.http.routers.arcane-ui.priority=100
```

Delete public `arcane-api`, `/_app`, spa-redirect, and other `WEBDOMAIN` path routers for Arcane.

- [ ] **Step 3: Soften `dynamic/arcane.yml`**

If file-provider rewrites assume `/${URI_ARCANE}`, gate them off or replace with root-safe config so Traefik still loads the directory. Keep comments free of `{{` `}}` (existing arcane test).

- [ ] **Step 4: Tests**

Run: `bash tests/arcane/run.sh`  
Run: `bash tests/xray-admin/run.sh` (arcane pattern must be clean)

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/compose.d/07-arcane.yml docker-proxy/traefik/dynamic/arcane.yml
git commit -m "feat(arcane): serve UI on arcane.${WEBDOMAIN} admin plane only"
```

---

### Task 5: Homepage → `homepage.${WEBDOMAIN}` on `admin`

**Files:**
- Modify: `docker-proxy/compose.d/13-homepage.yml`
- Modify: `docker-proxy/homepage/settings.yaml`
- Modify: `docker-proxy/homepage/services.yaml`
- Test: isolation harness

**Interfaces:**
- Produces: Host router on `admin` at `/`; widget links use admin Hosts
- Consumes: Task 2

- [ ] **Step 1: Migrate compose routers**

Remove `PathPrefix(\`/${URI_HOMEPAGE}\`)` and related `/_next` / auth public routers on `WEBDOMAIN`.

Add:

```yaml
      - traefik.http.middlewares.homepage-admin-chain.chain.middlewares=homepage-basic-auth,homepage-rate-limit,admin-security-headers@file,homepage-compress
      - traefik.http.routers.homepage-router.rule=Host(`homepage.${WEBDOMAIN}`)
      - traefik.http.routers.homepage-router.entrypoints=admin
      - traefik.http.routers.homepage-router.middlewares=homepage-admin-chain
      - traefik.http.routers.homepage-router.tls=true
```

Drop strip-prefix middlewares that exist only for public path mode.

- [ ] **Step 2: Update Homepage config**

`settings.yaml` base → `https://homepage.${WEBDOMAIN}` (or empty base at root).

`services.yaml` hrefs →:

```yaml
https://3x-ui.{{HOMEPAGE_VAR_WEBDOMAIN}}/
https://traefik.{{HOMEPAGE_VAR_WEBDOMAIN}}/dashboard/
https://adguard.{{HOMEPAGE_VAR_WEBDOMAIN}}/
https://arcane.{{HOMEPAGE_VAR_WEBDOMAIN}}/
https://homepage.{{HOMEPAGE_VAR_WEBDOMAIN}}/
https://lampac-admin.{{HOMEPAGE_VAR_WEBDOMAIN}}/admin
```

(Adapt to existing YAML structure; keep widget auth env vars working.)

- [ ] **Step 3: Test + commit**

```bash
bash tests/xray-admin/run.sh
git add docker-proxy/compose.d/13-homepage.yml docker-proxy/homepage/settings.yaml docker-proxy/homepage/services.yaml
git commit -m "feat(homepage): move dashboard to homepage.${WEBDOMAIN} admin plane"
```

---

### Task 6: AdGuard UI → `adguard.${WEBDOMAIN}` + rewrites helper

**Files:**
- Modify: `docker-proxy/compose.d/10-adguard.yml`
- Create: `docker-proxy/adguard/ensure-admin-rewrites.sh`
- Test: isolation harness

**Interfaces:**
- Produces: panel on `admin` Host; DoH unchanged on `websecure`; script upserts six rewrites → `172.18.0.6`
- Consumes: Task 2; live AdGuard API/config on server

- [ ] **Step 1: Migrate panel router**

Remove `adguard-panel` from `websecure`. Keep `adguard-doh` on `websecure`.

```yaml
      - traefik.http.middlewares.adguard-admin-chain.chain.middlewares=adguard-basic-auth,rate-limit,admin-security-headers@file,compress
      - traefik.http.routers.adguard-panel.rule=Host(`adguard.${WEBDOMAIN}`)
      - traefik.http.routers.adguard-panel.entrypoints=admin
      - traefik.http.routers.adguard-panel.middlewares=adguard-admin-chain
      - traefik.http.routers.adguard-panel.service=adguard-panel
      - traefik.http.routers.adguard-panel.tls=true
```

Remove strip-prefix / Location rewrite middlewares that exist only for `/${URI_ADGUARD_PANEL}`.

- [ ] **Step 2: Write `ensure-admin-rewrites.sh`**

Idempotent bash that, given `WEBDOMAIN`, ensures rewrites (via AdGuard YAML edit **or** HTTP API if the stack already uses one):

| Domain | Answer |
|---|---|
| `arcane.$WEBDOMAIN` | `172.18.0.6` |
| `homepage.$WEBDOMAIN` | `172.18.0.6` |
| `adguard.$WEBDOMAIN` | `172.18.0.6` |
| `3x-ui.$WEBDOMAIN` | `172.18.0.6` |
| `traefik.$WEBDOMAIN` | `172.18.0.6` |
| `lampac-admin.$WEBDOMAIN` | `172.18.0.6` |

Script must be safe to re-run; must not publish public DNS.

- [ ] **Step 3: Test + commit**

```bash
bash tests/xray-admin/run.sh
git add docker-proxy/compose.d/10-adguard.yml docker-proxy/adguard/ensure-admin-rewrites.sh
git commit -m "feat(adguard): panel on adguard.${WEBDOMAIN}; add admin DNS rewrite helper"
```

---

### Task 7: 3x-ui panel → `3x-ui.${WEBDOMAIN}` (keep sub/xhttp/grpc)

**Files:**
- Modify: `docker-proxy/compose.d/12-3x-ui.yml`
- Test: isolation harness + subscription smoke on live when applied

**Interfaces:**
- Produces: panel/health/api UI routers on `admin` Host; `3xui-sub`, xhttp, grpc stay `websecure`
- Consumes: Task 2

- [ ] **Step 1: Smoke sub BEFORE edit (live, when applying)**

```bash
ssh vps-vdsok-streambase-torotin 'curl -fsS -o /dev/null -w "%{http_code}\n" "https://$WEBDOMAIN/$URI_SUB_PATH"'
```

Expected: `200` (or current known-good code). Record result.

- [ ] **Step 2: Migrate panel only**

Move `3xui-panel` (and panel-only health/api if UI-only) to:

```yaml
      - traefik.http.routers.3xui-panel.rule=Host(`3x-ui.${WEBDOMAIN}`)
      - traefik.http.routers.3xui-panel.entrypoints=admin
      - traefik.http.routers.3xui-panel.tls=true
```

**Do not** change `3xui-sub`, `xhttp3xui`, `grpc3xui` (names as in file) `entrypoints=websecure` or their paths.

- [ ] **Step 3: Local assert + commit**

```bash
bash tests/xray-admin/run.sh
git add docker-proxy/compose.d/12-3x-ui.yml
git commit -m "feat(3x-ui): move panel to 3x-ui.${WEBDOMAIN}; keep sub on websecure"
```

- [ ] **Step 4: Live sub smoke AFTER apply**

Repeat Step 1; must match pre-change success.

---

### Task 8: Lampac admin → `lampac-admin.${WEBDOMAIN}`

**Files:**
- Modify: `docker-proxy/compose.d/14-lampac.yml`
- Test: isolation harness

**Interfaces:**
- Produces: `lampac-sensitive` / auth-pages on `Host(lampac-admin.${WEBDOMAIN})` + `admin`; front/nws/proxy stay public
- Consumes: Task 2

- [ ] **Step 1: Migrate sensitive routers**

```yaml
      - traefik.http.middlewares.lampac-admin-chain.chain.middlewares=lampac-admin-auth,lampac-admin-rate,lampac-admin-noindex,lampac-headers
      - traefik.http.routers.lampac-sensitive.rule=Host(`lampac-admin.${WEBDOMAIN}`) && PathRegexp(`^/(admin|adminpanel|stats|weblog|database-editor)`)
      - traefik.http.routers.lampac-sensitive.entrypoints=admin
      - traefik.http.routers.lampac-sensitive.middlewares=lampac-admin-chain
      - traefik.http.routers.lampac-sensitive.tls=true
```

Move `lampac-auth-pages` similarly. Remove `bouncer@file` from this private chain. Leave `lampac-https`, `lampac-nws`, etc. on `websecure`.

- [ ] **Step 2: Test + commit**

```bash
bash tests/xray-admin/run.sh
git add docker-proxy/compose.d/14-lampac.yml
git commit -m "feat(lampac): move admin/stats to lampac-admin.${WEBDOMAIN} admin plane"
```

---

### Task 9: Xray desired-state route admin FQDNs → `admin-traefik`

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/lib/json_state.bash` (and the caller that invokes `json_apply_managed_xray_state`, typically `xray_runtime.bash`)
- Create/modify: unit fixture under `tests/3x-ui-scripts/` if patterns exist
- Test: `bash tests/3x-ui-scripts/run.sh` (or focused test)

**Interfaces:**
- Produces: outbound:

```json
{
  "tag": "admin-traefik",
  "protocol": "freedom",
  "settings": {
    "redirect": "traefik:9443",
    "domainStrategy": "AsIs"
  }
}
```

(If `redirect` is unsuitable for this Xray build, use documented equivalent: freedom dial to `traefik` port `9443` per official docs — validate with `xray run -test`.)

- Routing rule (high priority, before WARP/TOR):

```json
{
  "type": "field",
  "domain": [
    "full:arcane.PLACEHOLDER",
    "full:homepage.PLACEHOLDER",
    "full:adguard.PLACEHOLDER",
    "full:3x-ui.PLACEHOLDER",
    "full:traefik.PLACEHOLDER",
    "full:lampac-admin.PLACEHOLDER"
  ],
  "outboundTag": "admin-traefik"
}
```

Replace `PLACEHOLDER` with live `WEBDOMAIN` at apply time. Domains must **not** go to WARP/TOR balancers.

- [ ] **Step 1: Write/adjust unit test** proving domains map to `admin-traefik` and outbound exists.

- [ ] **Step 2: Implement upsert in managed state apply path** (idempotent).

- [ ] **Step 3: Run tests**

```bash
bash tests/3x-ui-scripts/run.sh
```

- [ ] **Step 4: Commit**

```bash
git add docker-proxy/3x-ui/scripts/lib/json_state.bash docker-proxy/3x-ui/scripts/lib/xray_runtime.bash tests/3x-ui-scripts/
git commit -m "feat(xray): route admin.${WEBDOMAIN} hosts to Traefik admin outbound"
```

---

### Task 10: Isolation suite green + skills docs

**Files:**
- Modify: `.agents/skill/traefik/`, `arcane/`, `homepage/`, `adguard/`, `3x-ui/`, `lampac/`, `compose-stack/`, `3x-ui-pro-docker/` as present in repo
- Modify: `tests/xray-admin/test_admin_isolation.bash` if extra asserts needed (admin Host labels present)
- Test: `bash tests/xray-admin/run.sh` must exit 0

**Interfaces:**
- Produces: docs matching Host map; suite fully green on branch
- Consumes: Tasks 2–9

- [ ] **Step 1: Extend isolation test** to require at least one `entrypoints=admin` for each of: arcane, homepage, adguard-panel, 3xui-panel, traefik-dashboard, lampac-sensitive.

- [ ] **Step 2: Run full local checks**

```bash
bash tests/xray-admin/run.sh
bash tests/arcane/run.sh
bash docker-proxy/compose.d/run-compose.sh validate
```

Expected: all PASS / validate OK.

- [ ] **Step 3: Update skills** — access via `https://<svc>.${WEBDOMAIN}` through Xray; public plane has no admins; break-glass `curl -k https://127.0.0.1:9443 -H 'Host: …'`. Do **not** add a Tailscale skill.

- [ ] **Step 4: Commit**

```bash
git add tests/xray-admin/ .agents/skill/
git commit -m "docs(agents): document Xray admin plane Host routing"
```

---

### Task 11: Live apply on streambase (destructive OK)

**Files:**
- Create: `tests/xray-admin/probe-live.sh`
- Server: `/opt/docker-proxy`, `/opt/script` as deployed

**Interfaces:**
- Produces: live stack without Tailscale; admins only via Xray; sub smoke green
- Consumes: merged branch files rsynced/deployed per project norm

- [ ] **Step 1: Preflight sub smoke** (record codes).

- [ ] **Step 2: Remove Tailscale leftovers**

```bash
ssh vps-vdsok-streambase-torotin 'docker rm -f tailscale 2>/dev/null; rm -f /opt/docker-proxy/compose.d/17-tailscale.yml; sed -i "/^TS_/d" /opt/docker-proxy/compose.d/.env 2>/dev/null; true'
```

(Adjust paths to actual live layout; destructive OK.)

- [ ] **Step 3: Deploy branch artifacts** (compose, traefik.yml, scripts, adguard helper) via the project’s usual sync/`run-compose.sh` flow.

- [ ] **Step 4: Recreate Traefik + affected admin services; run `ensure-admin-rewrites.sh`; trigger 3x-ui afterstart / desired-state apply.**

- [ ] **Step 5: Break-glass probe from server**

```bash
curl -k -sS -o /dev/null -w "%{http_code}\n" -H "Host: arcane.$WEBDOMAIN" https://127.0.0.1:9443/
```

Expected: `401` (Basic Auth) or `200` if auth header provided — **not** connection refused.

- [ ] **Step 6: Public negative probe**

```bash
curl -k -sS -o /dev/null -w "%{http_code}\n" "https://$WEBDOMAIN/$URI_ARCANE/"
```

Expected: not the Arcane UI (404/SelfSteal/other non-panel).

- [ ] **Step 7: With Xray client** — open each admin Host; accept self-signed warning; Basic Auth → UI.

- [ ] **Step 8: Post sub/DoH/Lampac `/` smoke** — must match preflight success class.

- [ ] **Step 9: Commit probe script + short live notes** (force-add under `docs/` only if needed; prefer `tests/xray-admin/probe-live.sh` tracked)

```bash
git add tests/xray-admin/probe-live.sh
git commit -m "test(xray-admin): add live probe script for admin plane smoke"
```

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|---|---|
| Remove admins from public websecure | 3–8, 1 asserts |
| Xray-only primary access | 9, 11 |
| Hostnames `*.${WEBDOMAIN}` not public DNS | 4–8, 6 rewrites |
| Self-signed TLS on admin plane | 2 |
| Basic Auth kept | 3–8 chains |
| Break-glass SSH/localhost | 2 publish `127.0.0.1`, 11 curl |
| No Tailscale | 1 assert, 11 cleanup |
| Subscription invariant | 7 keep sub, 11 smoke |
| Live streambase destructive OK | 11 |
| Branch `feat/xray-admin-access` | Global Constraints |

No TBD placeholders remain; open choices from the spec are resolved in “Resolved design choices”.
