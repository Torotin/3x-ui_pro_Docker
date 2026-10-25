---
name: 3x-ui-pro-docker
description: Routes work on the 3x-ui_pro_Docker repo to the correct project skill (installer, compose-stack, traefik, 3x-ui, lampac, and other stack services). Use when starting work in this repository or when unsure which service skill applies.
---

# 3x-ui_pro_Docker (router)

Entry skill: `3x-ui-pro-docker` — load this router first, then exactly one service skill below.

## Official documentation

- This repository README (project overview)
- Child skills listed in the Skill map below — load exactly one service skill after this router
- Custom image builds for `torotin/*`: https://github.com/Torotin/AutoDockerBuilder

## First steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Pick the service skill below; load only that skill's `SKILL.md` (+ its `references/` as needed).
3. Do not use the deleted personal global monolith skill for this project.

## Skill map

| When working on… | Use skill |
|---|---|
| `script/`, doctor/wizard/uninstall, host DNSCrypt | `installer` |
| `run-compose.sh`, `00-base.yml`, networks/IPs/volumes, `docker-maintenance.sh`, `docker-reset.sh` | `compose-stack` |
| Traefik static/dynamic, entrypoints, acme-exporter | `traefik` |
| `docker-proxy/3x-ui`, Xray desired state, panel API | `3x-ui` |
| Lampac files/sync/routing | `lampac` |
| CrowdSec LAPI/AppSec + firewall bouncer | `crowdsec` |
| AdGuard DNS/DoH | `adguard` |
| Arcane manager UI / path-prefix | `arcane` |
| Homepage dashboard | `homepage` |
| Mihomo compose/config/UI path | `mihomo` |
| Telemt stack + telemt-panel | `telemt` |
| usque / tor-proxy SOCKS backends | `proxy-backends` |
| logrotate | `logrotate` |
| Caddy catch-all / error backend | `caddy` |

## Doctor inventory hints

Always-on containers: `adguard`, `arcane`, `caddy`, `crowdsec`, `crowdsec_firewall_bouncer`, `homepage`, `logrotate`, `tor-proxy`, `traefik`, `traefik-acme-exporter`, `usque`, `3x-ui`.

Optional: `lampac`, `telemt`, `mihomo` (ENABLE_* + active compose file).

## Out of scope

`dockcheck`, `warp`, `dozzle`, `watchtower`, `sub-json-processor`, removed `caddy/subs` — remnants/disabled; do-not-revive.
