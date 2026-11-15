# Design: Xray-only admin access (Traefik `admin` + self-signed TLS)

Date: 2026-10-25  
Status: approved  
Branch: `feat/xray-admin-access` (from `ca445fb` / `dev`)  
Supersedes: Tailnet Admin Access (`feat/tailnet-admin-access` deleted as failed approach)

## Problem

Admin UIs share public `Host(${WEBDOMAIN})` with path prefixes. Apps that need root paths (Arcane `/api`, `/_app`; Homepage `/_next`; Traefik dashboard `/api`) force brittle Traefik priorities and race with Lampac/SelfSteal.

A prior Tailscale Serve + MagicDNS Services design solved Host-at-`/` isolation but proved operationally excessive (console Define/Approve/tag, Services DNS). Wildcard ACME for `*.${WEBDOMAIN}` is unavailable (free NS / provider subdomain constraints).

## Goals

- Remove listed admin panels from public Traefik `websecure` / `WEBDOMAIN`.
- Primary access: personal Xray proxy only (connected client required).
- Host-based private names: `*.${WEBDOMAIN}` subdomains **not** published in public DNS.
- TLS on the private plane via Traefik **self-signed** certificates (browser warnings acceptable; no internal CA install).
- Keep Basic Auth (`USER_WEB` / `PASS_WEB`) as a second factor.
- Eliminate public admin path-prefix races by **removing** those routers.
- Light break-glass: SSH + localhost / `docker exec` (no Tailscale).
- Live verify on `vps-vdsok-streambase-torotin` with destructive changes allowed.

## Non-goals

- Tailscale / Headscale / Serve / MagicDNS Services.
- Wildcard or public ACME for admin subdomains.
- Installing a private CA on operator devices.
- Single path-prefix portal hostname for all admins.
- Publishing admin hostnames in public DNS for `WEBDOMAIN`.
- Automatic fallback that re-exposes admins on public `WEBDOMAIN` if Xray fails.
- Moving Mihomo/Telemt panels unless later added explicitly.
- Changing public L4 `:443` / SelfSteal beyond removing admin HTTP routers from `websecure`.
- Breaking the current Xray subscription.

## Hard invariants

1. **Subscription continuity:** Do not change `URI_SUB_PATH` / `URI_JSON_PATH` / `URI_CLASH_PATH` / `WEBDOMAIN` subscription URLs, or VLESS xhttp/grpc public paths, without an approved client migration. Move **only** panel UIs off public; leave `3xui-sub`, `xhttp3xui`, `grpc3xui` on `websecure`.
2. **No public admin routers:** Traefik dashboard, Arcane (+ root exceptions), Homepage (+ `/_next` / NextAuth path routers), AdGuard **UI**, 3x-ui **panel**, Lampac `/admin` `/adminpanel` `/stats` `/weblog` must not be served on public `websecure`.
3. **Admin bind:** Traefik entrypoint `admin` only on `127.0.0.1` and/or docker-internal non-public bind. Never publish the admin plane on `0.0.0.0` public interfaces.
4. **No public DNS for admin names:** AdGuard (or equivalent tunnel DNS) may rewrite admin FQDNs; public NS must not publish them.
5. **Server freedom:** On `vps-vdsok-streambase-torotin`, destructive stack changes are allowed; subscription must remain valid (smoke sub URL before/after each risky step).

## Chosen approach

**Approach 1:** Traefik private entrypoint `admin` + Host routers on `*.${WEBDOMAIN}` + self-signed TLS + Xray domain routing + AdGuard rewrite. No Tailscale.

Rejected: path-prefix portal (race/rewrite); direct per-container localhost publishes (duplicates Traefik auth/TLS); Tailscale Services (ops overhead).

## Architecture

```text
[Device + Xray proxy]
   DNS: AdGuard rewrite  <svc>.${WEBDOMAIN} → admin-plane address
   HTTPS (self-signed; warning OK)
        ▼
[Xray]  domain route → Traefik entrypoint `admin` (non-public)
        ▼
[Traefik `admin` + TLS self-signed]
  Host(arcane.${WEBDOMAIN})       → Arcane @ /
  Host(homepage.${WEBDOMAIN})     → Homepage @ /
  Host(adguard.${WEBDOMAIN})      → AdGuard UI @ /
  Host(3x-ui.${WEBDOMAIN})        → 3x-ui panel @ /
  Host(traefik.${WEBDOMAIN})      → Traefik dashboard @ /
  Host(lampac-admin.${WEBDOMAIN}) → /admin|/adminpanel|/stats|/weblog
  + Basic Auth + rate-limit + security headers

[Internet without Xray]
        ▼
[Public websecure / SelfSteal]
  — no admin routers
  — SelfSteal/Caddy, Lampac front, 3x-ui sub/xhttp/grpc, AdGuard DoH, …

[Break-glass]
  SSH → docker exec / curl -k https://127.0.0.1:<admin-port> -H 'Host: …'
```

