---
name: telemt
description: Use when editing or operating Telemt in 3x-ui_pro_Docker, including 15-telemt.yml, docker-proxy/telemt, docker-proxy/telemt-panel, telemt installer templates, telemt-panel routing, ENABLE_TELEMT, health, or restarts.
---

# Telemt

Use this skill for the optional Telemt stack and Telemt panel in this repository.

## Official documentation

- Telemt: https://github.com/telemt/telemt
- Telemt docs: https://github.com/telemt/telemt/tree/main/docs
- Panel in this image: https://github.com/amirotin/telemt_panel
- Image contract (`torotin/telemt-stack`): https://github.com/Torotin/AutoDockerBuilder/blob/main/bin/telemt-stack/README.md

Optional stack via `ENABLE_TELEMT`. Panel Traefik path: `/${URI_TELEMT_PANEL}` on `websecure` with BasicAuth/rate-limit/noindex/CrowdSec/admin headers per `15-telemt.yml`.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/15-telemt.yml`
   - `docker-proxy/telemt/**`
   - `docker-proxy/telemt-panel/**`
   - `script/template/telemt.config.toml.template`
   - `script/template/telemt-panel.config.toml.template`

## Ownership

Own:
- `docker-proxy/compose.d/15-telemt.yml`
- `docker-proxy/telemt/**`
- `docker-proxy/telemt-panel/**`
- Telemt and Telemt panel installer templates under `script/template/telemt*.toml.template`
- `ENABLE_TELEMT` compose inclusion behavior and Telemt doctor/inventory notes

Coordinate with `installer` when template rendering changes and with `traefik` for shared edge middleware. Telemt is optional: `run-compose.sh` includes `15-telemt.yml` only when `ENABLE_TELEMT` is truthy.

## Core Rules

- Keep `telemt` on `172.18.0.15` / `172.19.0.15` and dual-stack ULA pins unless the live network plan changes.
- Keep AdGuard as the DNS dependency and resolver (`172.19.0.10`).
- Keep Telemt config writable at `/etc/telemt`, runtime data at `/var/lib/telemt`, panel config read-only at `/etc/telemt-panel`, and panel data writable.
- Treat `/var/run/docker.sock` access and `DOCKER_SOCKET_GID` as privileged; do not broaden permissions casually.
- Preserve panel routing under `/${URI_TELEMT_PANEL}` with BasicAuth, rate limit, noindex, CrowdSec bouncer, and admin security headers.
- Keep API and metrics listeners internal to the Docker networks unless an explicit public exposure plan exists.

## Live Stack Contract

| Surface | Reachability | Role |
|---|---|---|
| MTProto / Fake TLS listener | container expose `${PORT_LOCAL_TELEMT_PROXY:-9443}` | Telemt proxy listener; configured inside `/etc/telemt/config.toml` |
| Telemt API | internal expose `${PORT_LOCAL_TELEMT_API:-9091}` | Local control API for stack consumers |
| Metrics | internal expose `${PORT_LOCAL_TELEMT_METRICS:-9090}` | Internal observability endpoint |
| Panel | Traefik `Host(${WEBDOMAIN}) && PathPrefix(/${URI_TELEMT_PANEL})` on `websecure` to `${PORT_LOCAL_TELEMT_PANEL:-8080}` | Bundled `amirotin/telemt_panel` UI protected by BasicAuth, rate limit, noindex, CrowdSec, and admin security headers |

The MTProto listener is config/ports inside the `telemt` container, not Traefik L4 routing. Traefik routes only the panel HTTP path in this compose fragment.

### Product routing (upstream)

- Telemt supports official MTProto proxy modes: classic, secure (`dd` prefix), and Fake TLS (`ee` prefix with SNI fronting).
- Optional traffic masking can forward unrecognized connections to a real web target; in this stack, Telemt participates in Vision/REALITY fallback only when `ENABLE_TELEMT=true`.
- The bundled panel must stay base-path aware: preserve `/${URI_TELEMT_PANEL}` in panel config, healthchecks, and Traefik routing.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart telemt
docker-proxy/compose.d/run-compose.sh logs telemt
```

The healthcheck runs `telemt healthcheck /etc/telemt/config.toml --mode liveness` and verifies the panel base path on the local panel port.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
bash -n docker-proxy/compose.d/run-compose.sh
git diff --check
```
