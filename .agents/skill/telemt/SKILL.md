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
- Stack design (admin Host + subpage): [docs/superpowers/specs/2026-11-01-telemt-admin-subpage-design.md](../../docs/superpowers/specs/2026-11-01-telemt-admin-subpage-design.md)
- WEB path design: [docs/superpowers/specs/2026-11-01-telemt-web-path-design.md](../../docs/superpowers/specs/2026-11-01-telemt-web-path-design.md)

Optional stack via `ENABLE_TELEMT`. **Panel admin** is `https://telemt.${WEBDOMAIN}:${PORT_LOCAL_ADMIN}/` (Traefik entrypoint `admin`, empty panel `base_path`). **Subpage** is public `https://${WEBDOMAIN}/${URI_TELEMT_SUB}/…` on `websecure` (no BasicAuth; HMAC tokens). **WEB** stays `https://${WEBDOMAIN}/${URI_TELEMT_WEB}/…` on `websecure`.

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
- Treat `/var/run/docker.sock` access and `DOCKER_SOCKET_GID` as privileged; do not broaden permissions casually. Logs UI needs: real socket GID (not `0`) in `group_add`; bind-mount `/usr/bin/docker` (panel 1.0.0-rc.3 returns `command_missing` without CLI — socket alone is not enough); `[host] log_source=docker` with `telemt_container`/`panel_container` both `telemt` (no separate `telemt-panel` container).
- **Panel admin:** Traefik `Host(telemt.${WEBDOMAIN})` on entrypoint `admin` → panel `:8080` with `base_path=""`. Middlewares: BasicAuth, rate limit, noindex, compress, `admin-security-headers@file`. **No** `bouncer@file` on admin (parity with homepage / 3x-ui admin).
- **Subpage:** Traefik `Host(${WEBDOMAIN}) && PathPrefix(/${URI_TELEMT_SUB})` on `websecure` → sub listener `:8081`. Middlewares: `bouncer@file`, rate, noindex. **Do not** strip `base_path` (no Stripprefix).
- Keep API and metrics listeners internal to the Docker networks unless an explicit public exposure plan exists.
- Add AdGuard admin rewrite `telemt.${WEBDOMAIN}` → `172.18.0.6` (`ensure-admin-rewrites.sh`).

## Live Stack Contract

| Surface | Reachability | Role |
|---|---|---|
| FakeTLS / MTProto listener | container `${PORT_LOCAL_TELEMT_PROXY:-9443}` (not Traefik L7) | Telemt proxy listener; mask chain to `traefik:4443` per `[censorship]` in `/etc/telemt/config.toml` |
| WEB listener | container `${PORT_LOCAL_TELEMT_WEB:-18080}` | Plain HTTP WEB transport; Traefik `websecure` PathPrefix `/${URI_TELEMT_WEB}` terminates TLS |
| Telemt API | internal `${PORT_LOCAL_TELEMT_API:-9091}` | Loopback from panel; whitelist Docker nets in config |
| Metrics | internal `${PORT_LOCAL_TELEMT_METRICS:-9090}` | Internal observability |
| Panel (admin) | `https://telemt.${WEBDOMAIN}:${PORT_LOCAL_ADMIN:-9443}/` via Traefik **admin** → `${PORT_LOCAL_TELEMT_PANEL:-8080}` | telemt_panel **1.x** UI; Traefik BasicAuth + panel login; empty `base_path` |
| Subpage | `https://${WEBDOMAIN}/${URI_TELEMT_SUB}/<token>` via **websecure** → `${PORT_LOCAL_TELEMT_SUB:-8081}` | Panel `[subpage]`; path preserved; token HMAC via `TELEMT_SUBPAGE_SECRET` |
| WEB path | `https://${WEBDOMAIN}/${URI_TELEMT_WEB}/…` via **websecure** → WEB port | Carrier + decoy; no BasicAuth; long `telemt-web@file` transport (YAML under `docker-proxy/telemt/`, mounted into Traefik only via `15-telemt.yml`) |

Public TCP `:443` stays on Reality; unrecognized TLS on the Telemt FakeTLS listener is masked to `traefik:4443` (PROXY v1). Do not route panel or subpage through Stripprefix middleware.

Telemt TG egress uses `socks5://3x-ui:${PORT_LOCAL_XRAY_MIXED}` (`use_middle_proxy=false`, direct upstream disabled). Xray applies default routing — do not hard-code `mihomo:7890` in Telemt config unless the live stack plan explicitly changes.

### Panel config (telemt_panel 1.x)

Rendered from `script/template/telemt-panel.config.toml.template`. Must pass `telemt-panel config check` in the target image.

