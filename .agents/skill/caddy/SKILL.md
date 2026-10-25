---
name: caddy
description: Use when editing or operating Caddy in 3x-ui_pro_Docker, including 05-caddy.yml, docker-proxy/caddy/config, fallback/error pages, Caddy CrowdSec integration, health, or restarts.
---

# Caddy

Use this skill for the Caddy catch-all/error backend and its active configuration.

## Official documentation

- Caddy docs: https://caddyserver.com/docs/
- Layer 4 app: https://github.com/mholt/caddy-l4 · https://github.com/mholt/caddy-l4/tree/master/docs
- CrowdSec Caddy bouncer: https://github.com/hslatman/caddy-crowdsec-bouncer
- Image contract (`torotin/caddy-l4`): https://github.com/Torotin/AutoDockerBuilder/blob/main/bin/caddy/README.md

L4 modules in the image do **not** mean this stack exposes L4 listeners. TLS terminates at Traefik; Caddy is the low-priority fallback/error backend. `caddy/subs` is do-not-revive.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/05-caddy.yml`
   - `docker-proxy/caddy/config/**`

## Ownership

Own:
- `docker-proxy/compose.d/05-caddy.yml`
- `docker-proxy/caddy/config/**`
- Caddy fallback/error backend labels and health behavior
- Caddy CrowdSec/appsec snippets and access log policy

Coordinate with `traefik` for shared router/middleware behavior and with `crowdsec` for Caddy bouncer/appsec integration.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure` unless noted. Caddy is reached through Traefik only; it does not terminate public TLS in this stack.

| Service skill | Path / rule (from compose) | Notes |
|---|---|---|
| `caddy` | Host-only `caddy-fallback` priority `1` | Catch-all / error backend, intentionally unauthenticated and lower priority than Lampac. |

### Product routing (upstream)

- Caddy listens on `${PORT_LOCAL_CADDYWEB}` behind Traefik with `auto_https off`.
- The live Caddyfile serves the image-owned `/srv` decoy site with `try_files {path} /index.html`.
- Traefik sends fallback/error traffic to service `caddy-error` on `${PORT_LOCAL_CADDYWEB}`.
- The public Traefik router is `Host(${WEBDOMAIN})`, `websecure`, priority `1`, service `caddy-error`.
- Caddy imports CrowdSec config and runs `crowdsec` plus `appsec` before serving fallback content.
- Trusted proxy ranges must include the project Docker networks so client attribution survives Traefik.
- Caddy reverse_proxy patterns are upstream-supported, but live config is file server fallback; do not invent app proxies.
- Do not revive `caddy/subs`; 3x-ui owns native subscription, JSON, and Clash paths.

## Core Rules

- Keep Caddy on `172.18.0.5` and `172.19.0.5`.
- Traefik terminates public TLS; Caddy listens on internal ports and has `auto_https off`.
- Preserve trusted proxy ranges for the project Docker networks so CrowdSec/appsec sees the real client host.
- The `caddy-fallback` router is intentionally public, low priority, and lower than Lampac routes.
- Keep `/var/log/caddy` under `docker-proxy/_logs/caddy` and active config under `/etc/caddy`.
- `/srv` is image-owned (decoy HTML from entrypoint); do not bind-mount subscription HTML trees into Caddy.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart caddy
docker-proxy/compose.d/run-compose.sh logs caddy
```

The healthcheck accepts either admin config visibility on `127.0.0.1:2019` or an open local Caddy web port.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
git diff --check
```
