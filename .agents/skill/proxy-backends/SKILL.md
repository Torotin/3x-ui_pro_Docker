---
name: proxy-backends
description: Use when editing or operating proxy backend services in 3x-ui_pro_Docker, including 09-usque.yml, the tor-proxy service in 11-tor-proxy.yml, WARP-like SOCKS egress, TOR SOCKS/DNS/HTTP backends, health, or restarts.
---

# Proxy Backends

Use this skill for active SOCKS/proxy backend containers used by 3x-ui managed Xray desired state.

## Official documentation

### usque (`torotin/usque`)

- Upstream: https://github.com/Diniboy1123/usque
- Image contract: https://github.com/Torotin/AutoDockerBuilder/blob/main/bin/usque/README.md

### tor-proxy (`torotin/tor-proxy`)

- Image contract (architecture, env matrix, feeds): https://github.com/Torotin/AutoDockerBuilder/blob/main/bin/tor-proxy/README.md
- Components: https://www.torproject.org/ | https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird | https://github.com/go-gost/gost | https://github.com/AdguardTeam/dnsproxy

Do not document a separate active `warp` container. Do not use legacy `torproxy` naming.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/09-usque.yml`
   - `docker-proxy/compose.d/11-tor-proxy.yml` for the `tor-proxy` service only

## Ownership

Own:
- `docker-proxy/compose.d/09-usque.yml`
- `docker-proxy/compose.d/11-tor-proxy.yml` service `tor-proxy`
- `usque` WARP-like SOCKS availability and health semantics
- `tor-proxy` SOCKS, DNS, HTTP, bridge bootstrap, and volume expectations

Coordinate with `3x-ui` for managed Xray outbound/balancer tags and with `compose-stack` for service inventory and network pins.

## Core Rules

- `usque` is the active WARP-like SOCKS backend. Its healthcheck must confirm `warp=on` through `127.0.0.1:${USQUE_PORT_INTERNAL:-1080}`.
- `tor-proxy` is the active TOR backend. Keep the current service name and tag spelling: `tor-proxy`.
- Keep `usque` on `172.18.0.9`.
- Keep `tor-proxy` on `172.18.0.11` and `172.19.0.11`, with persistent `tor-proxy-data` and `tor-proxy-state` volumes.
- Host ports for proxy backends stay commented unless host-local access is intentionally required. Other containers should use service names and internal ports.
- Do not document or restore a separate `warp` container as active. It is do-not-revive.
- Do not document or restore legacy `torproxy` naming or endpoint probes. Use `tor-proxy` only unless live code changes first.

## Live Stack Contract

| Backend | Reachability | Role |
|---|---|---|
| `usque` | internal SOCKS (compose IP pin `172.18.0.9`) | WARP-like MASQUE SOCKS for managed Xray |
| `tor-proxy` | `tor-proxy:53` DNS, `:1080` SOCKS5, `:8080` HTTP (host `ports` usually commented) | Tor egress; IPs `172.18.0.11` / `172.19.0.11` |

### tor-proxy architecture (image)

```text
client -> :1080 SOCKS5 / :8080 HTTP  (gost)
              -> 127.0.0.1:9050      (tor SocksPort)
client -> :53 DNS                    (dnsmasq -> tor DNSPort)
startup -> dnsproxy                  (encrypted bootstrap DNS)
bridges -> lyrebird                  (obfs4 / webtunnel / snowflake)
```

Full env matrix lives in the AutoDockerBuilder tor-proxy README. This stack may override defaults; prefer live compose values. Current `11-tor-proxy.yml` deltas from ADB defaults include:

- `TOR_BRIDGES_MAX_PER_TRANSPORT=10` instead of ADB's small-VPS/default `2`.
- `TOR_IPV6_AVAILABLE=${TOR_IPV6_AVAILABLE:-false}` instead of ADB default `auto`.
- Bootstrap DNS upstreams are AdGuard DoH, Quad9 DoH, and AdGuard DoQ; ADB documents AdGuard-family defaults.
- Bridge feed URLs are pinned explicitly in compose, including third-party Tor-Bridges-Collector feeds.

### Product routing (upstream)

- usque: MASQUE/WARP client exposing SOCKS; health idea `warp=on` via SOCKS.
- tor-proxy: bridges/feeds/bootstrap DNS per ADB README; public bridge collector feeds are untrusted third-party sources.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart usque tor-proxy
docker-proxy/compose.d/run-compose.sh logs usque
docker-proxy/compose.d/run-compose.sh logs tor-proxy
```

`tor-proxy` health is delegated to `/usr/local/bin/tor-proxy-healthcheck`; avoid replacing it with ad hoc external curl checks unless debugging a specific failure.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
bash tests/3x-ui-scripts/run.sh
git diff --check
```
