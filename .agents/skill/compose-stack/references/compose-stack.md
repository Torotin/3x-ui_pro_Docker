# Compose Stack Reference

Source of truth: live `docker-proxy/compose.d/*.yml` files in this repository. Files ending in `*.yml.disable` are remnants only and must not be documented as active services.

## Base Topology

`docker-proxy/compose.d/00-base.yml` defines external dual-stack Docker networks created by the installer:

| Network | IPv4 range | IPv6 range | Purpose |
|---|---:|---:|---|
| `traefik-proxy` | `172.18.0.0/24` | `fd00:dead:beef:12::/64` | public edge/backend network |
| `dns-net` | `172.19.0.0/24` | `fd00:dead:beef:13::/64` | internal DNS/service network |

Named volumes in base: `crowdsec_data`, `crowdsec_config`, `logrotate-status`, `lampac_cache` (tmpfs, 1 GiB), `tor-proxy-data`, and `tor-proxy-state`.

## Live Compose Inventory

Active means the file exists as `*.yml` in `docker-proxy/compose.d`, not as `*.yml.disable`. `run-compose.sh` may skip optional active fragments at runtime when their `ENABLE_*` env flag is false.

| Compose file | Service/container | Image | Networks/IPs | Notes |
|---|---|---|---|---|
| `02-logrotate.yml` | `logrotate` | `blacklabelops/logrotate:1.3` | none declared | Rotates `../_logs`, stores status in `logrotate-status`. |
| `03-crowdsec.yml` | `crowdsec` | `crowdsecurity/crowdsec` | `172.18.0.3` / `fd00:dead:beef:12::3`; `172.19.0.3` / `fd00:dead:beef:13::3` | LAPI/AppSec, loopback host ports `8080` and `7422`, feeds Caddy/Traefik/firewall bouncers. |
| `04-crowdsec-firewall-bouncer.yml` | `crowdsec-firewall-bouncer` / `crowdsec_firewall_bouncer` | `ghcr.io/shgew/cs-firewall-bouncer-docker:latest` | `network_mode: host` | Depends on healthy CrowdSec, uses `NET_ADMIN`/`NET_RAW`. |
| `05-caddy.yml` | `caddy` | `torotin/caddy-l4:latest` | `172.18.0.5` / `fd00:dead:beef:12::5`; `172.19.0.5` / `fd00:dead:beef:13::5` | Fallback/error backend and low-priority public catch-all. |
| `06-traefik.yml` | `traefik` | `traefik:latest` | `172.18.0.6` / `fd00:dead:beef:12::6`; `172.19.0.6` / `fd00:dead:beef:13::6` | Edge router; publishes host `80:80`; health probes `80` and internal `4443`. |
| `06-traefik-pem-export.yml` | `traefik-acme-exporter` | `alpine:latest` | none declared | Exports certs from `acme.json`, depends on healthy Traefik. |
| `07-arcane.yml` | `arcane` | `ghcr.io/getarcaneapp/manager:latest` | `172.18.0.7` / `fd00:dead:beef:12::7`; `172.19.0.7` / `fd00:dead:beef:13::7` | Docker management UI behind Traefik path-prefix workarounds. |
| `09-usque.yml` | `usque` | `${USQUE_IMAGE:-torotin/usque:latest}` | `172.18.0.9` / `fd00:dead:beef:12::9` | SOCKS backend; healthcheck confirms Cloudflare `warp=on`. |
| `10-adguard.yml` | `adguard` | `adguard/adguardhome:latest` | `172.18.0.10` / `fd00:dead:beef:12::10`; `172.19.0.10` / `fd00:dead:beef:13::10` | Stack DNS at `172.19.0.10`, DoH/panel via Traefik; plain DNS host ports are commented. |
| `11-tor-proxy.yml` | `tor-proxy` | `torotin/tor-proxy:latest` | `172.18.0.11` / `fd00:dead:beef:12::11`; `172.19.0.11` / `fd00:dead:beef:13::11` | Current TOR/DNS/SOCKS backend; uses `tor-proxy-data` and `tor-proxy-state`. |
| `12-3x-ui.yml` | `3x-ui` | `torotin/3x-ui:latest` | `172.18.0.12` / `fd00:dead:beef:12::12`; `172.19.0.12` / `fd00:dead:beef:13::12`; DNS `172.19.0.10` | Panel/Xray container; host publishes `443/tcp` and `443/udp`; depends on `usque`, `adguard`, `tor-proxy`, and `traefik-acme-exporter`. |
| `13-homepage.yml` | `homepage` | `ghcr.io/gethomepage/homepage:latest` | `172.18.0.13` / `fd00:dead:beef:12::13`; `172.19.0.13` / `fd00:dead:beef:13::13` | Dashboard; Traefik healthcheck forces `Host` to `${WEBDOMAIN}`. |
| `14-lampac.yml` | `lampac-fix-perms` | `alpine:latest` | `network_mode: none` | Oneshot `chown 1000:1000` on Lampac bind mounts; `restart: "no"` (exits after run). |
| `14-lampac.yml` | `lampac` | `ghcr.io/lampac-nextgen/lampac` | `172.18.0.14` / `fd00:dead:beef:12::14`; `172.19.0.14` / `fd00:dead:beef:13::14` | Optional by `ENABLE_LAMPAC`; waits for `lampac-fix-perms` (`service_completed_successfully`). |
| `15-telemt.yml` | `telemt` | `${TELEMT_STACK_IMAGE:-torotin/telemt-stack:latest}` | `172.18.0.15` / `fd00:dead:beef:12::15`; `172.19.0.15` / `fd00:dead:beef:13::15`; DNS `172.19.0.10` | Optional by `ENABLE_TELEMT`; exposes proxy/API/metrics/panel internally and routes panel via Traefik. |
| `16-mihomo.yml` | `mihomo` | `metacubex/mihomo:latest` | `traefik-proxy` without static IP | Optional by `ENABLE_MIHOMO`; routes dashboard/UI under `${URI_MIHOMO}`. |