## Hostname map

| Service | Hostname | Public `websecure` |
|---|---|---|
| Arcane | `arcane.${WEBDOMAIN}` @ `/` | Remove UI + root `/api` `/_app` helpers |
| Homepage | `homepage.${WEBDOMAIN}` @ `/` | Remove UI + `/_next` + auth path routers |
| AdGuard UI | `adguard.${WEBDOMAIN}` @ `/` | Remove panel; **keep DoH** |
| 3x-ui panel | `3x-ui.${WEBDOMAIN}` @ `/` | Remove panel; **keep sub/xhttp/grpc** |
| Traefik dashboard | `traefik.${WEBDOMAIN}` @ `/` | Remove dashboard / root `/api` |
| Lampac admin | `lampac-admin.${WEBDOMAIN}` | Remove admin/stats/weblog; **keep front** |

## Components

### Add / change

- Traefik static entrypoint `admin` (non-public bind; port via env, e.g. `9443`).
- TLS on `admin`: Traefik default/self-signed (no `certresolver=le`).
- Host routers for the six admin FQDNs only on entrypoint `admin`.
- Xray desired-state: those FQDNs → local `admin` outbound (not WARP/TOR/public freedom).
- AdGuard rewrites for the six names → admin-plane target used by Xray clients.
- App base URLs (`APP_URL`, Homepage base, 3x-ui panel base) → private host roots.

### Remove from public `websecure`

- Traefik dashboard routers (including root `/api` for dashboard).
- Arcane UI + public root exceptions tied to `WEBDOMAIN`.
- Homepage prefixed UI + `/_next` + narrow auth routers on public Host.
- AdGuard panel UI (keep DoH).
- 3x-ui **panel** only (keep subscription and VLESS path routers).
- Lampac sensitive admin/stats/weblog routers.

### Remove entirely (failed prior approach)

- Compose `tailscale`, Serve scripts, `TS_AUTHKEY` / `TS_TAILNET_NAME` installer prompts, MagicDNS Services wiring.
- Live: stop/remove Tailscale container and related env on the test server.

### Leave on public

- SelfSteal / Caddy fallback, Lampac front transport, 3x-ui sub/json/clash + xhttp/grpc, AdGuard DoH.

## Failure modes

- Xray/3x-ui down → proxy admin path dead; use SSH break-glass.
- Traefik down → admin and public face affected (status quo).
- AdGuard rewrite broken → admin names fail for proxy clients; fix via SSH.
- No automatic re-publish of admins onto public `WEBDOMAIN`.

## Verification

### Local

- `run-compose.sh validate` / compose config OK.
- Assert: listed admin routers are **not** on `entrypoints=websecure` (except documented public exceptions).
- Assert: entrypoint `admin` exists; admin Host routers only there; TLS without LE resolver.
- Assert: Xray desired-state routes admin FQDNs to local `admin`.
- Assert: no Tailscale service/compose fragment remains in the active stack.

### Live (`vps-vdsok-streambase-torotin`)

Destructive changes allowed. Subscription smoke before/after each risky step.

1. Without Xray: admin URLs on public face do not serve panels.
2. With Xray: each `https://<svc>.${WEBDOMAIN}` → Basic Auth → UI (self-signed warning OK).
3. Subscription, DoH, Lampac `/`, VLESS — no regression.
4. Tailscale removed from the live stack.

### Done when

- Admins unreachable on public `WEBDOMAIN`.
- Reachable via personal Xray on the `admin` plane with self-signed TLS.
- Public path-prefix admin race eliminated.
- Basic Auth kept; subscription still works; Tailscale gone.
- Planning and implementation land on `feat/xray-admin-access`.

## Open implementation choices (resolve in plan)

- Exact `admin` listen address/port and whether TLS is terminated only on that entrypoint.
- AdGuard rewrite target (docker DNS name vs fixed IP vs loopback-via-Xray sniff).
- Whether CrowdSec bouncer attaches to `admin` chains in v1 (default: omit or reuse existing chain pattern).
- Order of live cleanup: remove Tailscale first vs cutover routers first (prefer: preserve subscription smoke between steps).
