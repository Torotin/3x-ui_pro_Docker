---
name: homepage
description: Use when editing or operating Homepage in 3x-ui_pro_Docker, including 13-homepage.yml, docker-proxy/homepage configuration, dashboard widgets, /api routing conflicts, :3000 healthchecks, host validation, or restarts.
---

# Homepage

Use this skill for the active Homepage dashboard and its config directory under `docker-proxy/homepage/`.

## Official documentation

- Homepage docs: https://gethomepage.dev/
- Stack path: `/${URI_HOMEPAGE}` plus explicit `/_next/` and widget/NextAuth `/api/*` carve-outs in `13-homepage.yml`. Do not claim ownership of full `/api` (Arcane/Traefik).

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/13-homepage.yml`
   - `docker-proxy/homepage/**`

## Ownership

Own:
- `docker-proxy/compose.d/13-homepage.yml`
- `docker-proxy/homepage/**`
- Homepage dashboard config, widgets, bookmarks, services, and logs
- Homepage Traefik labels and allowed-host behavior

Coordinate with `arcane`, `lampac`, and `traefik` before changing root `/api` routes or shared middleware assumptions.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure`.

| Route / router | Rule | Priority | Middleware / notes |
|---|---|---:|---|
| `homepage-router` | `PathPrefix('/${URI_HOMEPAGE}')` | 950 | Main dashboard, BasicAuth, strip `/${URI_HOMEPAGE}`, Location rewrite, compression. |
| `homepage-static` | `PathPrefix('/_next/')` plus selected NextAuth/widget `/api/*` paths | 949 | Static/API carve-outs only; keeps Homepage APIs above Arcane root `/api`. |
| `homepage-favicon` | `Path('/favicon.ico')` | 951 | Maps root favicon to `/homepage.ico` without BasicAuth. |
| `homepage-icons` | `PathPrefix('/favicon')`, Apple/Android icons, `site.webmanifest`, `homepage.ico`, Safari pinned tab | 949 | Root icon/PWA assets without BasicAuth to avoid public-page login prompts. |

Root `/api` is a conflict zone: Homepage owns only the explicit paths listed in `13-homepage.yml`; Arcane owns broad `/api` at priority `900`; Traefik dashboard also has root `/api*` for `api@internal` at lower dashboard priority. Never replace the selected Homepage list with broad `/api` or `/api/auth`.

## Product Routing

- Homepage config lives under `docker-proxy/homepage/` and is mounted to `/app/config`; logs mount to `/logs`.
- Dashboard services/widgets consume `HOMEPAGE_VAR_*` env values for stack URLs, credentials, Mihomo secret, and path variables.
- Server-side widgets resolve `${WEBDOMAIN}` to Traefik (`172.18.0.6`) through `extra_hosts`; keep that path for HTTPS/self-hosted widget calls.
- `HOMEPAGE_ALLOWED_HOSTS` must include `${WEBDOMAIN}` and local probe hosts so app host validation and Traefik healthchecks both pass.
- The Docker socket is read-only for container status/stats; prefer a constrained socket proxy before expanding access.
- Keep NextAuth carve-outs narrow: `/api/auth/signin`, signout/session/csrf/providers/error/log/callback paths only.

## Core Rules

- Keep Homepage on `172.18.0.13` and `172.19.0.13`.
- Keep config mounted from `docker-proxy/homepage` to `/app/config`; logs mount to `docker-proxy/homepage/logs`.
- Keep the container healthcheck on `127.0.0.1:3000` with `/api/healthcheck` fallback to `/`.
- Keep `HOMEPAGE_ALLOWED_HOSTS` including `${WEBDOMAIN}`, `localhost:3000`, and `127.0.0.1:3000`.
- Keep `${WEBDOMAIN}:172.18.0.6` in `extra_hosts` so server-side widgets can reach Traefik internally by public hostname.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh restart homepage
docker-proxy/compose.d/run-compose.sh logs homepage
```

Traefik probes service port `3000` at `/api/healthcheck` and sets healthcheck hostname to `${WEBDOMAIN}` so Homepage host validation accepts the probe.

## Traefik Notes

- Main dashboard route: `/${URI_HOMEPAGE}`, priority `950`, with BasicAuth.
- Homepage static/API route priority is `949`; it intentionally covers selected NextAuth and Homepage APIs only.
- Do not broaden `/api/auth`; Arcane owns `/api/auth/login`, `/api/auth/me`, refresh paths, and related app APIs.
- Icons and `/favicon.ico` are routed without BasicAuth to avoid login prompts on public pages that request root icons.
- Prefix strip and Location rewrite are required for path-prefix operation.

## Pitfalls

- Do not remove the healthcheck hostname override; Traefik can otherwise mark the backend unhealthy with HTTP 503.
- Do not expose the Docker socket with more privileges than the current read-only mount; prefer a constrained socket proxy if redesigning.
- Do not place service secrets directly in dashboard YAML; use existing `HOMEPAGE_VAR_*` environment variables.
- Do not expand root icon routes into broad static catch-alls that steal Caddy or app assets.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart homepage
git diff --check
```
