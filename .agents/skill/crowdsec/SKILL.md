---
name: crowdsec
description: Use when editing or operating CrowdSec in 3x-ui_pro_Docker, including 03-crowdsec.yml, 04-crowdsec-firewall-bouncer.yml, docker-proxy/crowdsec files, Traefik bouncer middleware, LAPI/AppSec, or firewall-bouncer health and restarts.
---

# CrowdSec

Use this skill for the active CrowdSec security services: LAPI/AppSec, Traefik bouncer middleware, and the host-network firewall bouncer.

## Official documentation

- CrowdSec docs: https://docs.crowdsec.net/
- Traefik bouncer / AppSec: docs.crowdsec.net bouncer guides + live `docker-proxy/traefik/dynamic/crowdsec.yml` (`bouncer@file`)
- Firewall bouncer: https://docs.crowdsec.net/u/bouncers/firewall/
- Community Docker image used here: https://github.com/shgew/cs-firewall-bouncer-docker

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```
3. Treat these live files as source of truth:
   - `docker-proxy/compose.d/03-crowdsec.yml`
   - `docker-proxy/compose.d/04-crowdsec-firewall-bouncer.yml`
   - `docker-proxy/crowdsec/**`
   - `docker-proxy/traefik/dynamic/crowdsec.yml`

## Ownership

Own:
- `docker-proxy/compose.d/03-crowdsec.yml`
- `docker-proxy/compose.d/04-crowdsec-firewall-bouncer.yml`
- `docker-proxy/crowdsec/**`
- `docker-proxy/traefik/dynamic/crowdsec.yml`
- CrowdSec environment keys and bouncer wiring in service-specific Traefik chains

Coordinate with `traefik` for shared file-provider behavior and with `compose-stack` for startup ordering.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure` unless noted. CrowdSec has no public UI route in live compose.

| Service skill | Path / rule (from compose) | Notes |
|---|---|---|
| `crowdsec` | no public UI route | `bouncer@file`, AppSec/LAPI internals, and firewall bouncer. |

### Product routing (upstream)

- Acquisitions read Traefik logs, Caddy logs, SSH auth logs, and the AppSec listener.
- LAPI listens on `crowdsec:8080` for Docker peers and `127.0.0.1:8080` on the host.
- AppSec listens on `crowdsec:7422`; Traefik and Caddy bouncers send requests there.
- The Traefik bouncer is a file-provider middleware named `bouncer@file`, not a Docker-label duplicate.
- Caddy uses the Caddy CrowdSec module with `api_url`, `appsec_url`, and `CROWDSEC_API_KEY_CADDY`.
- Firewall decisions are enforced by `crowdsec-firewall-bouncer` in host network mode with `NET_ADMIN` and `NET_RAW`.
- Use the matching `CROWDSEC_API_KEY_TRAEFIK`, `CROWDSEC_API_KEY_CADDY`, and `CROWDSEC_API_KEY_FIREWALL` for each bouncer.
- Do not expose LAPI/AppSec publicly; loopback host ports are for local operations only.

## Core Rules

- Keep `crowdsec` on both Docker networks at `172.18.0.3` and `172.19.0.3`.
- Keep LAPI/AppSec host ports loopback-only: `127.0.0.1:8080:8080` and `127.0.0.1:7422:7422`.
- Keep `crowdsec-firewall-bouncer` in host network mode with `NET_ADMIN` and `NET_RAW`.
- The firewall bouncer depends on healthy `crowdsec`; Traefik depends on both `crowdsec` and `crowdsec-firewall-bouncer`.
- `bouncer@file` is defined in `docker-proxy/traefik/dynamic/crowdsec.yml`; do not duplicate it as Docker labels.
- Use `CROWDSEC_API_KEY_TRAEFIK`, `CROWDSEC_API_KEY_CADDY`, and `CROWDSEC_API_KEY_FIREWALL` consistently with the matching bouncer.

## Health and Restart

```bash
docker-proxy/compose.d/run-compose.sh restart crowdsec
docker-proxy/compose.d/run-compose.sh restart crowdsec-firewall-bouncer
docker-proxy/compose.d/run-compose.sh restart traefik
docker-proxy/compose.d/run-compose.sh logs crowdsec
docker-proxy/compose.d/run-compose.sh logs crowdsec_firewall_bouncer
```

`crowdsec` health probes `http://localhost:8080/health`; the firewall bouncer healthcheck confirms the bouncer process is running.

## Traefik Notes

- Service chains should reference `bouncer@file` before app BasicAuth/rate-limit middleware.
- AppSec uses `crowdsec:7422`; LAPI uses `crowdsec:8080`.
- `forwardedHeadersTrustedIPs` and `clientTrustedIPs` must include the project Docker networks.
- After changing `docker-proxy/traefik/dynamic/crowdsec.yml`, restart `traefik`; restart `traefik-acme-exporter` only for certificate/exporter changes.

## Pitfalls

- Do not publish CrowdSec LAPI/AppSec to the public interface.
- Do not remove `crowdsec-firewall-bouncer` from Traefik's health-gated startup chain.
- Do not revive `docker-proxy/traefik/dynamic_old/crowdsec.yml`; it is a remnant only and do-not-revive as active config.
- Do not rotate bouncer API keys in only one place; update compose env, dynamic config references, and live secrets together.

## Validation

```bash
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart crowdsec crowdsec-firewall-bouncer
docker-proxy/compose.d/run-compose.sh restart traefik
git diff --check
```
