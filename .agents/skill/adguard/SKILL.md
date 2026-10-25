---
name: adguard
description: Use when editing or operating AdGuard Home in 3x-ui_pro_Docker, including 10-adguard.yml, docker-proxy/adguard configuration, stack DNS at 172.19.0.10, DoH routing, panel routing, password updates, health, or restarts.
---

# AdGuard

Use this skill for the active AdGuard Home service: internal stack DNS, public DoH, and the protected AdGuard panel.

## Official documentation

- AdGuard Home wiki/docs: https://github.com/AdguardTeam/AdGuardHome/wiki
- Stack UI/DoH paths come from `10-adguard.yml` (`URI_ADGUARD_PANEL`, `URI_ADGUARD_DOH`), not from upstream sample compose.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/10-adguard.yml`
   - `docker-proxy/adguard/conf/AdGuardHome.yaml`
   - `docker-proxy/adguard/update-pass.sh`
   - `docker-proxy/adguard/work/**`

## Ownership

Own:
- `docker-proxy/compose.d/10-adguard.yml`
- `docker-proxy/adguard/**`
- AdGuard panel and DoH Traefik labels
- Stack DNS behavior for services that use `172.19.0.10`

Coordinate with `3x-ui` for service DNS dependencies and with `traefik` for shared middleware behavior.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure` unless noted. Plain DNS stays internal on `172.19.0.10:53`.

| Service skill | Path / rule (from compose) | Notes |
|---|---|---|
| `adguard` | `/${URI_ADGUARD_PANEL}*`, `/${URI_ADGUARD_DOH}` | Panel plus public DoH; plain DNS stays internal. |

### Product routing (upstream)

- AdGuard Home serves its UI on container port `80`; Traefik prefixes it with `/${URI_ADGUARD_PANEL}`.
- The panel router uses `PathPrefix`, BasicAuth, `bouncer@file`, rate limit, strip-prefix, Location rewrite, and compression.
- The public DoH router uses exact `Path(/${URI_ADGUARD_DOH})` and rewrites to `/dns-query`.
- DoH intentionally omits BasicAuth; protect it with bouncer and the higher DoH rate limit.
- Plain DNS listens inside the container on port `53` and is consumed by stack peers on `172.19.0.10`.
- Rewrites in `AdGuardHome.yaml` provide internal names for peers including `3x-ui`, Traefik, Caddy, CrowdSec, Homepage, and Lampac.
- Upstreams currently use Quad9 and Google DoH/DoT with load-balance mode and bootstrap resolvers.
- Keep coordination with `3x-ui`: it may rely on AdGuard as its DNS peer on `dns-net`.

## Core Rules

- Keep AdGuard on `172.18.0.10` and `172.19.0.10`; `172.19.0.10` is the stack DNS server.
- Plain DNS ports `53/tcp` and `53/udp` are intentionally not published by default.
- Persist config under `docker-proxy/adguard/conf` and runtime data under `docker-proxy/adguard/work`.
- Keep `update-pass.sh` mounted read-only and run from the entrypoint before `AdGuardHome -s run`.
- Keep Traefik PEM mounted read-only at `/opt/adguardhome/pem` for certificate-aware AdGuard configuration.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh restart adguard
docker-proxy/compose.d/run-compose.sh logs adguard
```

The container healthcheck probes `http://127.0.0.1/` or falls back to checking local port `80`. Traefik also healthchecks `/` on service port `80`.

## Traefik Notes

- Panel router: `Host(${WEBDOMAIN}) && PathPrefix(/${URI_ADGUARD_PANEL})`, priority `1000`, BasicAuth enabled.
- Public DoH router: `Path(/${URI_ADGUARD_DOH})`, priority `11000`, rewritten to `/dns-query`.
- Panel chain uses `bouncer@file`, AdGuard BasicAuth, rate limit, security headers, strip prefix, Location rewrite, and compress.
- DoH chain uses `bouncer@file`, a higher DoH rate limit, and replace-path only; do not add BasicAuth to public DoH.

## Pitfalls

- Do not publish host port `53` unless the host DNS listener conflict is understood and intentionally resolved.
- Do not remove the panel prefix strip/rewrite pair; AdGuard redirects with root-relative `Location` headers.
- Do not broaden DoH routing with `PathPrefix` unless clients and admin routes remain separated.
- Do not revive `docker-proxy/traefik/dynamic_old/adguard.yml`; it is a remnant only and do-not-revive as active config.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart adguard
git diff --check
```
