---
name: compose-stack
description: Use when editing or operating docker-proxy/compose.d, run-compose.sh, base Docker networks/volumes, docker-maintenance.sh, docker-reset.sh, or stack-wide compose inventory in 3x-ui_pro_Docker.
---

# Compose Stack

Use this skill for the Docker Compose stack fragments under `docker-proxy/compose.d`, especially stack inventory, startup orchestration, network/IP allocation, maintenance scripts, reset helpers, and doctor compose/container expectations.

## Official documentation

- Docker Compose: https://docs.docker.com/compose/
- Edge routing concepts: use the `traefik` skill and https://doc.traefik.io/traefik/
- Custom `torotin/*` image pipeline/inventory (dockcheck is do-not-revive; use AutoDockerBuilder): https://github.com/Torotin/AutoDockerBuilder

This skill owns the **full public route index** for the stack. Per-service path details also live in each thick skill (duplicated own rows only).

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/compose-stack.md](references/compose-stack.md) before changing compose files or stack documentation.
3. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
4. Rebuild inventory from live `docker-proxy/compose.d/*.yml` files. Do not treat `*.yml.disable` remnants as active.

## Core Commands

- `docker-proxy/compose.d/run-compose.sh list-files`
- `docker-proxy/compose.d/run-compose.sh validate`
- `docker-proxy/compose.d/run-compose.sh up`
- `docker-proxy/compose.d/run-compose.sh restart [--logs] SERVICE...`
- `docker-proxy/compose.d/run-compose.sh rebuild [SERVICE...]`
- `docker-proxy/compose.d/run-compose.sh logs CONTAINER [ARGS...]`
- `docker-proxy/compose.d/run-compose.sh maintenance [report|prune]`
- `docker-proxy/compose.d/run-compose.sh down [ARGS...]`

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure` unless noted. Derive exact `URI_*` values from compose `.env` / live labels; do not invent paths. Entrypoints live: `web` (`:80`) and `websecure` (`:4443` inside Traefik). No live L4 TCP/UDP entrypoints.

| Service skill | Path / rule (from compose) | Notes |
|---|---|---|
| `traefik` | `/${URI_TRAEFIK_DASHBOARD}`, `/${URI_TRAEFIK_DASHBOARD}/dashboard*`, `/${URI_TRAEFIK_DASHBOARD}/api*`, `/${URI_TRAEFIK_DASHBOARD}/metrics`, root `/api*`, dashboard manifest | `api@internal`; root `/api` is a dashboard conflict zone with Arcane/Homepage carve-outs. |
| `arcane` | `/${URI_ARCANE}*`, root `/_app*`, `/api*`, `/img*`, `/login`, `/app.webmanifest`, `/service-worker.js`, `/arcane-mobile-passkey.json`, SPA root regexp families | Path-prefix hardening; Arcane owns broad root `/api` below Homepage widget priorities and above Traefik dashboard `/api`. |
| `adguard` | `/${URI_ADGUARD_PANEL}*`, `/${URI_ADGUARD_DOH}` | Panel plus public DoH; plain DNS stays internal. |
| `3x-ui` | `/${URI_PANEL_PATH}/health`, `/${URI_PANEL_PATH}*`, `/${URI_PANEL_PATH}/panel/api*`, `${URI_SUB_PATH}*`, `${URI_JSON_PATH}*`, `${URI_CLASH_PATH:-/clash/}*`, `${URI_VLESS_XHTTP}*`, `${URI_VLESS_GRPC}*` | Native subscriptions/JSON/Clash; caddy/subs and sub-json-processor are do-not-revive. |
| `homepage` | `/${URI_HOMEPAGE}*`, root `/_next/*`, selected NextAuth/widget `/api/*`, `/favicon.ico`, favicon/icon/PWA paths | Not full `/api`; static/API carve-outs outrank Arcane where listed. |
| `lampac` | Host catch-all; `/api/v1.0*`, `/api/v2.0*`, PathRegexp `^/(nws\|ws)`, `^/cub/[^/]+/plugin`, `^/(admin\|adminpanel\|stats\|weblog\|database-editor)`, `^/(adminpanel\|weblog)/auth$`; `!Host(${WEBDOMAIN})` fallback | Optional `ENABLE_LAMPAC`; catch-all priority is above Caddy fallback except unknown-host fallback. |
| `telemt` | `/${URI_TELEMT_PANEL}*` | Optional `ENABLE_TELEMT`; panel route only. |
| `mihomo` | `/${URI_MIHOMO}`, `/${URI_MIHOMO}/ui`, `/${URI_MIHOMO}/ui*`, manifest regexp under UI | Optional `ENABLE_MIHOMO`; dashboard/UI only. |
| `caddy` | Host-only `caddy-fallback` priority `1` | Catch-all / error backend, intentionally unauthenticated and lower priority than Lampac. |
| `proxy-backends` | no public Traefik UI | Internal `usque` / `tor-proxy` peers. |
| `crowdsec` | no public UI route | `bouncer@file`, AppSec/LAPI internals, and firewall bouncer. |

## Validation

Prefer static/local checks before live server changes:

```bash
bash -n docker-proxy/compose.d/run-compose.sh docker-proxy/compose.d/docker-maintenance.sh docker-proxy/compose.d/docker-reset.sh
bash tests/run-compose/test_run_compose.bash
bash tests/run-compose/test_compose_startup_chain.bash
git diff --check
```

Do not run live Docker mutations locally unless the user explicitly asks.