## Runtime File Selection

`run-compose.sh` collects `*.yml` and `*.yaml` from `COMPOSE_DIR` in sorted order, then skips:

- `14-lampac.yml` unless `ENABLE_LAMPAC` is truthy.
- `15-telemt.yml` unless `ENABLE_TELEMT` is truthy.
- `16-mihomo.yml` unless `ENABLE_MIHOMO` is truthy.

Boolean false values are `0`, `false`, `no`, `off`, and `disabled`. Defaults are false for all three optional fragments.

## `run-compose.sh`

Default command is `up`, implemented as safe `docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT"` with retries.

Commands:

- `validate` / `config`: run `docker compose config` and warn on top-level `name:` conflicts.
- `list-files`: print selected compose files and exit before Docker/env validation.
- `up [SERVICE...]`: optional pull via `PULL_BEFORE_UP=1`, preflight container-name conflicts, retry `RETRY_COUNT` times, and optionally remove unhealthy containers when `CLEAN_UNHEALTHY=1`.
- `restart [--logs] SERVICE...`: remove and recreate targeted services; defaults to `--no-deps` unless `RESTART_WITH_DEPS=1`.
- `rebuild [SERVICE...]`: validate, optionally pull with `PULL_ON_REBUILD=1`, remove containers, and force recreate.
- `logs SERVICE [ARGS...]`: execs `docker logs -f`.
- `clean-unhealthy`: shows recent logs for unhealthy compose containers, then removes them.
- `maintenance [report|prune]`, `prune`, `gc`: dispatches to `docker-maintenance.sh`; default subcommand is `prune`.
- `down [ARGS...]`: pass-through to `docker compose down`.
- Any other command is passed through to `docker compose`.

Important environment:

