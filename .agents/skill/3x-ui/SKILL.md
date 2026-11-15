---
name: 3x-ui
description: Use when operating or editing docker-proxy/3x-ui, 3x-ui bash runtime scripts, managed Xray desired state, 3x-ui panel API calls, native subscription paths, or the 12-3x-ui compose service.
---

# 3x-ui

Use this skill for the 3x-ui service in `3x-ui_pro_Docker`: `docker-proxy/compose.d/12-3x-ui.yml`, `docker-proxy/3x-ui/scripts`, `docker-proxy/3x-ui/configs/x-ui.db`, managed Xray desired state, native 3x-ui subscription routing, and panel API automation.

## Official documentation

Primary upstream docs (prefer over memory or outdated notes):

- Home: [https://docs.sanaei.dev/docs/](https://docs.sanaei.dev/docs/)
- API index: [https://docs.sanaei.dev/docs/reference/api](https://docs.sanaei.dev/docs/reference/api)
- Auth: [https://docs.sanaei.dev/docs/reference/api/authentication](https://docs.sanaei.dev/docs/reference/api/authentication)
- Subscription: [https://docs.sanaei.dev/docs/config/subscription](https://docs.sanaei.dev/docs/config/subscription)
- Env vars: [https://docs.sanaei.dev/docs/reference/env-vars](https://docs.sanaei.dev/docs/reference/env-vars)
- Reverse proxy (Nginx/Caddy examples): [https://docs.sanaei.dev/docs/operations/reverse-proxy](https://docs.sanaei.dev/docs/operations/reverse-proxy)
- Image contract (`torotin/3x-ui`): https://github.com/Torotin/AutoDockerBuilder/blob/main/bin/3x-ui/README.md

This stack terminates TLS at **Traefik**, not the official Nginx/Caddy samples. Keep `webBasePath` (`/${URI_PANEL_PATH}/`) behind the proxy. For Xray core behavior use https://xtls.github.io/.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/3x-ui-runtime.md](references/3x-ui-runtime.md) before changing runtime scripts, compose labels, Xray desired state, or server reset/deploy flows.
3. Read [references/3x-ui-api.md](references/3x-ui-api.md) before changing panel API calls, auth, clients, inbounds, hosts, nodes, settings, backup, or destructive operations.
4. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```

## Ownership

- Compose service: `docker-proxy/compose.d/12-3x-ui.yml`.
- Runtime scripts: `docker-proxy/3x-ui/scripts/00_BeforeStart`, `docker-proxy/3x-ui/scripts/01_AfterStart`, and `docker-proxy/3x-ui/scripts/lib`.
- Environment: `docker-proxy/3x-ui/3x-ui.env` plus compose `.env`.
- Panel DB: `docker-proxy/3x-ui/configs/x-ui.db`; reset source is `docker-proxy/3x-ui/clear/x-ui.db` (SQLite; PostgreSQL is upstream-supported but not used here).
- Tests: `tests/3x-ui-scripts/run.sh`.

## Live Stack Contract

| Route | Path prefix (env) | Traefik service |
|---|---|---|
| Panel / API | `/${URI_PANEL_PATH}`, `/${URI_PANEL_PATH}/panel/api`, `/${URI_PANEL_PATH}/health` | `3xui-panel-svc` |
| Subscriptions | `${URI_SUB_PATH}`, `${URI_JSON_PATH}`, `${URI_CLASH_PATH:-/clash/}` | `3xui-sub-svc` |
| XHTTP | `${URI_VLESS_XHTTP}` | `xhttp3xui-svc` |
| gRPC (upstream TLS) | `${URI_VLESS_GRPC}` | `grpc3xui-svc` |

- Traefik routers for panel, API, native subscriptions, XHTTP, and gRPC use `websecure`. Do not invent or document Traefik L4 TCP / REALITY passthrough unless live compose actually adds it.
- Public HTTPS terminates at Traefik for panel, API, native subscription, and XHTTP routes; the container still talks to the local panel over HTTP/HTTPS candidates during bootstrap.
- Subscription formats (raw/JSON/Clash) are served by the panel's **subscription server** on `subPort` (`PORT_LOCAL_VLESS_SUBSCRIBE`); Traefik path-prefixes forward to that port.
- `adguard` is the DNS peer. Managed Xray DNS should prefer AdGuard when reachable.
- SOCKS egress peers come from the `proxy-backends` area: `usque` for WARP-like SOCKS and `tor-proxy` for TOR SOCKS.
- `sub-json-processor` and `tests/sub-json-processor` are **do-not-revive**. Native 3x-ui subscription, JSON subscription, and Clash paths are routed directly to the 3x-ui subscribe port.

## Validation

Run this after changing 3x-ui scripts or their tests:

```bash
bash tests/3x-ui-scripts/run.sh
```

Use static diff hygiene before committing:

```bash
git diff --check
```

For Xray desired-state edits, also validate the generated runtime config on the server when available:

```bash
/app/bin/xray-linux-amd64 run -test -c /app/bin/config.json
```

## Server DB Reset Flow

Use only when intentionally resetting the live 3x-ui DB:

```bash
/opt/docker-proxy/compose.d/run-compose.sh down 3x-ui
cp /opt/docker-proxy/3x-ui/clear/x-ui.db /opt/docker-proxy/3x-ui/configs/x-ui.db
/opt/docker-proxy/compose.d/run-compose.sh restart 3x-ui
```

## Do Not Revive

- `docker-proxy/3x-ui/sub-json-processor` — do-not-revive
- `tests/sub-json-processor` — do-not-revive
- removed `caddy/subs` subscription HTML tree — do-not-revive
- legacy `torproxy` naming — do-not-revive; use the current `tor-proxy` service unless live code says otherwise
- legacy inbound `externalProxy` array — superseded by Hosts API (`/panel/api/hosts`); do not reintroduce

If this skill disagrees with live compose or scripts, code wins: fix the skill in the same change set. If it disagrees with upstream docs about panel product behavior, verify against the deployed panel version and update this skill.
