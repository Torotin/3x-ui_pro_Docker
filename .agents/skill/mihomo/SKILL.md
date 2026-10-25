---
name: mihomo
description: Use when editing or operating the optional Mihomo service in 3x-ui_pro_Docker, including docker-proxy/compose.d/16-mihomo.yml, docker-proxy/mihomo/config.yaml, proxy providers, Traefik UI path routing, URI_MIHOMO, MIHOMO_SECRET, ENABLE_MIHOMO, or the installer Mihomo config template.
---

# Mihomo

Use this skill for the optional Mihomo service in this repository: compose service wiring, runtime config under `docker-proxy/mihomo/`, installer-rendered config shape, dashboard/controller exposure, proxy providers, rule providers, DNS, and UI path-prefix behavior.

## Official documentation

- Mihomo / MetaCubeX: https://github.com/MetaCubeX/mihomo (and project wiki linked from that repo)
- Stack UI: `/${URI_MIHOMO}` (+ `/ui`) on `websecure` per `16-mihomo.yml`. Optional service.

## First Steps

1. Read [../_shared/project-conventions.md](../_shared/project-conventions.md).
2. Read [references/stack-notes.md](references/stack-notes.md) before editing `16-mihomo.yml`, `docker-proxy/mihomo/**`, or `script/template/mihomo.config.yaml.template`.
3. Inspect the dirty worktree before edits:
   ```bash
   git status --short
   ```

## Ownership

Own:
- `docker-proxy/compose.d/16-mihomo.yml`
- `docker-proxy/mihomo/**`
- Mihomo runtime expectations in installer summaries, doctor inventory, homepage links, and compose inventory

Coordinate with `installer` for `script/template/mihomo.config.yaml.template` rendering and with `traefik` for shared edge-proxy middleware behavior. Mihomo is optional: `run-compose.sh` includes `16-mihomo.yml` only when `ENABLE_MIHOMO` is truthy.

## Live Stack Contract

Public HTTPS Host is `${WEBDOMAIN}` on entrypoint `websecure`; Traefik forwards to controller/UI port `9090`.

| Route / router | Rule | Priority | Middleware / notes |
|---|---|---:|---|
| `mihomo-ui-manifest` | `PathRegexp('/${URI_MIHOMO}/ui/.*manifest(.webmanifest|.json)$')` | 974 | Manifest paths, strip prefix, no BasicAuth. |
| `mihomo-ui-slash` | `Path('/${URI_MIHOMO}/ui')` | 973 | BasicAuth then redirect to trailing-slash `/ui/`. |
| `mihomo-ui-static` | `PathPrefix('/${URI_MIHOMO}/ui')` | 972 | Main static dashboard, BasicAuth, strip prefix, compression. |
| `mihomo-ui-root` | `Path('/${URI_MIHOMO}')` or `Path('/${URI_MIHOMO}/')` | 971 | BasicAuth then redirect to Zashboard setup URL with `secondaryPath=/${URI_MIHOMO}`. |
| `mihomo-ui` | `PathPrefix('/${URI_MIHOMO}')` | 970 | Catch-all path-prefix route, strip prefix, no BasicAuth in this chain. |

## Product Routing

- Runtime config is `docker-proxy/mihomo/config.yaml`; installer seed is `script/template/mihomo.config.yaml.template`.
- Public UI is `https://${WEBDOMAIN}/${URI_MIHOMO}/ui/`; the router strips `/${URI_MIHOMO}` before forwarding because Mihomo serves `/ui/` internally.
- `${MIHOMO_SECRET}` protects the controller API and is rendered by the installer; never print live secrets or provider credentials.
- Proxies are grouped through providers, selectors, and health checks; local provider starts at `docker-proxy/mihomo/proxy-providers/local/proxies.yaml`.
- Rules and rule-providers steer traffic into service groups before final `MATCH,DIRECT`.
- DNS uses fake-IP concepts in the runtime baseline (`0.0.0.0:1053`, `respect-rules`, IPv6); treat listener exposure as security-sensitive before publishing ports or widening networks.
- `allow-lan`, `bind-address`, `mixed-port`, and `external-controller` are intentionally broad inside the container and depend on Traefik/auth boundaries for public access.

## Core Rules

- Keep the service optional. Fresh installs default `ENABLE_MIHOMO=false`; the wizard or env can enable it.
- Treat `docker-proxy/mihomo/config.yaml` as the live runtime baseline and `script/template/mihomo.config.yaml.template` as the installer-rendered seed for `/opt/docker-proxy/mihomo/config.yaml`.
- Preserve the Traefik path-prefix contract: public UI is under `https://${WEBDOMAIN}/${URI_MIHOMO}/ui/`, with `${URI_MIHOMO}` stripped before forwarding to the internal controller on port `9090`.
- Keep `${MIHOMO_SECRET}` rendered into the config by the installer; never print the live secret or subscription/provider credentials in responses.
- BasicAuth applies only on selected Traefik chains that include `mihomo-basic-auth` (static UI under `/${URI_MIHOMO}/ui`, the `/ui` slash redirect, and root redirects)—not on every Mihomo route (manifest and catch-all chains omit it). Do not weaken bouncer, rate limit, security headers, strip-prefix, or compression on those paths.
- Treat `allow-lan: true`, `bind-address: "*"`, `external-controller: 0.0.0.0:9090`, DNS listener `0.0.0.0:1053`, and unauthenticated mixed proxy `7890` as deliberate but high-risk surfaces; document security impact before changing them.
- Do not chase Xray REALITY compatibility fixes in Mihomo configs unless new runtime evidence proves the stack supports them. Prefer non-Reality nodes such as XHTTP or Hysteria2 for this deployment.

## Common Commands

```bash
docker-proxy/compose.d/run-compose.sh list-files
docker-proxy/compose.d/run-compose.sh validate
docker-proxy/compose.d/run-compose.sh restart mihomo
docker-proxy/compose.d/run-compose.sh logs mihomo
```

## Validation

Prefer static/local checks before live operations:

```bash
docker-proxy/compose.d/run-compose.sh validate
git diff --check
```

If a `mihomo` binary is available, validate the deployed config shape with the same config directory used by the container:

```bash
mihomo -t -d docker-proxy/mihomo -f docker-proxy/mihomo/config.yaml
```

If the binary is unavailable, report `NOT_RUN: mihomo binary unavailable` and still run repo-level static checks.
