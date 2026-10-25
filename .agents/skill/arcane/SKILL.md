---
name: arcane
description: Use when editing or operating Arcane in 3x-ui_pro_Docker, including 07-arcane.yml, docker-proxy/traefik/dynamic/arcane.yml, Docker manager UI routing, path-prefix behavior, root /api conflicts, health, or restarts.
---

# Arcane

Use this skill for the active Docker management UI that replaced Dozzle, including its path-prefix Traefik workaround.

## Official documentation

- Arcane docs: https://getarcane.app/docs
- Reverse proxy / networking guides under getarcane.app/docs
- This stack uses path-prefix UI (`/${URI_ARCANE}`) plus root exceptions (`/_app`, `/api`, PWA, `/img`, `/login`). Upstream has no true subpath support — follow live compose + `docker-proxy/traefik/dynamic/arcane.yml`.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/07-arcane.yml`
   - `docker-proxy/traefik/dynamic/arcane.yml`

## Ownership

Own:
- `docker-proxy/compose.d/07-arcane.yml`
- `docker-proxy/traefik/dynamic/arcane.yml`
- Arcane router priorities, root-path exceptions, and response-body rewrite middleware
- `arcane-data` volume expectations and `PROJECTS_DIRECTORY=/opt/docker-proxy`

Coordinate with `traefik` for shared file-provider/plugin behavior and with `compose-stack` for startup ordering.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure`.

| Route / router | Rule | Priority | Middleware / notes |
|---|---|---:|---|
| `arcane-ui` | `PathPrefix('/${URI_ARCANE}')` | 1100 | Prefixed UI, BasicAuth, strip prefix, `arcane-body@file` HTML/manifest rewrite. |
| `arcane-app` | `PathPrefix('/_app')` | 1100 | SvelteKit assets; `arcane-js-body@file` rewrites hardcoded login/root assumptions. |
| `arcane-api` | `PathPrefix('/api')` | 900 | Broad root Arcane API, BasicAuth; lower than Homepage/Lampac carve-outs, above Traefik dashboard `/api`. |
| `arcane-pwa` | `/app.webmanifest`, `/service-worker.js` | 1100 | Root PWA helpers with body rewrite. |
| `arcane-img` | `PathPrefix('/img')` | 1100 | Root icons/images, no BasicAuth in the root chain. |
| `arcane-passkey` | `/arcane-mobile-passkey.json` | 1100 | Mobile passkey helper. |
| `arcane-login` | `/login` | 1200 | Redirects hardcoded SPA login into `/${URI_ARCANE}`. |
| `arcane-spa-root` | SPA root regexp families | 1200 | Redirects Arcane app roots such as dashboard, containers, projects, settings, images. |

Root `/api` is a conflict zone: Homepage selected widget/NextAuth APIs run at priority `949`, Lampac `/api/v1.0` and `/api/v2.0` run at `910`, Arcane broad `/api` runs at `900`, and Traefik dashboard `/api` must remain below those app carve-outs.

## Product Routing

- `APP_URL=https://${WEBDOMAIN}/${URI_ARCANE}` and `TRUSTED_PROXIES` make Arcane generate external links and trust Traefik/Docker proxy headers.
- Arcane manages Docker through `/var/run/docker.sock` and may manage project files through `/opt/docker-proxy`; treat both mounts as privileged.
- Upstream is not subpath-native: keep prefixed UI, root asset/API exceptions, and file-provider body/JS rewrites together.
- `docker-proxy/traefik/dynamic/arcane.yml` rewrites manifest scope/start URL, SvelteKit base assumptions, login redirects, and SPA root navigations.
- UI/API routes that include BasicAuth are still followed by Arcane's own app login; this dual-auth behavior is intentional.
- Keep root image matching narrow enough not to steal unrelated public decoy/static paths.

## Core Rules

- Keep Arcane on `172.18.0.7` and `172.19.0.7`.
- Keep `APP_URL=https://${WEBDOMAIN}/${URI_ARCANE}` and `TRUSTED_PROXIES` aligned with the project Docker networks.
- Arcane needs `/var/run/docker.sock` and `/opt/docker-proxy` mounts; treat changes here as privileged operations.
- Arcane upstream has no true subpath support. The project uses a prefixed UI route plus root exceptions for `/_app`, `/api`, PWA helpers, images, passkey, and SPA redirects.
- Historical path-prefix notes under `docs/superpowers/` are context only if present; day-to-day ops must follow the live compose and dynamic Traefik files.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh restart arcane
docker-proxy/compose.d/run-compose.sh restart traefik
docker-proxy/compose.d/run-compose.sh logs arcane
```

The healthcheck runs `./arcane health --timeout 2s`. Restart `traefik` after changing `docker-proxy/traefik/dynamic/arcane.yml`.

## Traefik Notes

- Main UI route is `/${URI_ARCANE}` with `stripPrefix` and `arcane-body@file`.
- Root `/api` belongs to Arcane at priority `900`; Lampac `/api/v1.0` and `/api/v2.0` must outrank it, and Homepage selected APIs sit at priority `949`.
- `/_app` uses JS body rewrites for hardcoded login/root assumptions.
- `/login` and SPA roots redirect into `/${URI_ARCANE}` via `arcane-spa-redirect@file`.
- Arcane UI and API are dual-auth where configured: Traefik BasicAuth plus Arcane app login.

## Pitfalls

- Do not treat Arcane as subpath-native; removing body rewrites or root exceptions breaks assets, login, and SPA navigation.
- Do not broaden root `/api` priority above Homepage or Lampac overrides.
- Do not add compression to chains that are kept WS/SSE-safe by design.
- `07-dozzle.yml.disable` / `dozzle` is a remnant only and do-not-revive; Arcane is the active manager UI.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart arcane
docker-proxy/compose.d/run-compose.sh restart traefik
git diff --check
```