- `COMPOSE_PROJECT_NAME=docker-proxy`
- `COMPOSE_DIR`, `ENV_FILE`, `LOCK_FILE`
- `PULL_BEFORE_UP`, `PULL_ON_REBUILD`, `RETRY_COUNT`, `RETRY_DELAY`, `WAIT_TIMEOUT`
- `RESTART_WITH_DEPS`, `CLEAN_UNHEALTHY`, `CLEAR_SCREEN`

The runner unsets sensitive/derived env values before invoking compose: `HT_PASS_ENCODED`, `ADGUARD_ADMIN_HASH`, `URI_SUB_PATH`, `URI_JSON_PATH`, `URI_CLASH_PATH`, `URI_VLESS_XHTTP`, and `URI_VLESS_GRPC`.

## Maintenance

`docker-maintenance.sh` supports `run`, `prune`, and `report`. It is conservative by design:

- Never deletes named Docker volumes.
- Never runs broad Docker-wide prune operations.
- Never deletes containerd content blobs by filesystem path.
- Uses a lock, runtime budget, timeouts, and pressure checks.
- Reclaims journal/apt/tmp, truncates large Docker JSON logs, prunes old images/build cache/containers/networks, runs containerd GC, and only enters orphan snapshot cleanup under very high pressure.

The installer `docker`/`compose` step syncs project files, chmods `compose.d/docker-maintenance.sh`, writes `docker-proxy-maintenance.service` and `docker-proxy-maintenance.timer`, then enables and starts the timer. The timer is daily with randomized delay.

Use `run-compose.sh maintenance report` for disk/containerd diagnostics and `run-compose.sh maintenance prune` for a narrower prune path.

## Reset Helper

`docker-reset.sh` is a destructive manual helper for Docker resource cleanup. It supports:

- Actions: `containers`, `images`, `volumes`, `cache`, `networks`, `all`, `everything`.
- Options: `--menu`, `--yes`, `--dry-run`, `--help`.

`all` keeps networks; `everything` includes user-defined networks. The script confirms unless `--yes` is supplied, restarts Docker/containerd for cleanup, then runs selected deletes.

## Doctor Inventory

`script/modules/08_doctor.sh` validates compose with:

```bash
COMPOSE_DIR=$INSTALL_ROOT/compose.d ENV_FILE=$INSTALL_ROOT/compose.d/.env LOCK_FILE=$INSTALL_STATE_DIR/docker-proxy-compose.doctor.lock run-compose.sh validate
```

Always-on container expectations:

- `adguard`
- `arcane`
- `caddy`
- `crowdsec`
- `crowdsec_firewall_bouncer`
- `homepage`
- `logrotate`
- `tor-proxy`
- `traefik`
- `traefik-acme-exporter`
- `usque`
- `3x-ui`

Optional doctor expectations:

- `lampac` only when enabled and `14-lampac.yml` exists.
- `telemt` only when enabled and `15-telemt.yml` exists.
- `mihomo` only when enabled and `16-mihomo.yml` exists.

Doctor still contains do-not-revive compatibility probes for `01-dockcheck.yml` and `07-dozzle.yml`; treat those as dormant, not current active inventory.

## Remnants: Do Not Revive

These are disabled or removed remnants and must not be reintroduced by skill guidance:

- `01-dockcheck.yml.disable` / `dockcheck`: do-not-revive.
- `01-watchtower.yml.disable` / `watchtower`: do-not-revive.
- `07-dozzle.yml.disable` / `dozzle`: do-not-revive; Arcane is the active manager UI.
- `warp`: do-not-revive as an active compose service; `usque` is the active WARP-like SOCKS backend.
- Legacy dual TOR (`torproxy` plus `tor-proxy`): do-not-revive. Current active service is only `tor-proxy`.
- `sub-json-processor`: do-not-revive. Subscriptions/JSON/Clash are routed through native `3x-ui`.
- removed `caddy/subs`: do-not-revive (subscription HTML tree deleted; no `/srv/subs` mount).

If a future change adds/removes a service, update this inventory and the router skill in the same change.
