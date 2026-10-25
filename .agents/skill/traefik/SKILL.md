---
name: traefik
description: Use when editing or operating docker-proxy/traefik, Traefik static or dynamic file-provider config, 06-traefik.yml, Traefik entrypoints, CrowdSec bouncer middleware, ACME certificates, or traefik-acme-exporter in 3x-ui_pro_Docker.
---

# Traefik

Use this skill for the project Traefik edge proxy: static config, dynamic file-provider fragments, ACME storage/export, entrypoints, dashboard middleware chains, and the `traefik` / `traefik-acme-exporter` compose services.

## Official documentation

- Traefik docs: https://doc.traefik.io/traefik/
- Routers / middlewares / entrypoints / Docker provider: use the matching guides under doc.traefik.io
- This stack terminates public TLS at Traefik (`web` -> HTTPS `:443`, `websecure` on `:4443` inside the container). Do not assume live L4 TCP/UDP.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/compose-traefik.md](references/compose-traefik.md) before changing Traefik compose files or config.
3. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
4. Treat live files as authoritative: `docker-proxy/compose.d/06-traefik.yml`, `docker-proxy/compose.d/06-traefik-pem-export.yml`, and `docker-proxy/traefik/**`.

## Ownership

Own:
- `docker-proxy/compose.d/06-traefik.yml`
- `docker-proxy/compose.d/06-traefik-pem-export.yml`
- `docker-proxy/traefik/**`
- `traefik` and `traefik-acme-exporter` operational restart/order guidance

Do not own per-app router label details. For app-specific routing, read the owning service skill (`lampac`, `arcane`, `3x-ui`, `adguard`, `homepage`, and so on) and keep this skill focused on shared Traefik behavior.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure` unless noted. Entrypoints live: `web` (`:80`) and `websecure` (`:4443` inside Traefik). No live L4 TCP/UDP entrypoints.

| Service skill | Path / rule (from compose) | Notes |
|---|---|---|
| `traefik` | `/${URI_TRAEFIK_DASHBOARD}`, `/${URI_TRAEFIK_DASHBOARD}/dashboard*`, `/${URI_TRAEFIK_DASHBOARD}/api*`, `/${URI_TRAEFIK_DASHBOARD}/metrics`, root `/api*`, dashboard manifest | `api@internal`; root `/api` is a dashboard conflict zone with Arcane/Homepage carve-outs. |

### Product routing (upstream)

- Docker provider reads only containers with `traefik.enable=true` and `traefik.tags=traefik`.
- Public routers must bind to `websecure` and use the `le` certificate resolver.
- The `web` entrypoint only redirects to public HTTPS `:443`; it is not an app router target.
- Shared file-provider middlewares live under `/dynamic` and are referenced with `@file`.
- Admin routes use chain middlewares for `bouncer@file`, BasicAuth, rate limiting, security headers, and compression.
- Dashboard compatibility uses strip-prefix and redirects around `${URI_TRAEFIK_DASHBOARD}` plus the root `/api` router.
- Keep root `/api` priority coordinated with Arcane/Homepage carve-outs; do not broaden it casually.
- Do not add or document L4 TCP/UDP routing unless live compose/static config actually exposes it.

## Core Rules

- Live entrypoints are **`web` (`:80`)** and **`websecure` (`:4443`)** only (see `docker-proxy/traefik/traefik.yml`).
- Static config redirects **`web` → public `:443` with HTTPS** (not an entrypoint named `websecure` on `:443`).
- Compose publishes **`80:80`** only; the healthcheck still probes **`80` and `4443` inside the container**.
- The file provider watches `/dynamic`; shared file-provider middleware must be referenced with `@file`.
- `bouncer@file` depends on `docker-proxy/traefik/dynamic/crowdsec.yml`; do not move it into Docker labels unless deliberately redesigning the CrowdSec integration.
- Restart Traefik before the ACME exporter after certificate or ACME changes:
  ```bash
  docker-proxy/compose.d/run-compose.sh restart traefik
  docker-proxy/compose.d/run-compose.sh restart traefik-acme-exporter
  ```
- Treat HTTP/3 changes as high risk. Keep H2 as default unless there is an explicit rollback plan and UDP/entrypoint validation.
- Do not introduce colliding middleware names such as `https-redirect` in Docker labels. Prefer the static `web` → `:443` HTTPS redirect in `traefik.yml`.
- Do not revive **`l4tcp` / `l4udp`** or `docker-proxy/traefik/dynamic_old/**`; those belong to the removed TCP-clean / L4 architecture (historical only; do not restore as current ops).

## Validation

Prefer local/static checks first:

```bash
docker-proxy/compose.d/run-compose.sh validate
bash tests/run-compose/test_stage_tcp_clean_architecture.bash
git diff --check
```

For live operations, provide exact sync/restart/log commands instead of mutating a server unless the user asks.
