---
name: lampac
description: Use when editing or operating Lampac in 3x-ui_pro_Docker, including docker-proxy/compose.d/14-lampac.yml, docker-proxy/lampac local-master files, sync-lampac.sh, Lampac Traefik labels, KnownProxies, AdminPanel/WebLog exposure, /nws WebSocket routing, /proxy streaming, or ENABLE_LAMPAC.
---

# Lampac

Use this skill for the optional Lampac NextGen service in this repository: compose service wiring, local-master files under `docker-proxy/lampac/`, sync to `/opt/docker-proxy/lampac/`, and the Lampac-specific Traefik routing contract.

## Official documentation

- Lampac docs: https://docs.lampac.dev/ (use site llms.txt / index for navigation)
- Stack Traefik rules live in `14-lampac.yml` (Host catch-all, `/api/v1.0` `/api/v2.0`, nws/ws, cub plugins, admin PathRegexp). Optional via `ENABLE_LAMPAC`.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/lampac-sync.md](references/lampac-sync.md) before syncing or changing files under `docker-proxy/lampac/`.
3. Read [references/reverse-proxy.md](references/reverse-proxy.md) before editing `14-lampac.yml`, `init.conf` proxy trust, or any Lampac router/middleware labels.
4. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```

## Ownership

Own:
- `docker-proxy/compose.d/14-lampac.yml`
- `docker-proxy/lampac/**`
- `sync-lampac.sh`
- Lampac notes in compose inventory, router docs, and doctor expectations

Coordinate with `compose-stack` for stack-wide file discovery and with `traefik` for shared edge proxy behavior. Lampac is optional: `run-compose.sh` includes `14-lampac.yml` only when `ENABLE_LAMPAC` is truthy.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure`; unknown hosts fall through a separate fallback.

| Route / router | Rule | Priority | Middleware / notes |
|---|---|---:|---|
| `lampac-api-override` | `PathPrefix('/api/v1.0')` or `PathPrefix('/api/v2.0')` | 910 | JacRed/Lampac APIs; must beat Arcane broad `/api` and Traefik dashboard `/api`. |
| `lampac-auth-pages` | `^/(adminpanel|weblog)/auth$` | 95 | Lampac auth pages without Traefik BasicAuth. |
| `lampac-sensitive` | `^/(admin|adminpanel|stats|weblog|database-editor)` | 90 | Admin/WebLog/stats/database editor with `lampac-admin-chain`. |
| `lampac-nws` | `^/(nws|ws)` | 70 | Native and legacy WebSocket paths; scheme headers only. |
| `lampac-cub-plugins` | `^/cub/[^/]+/plugin` | 35 | Forces JS content type for extensionless Cub plugin paths. |
| `lampac-https` | `Host('${WEBDOMAIN}')` | 10 | Main catch-all for Lampac UI and content. |
| `lampac-unknown-host` | `!Host('${WEBDOMAIN}')` | 1 | Unknown-host fallback rewritten to `/`. |

## Product Routing

- `docker-proxy/lampac/config/init.conf` is the local-master runtime config; keep `KnownProxies` aligned with Traefik/DNS Docker networks.
- Lampac modules and AdminPanel pointers live under `docker-proxy/lampac/mods/**`; this skill should point to them, not duplicate module internals.
- Accsdb/database state is persisted under `docker-proxy/lampac/database/`; avoid destructive sync or cleanup guidance without an explicit backup path.
- Cache and TorrServer-related runtime data are under `docker-proxy/lampac/cache/` and `docker-proxy/lampac/data/`.
- LampaWeb UI is mounted from `docker-proxy/_data/lampac/lampa-main`, outside the synced Lampac tree so `sync-lampac.sh --delete` cannot wipe it.
- Admin paths require BasicAuth, CrowdSec bouncer, rate limiting, noindex, and HTTPS scheme headers; auth pages are the narrow bypass.
- Preserve `/nws` and `/ws` upgrade behavior; do not attach response hardening headers that break RCH/WebSocket clients.

## Core Rules

- Treat `docker-proxy/lampac/` as the local master; server files are sync targets.
- Keep the local-master rsync source with a trailing slash and keep `--delete` enabled by default. Use `--no-delete` only when preserving remote-only files is intentional.
- Keep Lampac serving on container port `9118`; Traefik forwards to that internal port.
- Keep `KnownProxies` aligned with the Traefik and DNS Docker networks so forwarded headers are trusted.
- Preserve the `/nws` and `/ws` WebSocket router behavior and the high-priority `/api/v1.0` / `/api/v2.0` override.
- Do not expose admin paths without the existing BasicAuth, CrowdSec bouncer chain, rate limit, and noindex headers.
- Do not move LampaWeb data mounted from `../_data/lampac/lampa-main` into the synced `lampac/` tree; sync deletion must not wipe that UI tree.

## Common Commands

```bash
./sync-lampac.sh --dry-run
./sync-lampac.sh
./sync-lampac.sh --interval 10
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart lampac
docker-proxy/compose.d/run-compose.sh logs lampac
```

## Validation

Prefer static/local checks before live operations:

```bash
docker-proxy/compose.d/run-compose.sh validate
bash -n sync-lampac.sh docker-proxy/compose.d/run-compose.sh
git diff --check
```

For live changes, sync Lampac files first, then restart only the affected service when needed. Most `init.conf` keys hot-reload, while module manifest/mount changes usually need a restart.