- Root: `listen`, `base_path=""`, `public_url=https://telemt.${WEBDOMAIN}:${PORT_LOCAL_ADMIN}`, `trusted_proxies` (Traefik CIDRs), `data_dir`
- `[tls] mode=http` (Traefik terminates TLS on admin and websecure)
- `[telemt] url` + `auth_header` only (no 0.6 `auto_update` / `config_edit_mode`)
- `[auth] username` + `password_hash` (`TELEMT_PANEL_PASSWORD_HASH_RAW`); **no `jwt_secret`** in this stack (panel 1.x template omits it unless a future image gate requires it)
- `[subpage]` enabled, listen on `PORT_LOCAL_TELEMT_SUB`, `base_path=/${URI_TELEMT_SUB}`, `public_url=https://${WEBDOMAIN}`, `secret=TELEMT_SUBPAGE_SECRET`
- `[host]` `service_manager=docker`, `log_source=docker`, `telemt_container=telemt`, `panel_container=telemt`; `[privileges] mode=manual`
- **GeoIP:** not in panel TOML — applied by `docker-proxy/telemt-panel/ensure-geoip.sh` via `PUT /api/settings/geoip` after `run-compose` up/restart/rebuild of `telemt`. Runs **in background** and does **not** wait for MMDB `ready` (panel downloads asynchronously). Defaults (operator-chosen community mirror): P3TERX `GeoLite2-{City,ASN,Country}.mmdb` direct HTTPS under `raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/…` (`TELEMT_GEOIP_*` env). Panel docs mark P3TERX as `source_unconfirmed` for auto-updates; explicit enable is an operator choice (GeoLite EULA / attribution remain operator responsibility). Set `TELEMT_GEOIP_ENABLED=false` to skip.
- **Deprecated for routing:** `URI_TELEMT_PANEL` — do not use in Traefik rules, panel `base_path`, or healthcheck path; may remain in env until fully removed from templates

Subpage URL contract (upstream): `public_url + base_path + "/" + <user-token>`.

### WEB / `tg://webproxy` link (path mode)

WEB profile uses `secret_mode = "dd"` and `carrier = "https"` with vhost `base_path = URI_TELEMT_WEB`. Telegram Desktop links use the **path** webproxy form, not a root hex `dd…` URL:

```text
tg://proxy?server=HOST%2Fbase_path&port=443&secret=<base64url(secret)>
```

Where `HOST` is `${WEBDOMAIN}`, `base_path` is `${URI_TELEMT_WEB}` (no leading slash in the `server` parameter value: `HOST%2F${URI_TELEMT_WEB}`), and `secret` is base64url-encoded material for the WEB user profile (see installer summary / panel for the live hex secret). Public entry is always `https://${WEBDOMAIN}/${URI_TELEMT_WEB}/…` through Reality → mask → Traefik.

### Telemt `config.toml` invariants

- `[server.api] runtime_edge_enabled = true` (panel event journal / connections summary; upstream default is false → `feature_disabled`)
- `use_middle_proxy = false`
- `decoy_fasttrack_mode = "off"` on `[web]`
- Socks upstream → `3x-ui:${PORT_LOCAL_XRAY_MIXED}` enabled; **direct** upstream `enabled = false`
- `[censorship]`: `mask_host = "traefik"`, `mask_port = 4443`, `mask_proxy_protocol = 1`
- `public_addr = "${PUBLIC_IPV4}:443"` on WEB vhost

### Live apply: preserve `[access.users]`

When refreshing `telemt.config.toml` on an existing host, **do not** blind-overwrite live users or panel-added WEB profiles. Procedure:

1. Timestamped backup of live `config.toml`
2. Render template to a side file
3. Merge from backup: entire `[access.users]` map; extra `[[web.vhosts.profiles]]` from the panel; optional panel-expanded `[web.limits]` / timeouts if absent in the new file
4. Validate with `telemt healthcheck`, then restart

Details and a Python merge script: [references/live-config-merge.md](references/live-config-merge.md) (same content as repo `.tmp/task3-merge-procedure.md`).

Rotating `TELEMT_SUBPAGE_SECRET` invalidates all issued subpage links.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart telemt
docker-proxy/compose.d/run-compose.sh logs telemt
```

Healthcheck: `telemt healthcheck /etc/telemt/config.toml --mode liveness` and `curl -fsS http://127.0.0.1:${PORT_LOCAL_TELEMT_PANEL}/` (panel root, no path prefix).

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
bash -n docker-proxy/compose.d/run-compose.sh
git diff --check
```

## Canonical Telemt env (operator surface)

After install render / compose `.env` (see `02_env.sh` + `docker.env.template` / `install.env.template` parity):

| Key | Role |
|---|---|
| `ENABLE_TELEMT` | Include `15-telemt.yml` |
| `URI_TELEMT_WEB`, `URI_TELEMT_SUB` | Public path segments (unique vs other `URI_*`) |
| `PORT_LOCAL_TELEMT_*` | Proxy `9443`, WEB `18080`, API `9091`, metrics `9090`, panel `8080`, sub `8081` |
| `TELEMT_STACK_IMAGE` | `torotin/telemt-stack` pin |
| `TELEMT_API_AUTH_HEADER`, `TELEMT_SUBPAGE_SECRET` | API auth + sub HMAC |
| `TELEMT_PANEL_PASSWORD_HASH` / `TELEMT_PANEL_PASSWORD_HASH_RAW` | Panel login |
| `TELEMT_WEB_*` | WEB user, secret hex, carrier, decoy upstream |
| `TELEMT_*` tuning | Middle-proxy-related keys; safe to keep while `use_middle_proxy=false` |

Installer summary URLs: `SUMMARY_URL_TELEMT_PANEL` → admin Host; `SUMMARY_URL_TELEMT_SUB` → public sub base path.
