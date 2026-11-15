# Compose and Traefik

This reference covers the project Traefik edge service and ACME PEM exporter. Per-app router labels belong to the owning service skills; use this file only for shared Traefik behavior, entrypoints, file-provider fragments, middleware naming, and restart order.

## Owned Files

- `docker-proxy/compose.d/06-traefik.yml`
- `docker-proxy/compose.d/06-traefik-pem-export.yml`
- `docker-proxy/traefik/traefik.yml`
- `docker-proxy/traefik/dynamic/*.yml`
- `docker-proxy/traefik/exporter.sh`
- `docker-proxy/traefik/acme.json`
- `docker-proxy/traefik/pem/`

Do not use this skill to redesign app-specific routers in files such as Lampac, Arcane, AdGuard, Homepage, or 3x-ui compose fragments. Load the service skill that owns the app and preserve the shared Traefik contracts below.

## Static Configuration

File: `docker-proxy/traefik/traefik.yml`

Current shared behavior:

- Docker provider:
  - endpoint is the local Docker socket mounted read-only into Traefik
  - `exposedByDefault: false`
  - network is `traefik-proxy`
  - provider constraints require `traefik.tags=traefik`
- File provider:
  - directory mode on `/dynamic`
  - `watch: true`
  - fragments merge into the same dynamic configuration namespace
- ACME:
  - resolver is `le`
  - storage is `/acme.json`
  - HTTP challenge uses `web`
  - key type is `EC256`
- Dashboard API is enabled but not insecure; Docker labels on the Traefik service expose it under the configured admin hostname/path.

## Entrypoints

Live static entrypoints (`docker-proxy/traefik/traefik.yml`):

| Entrypoint | Purpose | Notes |
|---|---|---|
| `web` | HTTP on `:80` | Redirects to **public `:443` with HTTPS** (`permanent: true`). This is not a redirect to the `websecure` entrypoint name. |
| `websecure` | HTTPS app routes on `:4443` | Trusted proxy and forwarded-header networks include `traefik-proxy` and `dns-net`. |

**Historical (do not revive):** `l4tcp` / `l4udp` and related fragments under `docker-proxy/traefik/dynamic_old/**` were part of a removed TCP-clean / L4 edge architecture. Do not treat them as a current ops contract or re-enable them without an explicit redesign.

Do not add per-service HTTP redirect routers when the static `web` redirect already covers the case. In particular, avoid shared Docker-label middleware names such as `https-redirect`; middleware names are global within a provider and can collide across services.

## Dynamic File Provider

Directory: `docker-proxy/traefik/dynamic/`

Current active fragments:

- `crowdsec.yml`
  - defines `admin-security-headers`
  - defines `bouncer`
  - exposes `bouncer@file` to Docker-label chains such as `secured-chain`
  - reads `CROWDSEC_API_KEY_TRAEFIK` from the Traefik environment
  - talks to CrowdSec LAPI at `crowdsec:8080` and AppSec at `crowdsec:7422`
- `arcane.yml`
  - defines shared Arcane path-prefix helper middlewares used by the Arcane compose labels
  - requires file-provider directory mode and environment values such as `URI_ARCANE` and `WEBDOMAIN`

Use the `@file` provider suffix when Docker labels reference file-provider middleware, for example `bouncer@file` or `admin-security-headers@file`. Do not create Docker-label middlewares with the same names unless intentionally replacing the provider boundary.

`docker-proxy/traefik/dynamic_old/**` is remnant material. Do not revive it as active configuration; use it only for explicit archival comparison.

## Traefik Compose Service

File: `docker-proxy/compose.d/06-traefik.yml`

Key contracts:

- image/container: `traefik:latest` / `traefik`
- depends on healthy `crowdsec`, `crowdsec-firewall-bouncer`, and `caddy` in the current live fragment
- mounts:
  - Docker socket read-only
  - static config to `/etc/traefik/traefik.yml`
  - ACME storage to `/acme.json`
  - dynamic file-provider directory to `/dynamic:ro`
  - logs to `/logs`
- entrypoint ensures `/acme.json` exists, is `0600`, and is root-owned before starting Traefik
- networks:
  - `traefik-proxy` at `172.18.0.6` / `fd00:dead:beef:12::6`
  - `dns-net` at `172.19.0.6` / `fd00:dead:beef:13::6`
- **ports:** compose publishes **`80:80` only** (no host bind for `4443`; upstream terminates TLS on public `:443` elsewhere)
- healthcheck verifies the process and local **`80` / `4443` inside the container**

Traefik labels define shared admin middleware chains:

- `secured-chain`: `bouncer@file`, BasicAuth, rate limit, `admin-security-headers@file`, compression
- `dashboard-manifest-chain`: `bouncer@file`, rate limit, `admin-security-headers@file`, dashboard prefix strip, compression
- `api-chain`: rate limit and compression for internal web-service API routes
- `static-chain`: compression only

Keep these shared chains generic. App-specific middlewares and route priorities belong to their app skills.

## ACME PEM Exporter

File: `docker-proxy/compose.d/06-traefik-pem-export.yml`

Service: `traefik-acme-exporter`

Contracts:

- depends on healthy `traefik`
- mounts `../traefik/acme.json` read-only
- writes exported PEM files under `../traefik/pem`
- runs `docker-proxy/traefik/exporter.sh`
- healthcheck reads `/home/health.json` and requires `.process == "running"` and status not `ERROR`
- healthcheck interval should stay short enough to leave `starting` quickly after certificate processing

`exporter.sh` installs `jq`, `inotify-tools`, and `coreutils`, watches `/acme.json`, exports `<domain>-cert.pem`, `<domain>-key.pem`, and `<domain>-fullchain.pem`, converts wildcard names to `wildcard-example.com`, writes atomically through `*.tmp`, removes stale PEM files, and records `INIT`, `IDLE`, `OK`, `WARN`, or `ERROR` in `/home/health.json`.

After certificate, ACME storage, or exporter changes, restart in this order:

```bash
docker-proxy/compose.d/run-compose.sh restart traefik
docker-proxy/compose.d/run-compose.sh restart traefik-acme-exporter
docker-proxy/compose.d/run-compose.sh logs traefik
docker-proxy/compose.d/run-compose.sh logs traefik-acme-exporter
```

## HTTP/3 Caution

A previous HTTP/3 attempt caused loss of access to web services after container restart. Treat H3 as high risk:

- keep HTTP/2 as the default
- do not casually bind public `:443/udp` or revive historical L4/UDP entrypoints from `dynamic_old/`
- prepare rollback before changing UDP or HTTP/3 settings
- validate Traefik logs after restart

Do not edit or re-enable `docker-proxy/traefik/dynamic_old/l4-udp-vless.yml` or other `dynamic_old/**` L4 material; it is historical and unused.

## Local Validation

Use static validation before live mutation:

```bash
docker-proxy/compose.d/run-compose.sh validate
bash tests/run-compose/test_stage_tcp_clean_architecture.bash
git diff --check
```

If live changes are requested, prefer this sequence:

```bash
docker-proxy/compose.d/run-compose.sh restart traefik
docker-proxy/compose.d/run-compose.sh restart traefik-acme-exporter
docker-proxy/compose.d/run-compose.sh logs traefik
docker-proxy/compose.d/run-compose.sh logs traefik-acme-exporter
```
