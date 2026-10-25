# Lampac Reverse Proxy

## Source of Truth

Project file: `docker-proxy/compose.d/14-lampac.yml`.

External product docs: `https://docs.lampac.dev/deployment/reverse-proxy`.

Lampac listens on `9118` in the container. Traefik routes the public `${WEBDOMAIN}` host to the `lampac` service and injects HTTPS scheme headers so Lampac-generated URLs match the external URL.

## Required Transport Classes

| Class | Paths | Requirement |
|---|---|---|
| WebSocket / SSE | `/nws`, legacy `/ws` | Preserve upgrade behavior and long idle/read tolerance; do not attach response hardening headers that break RCH clients. |
| Streaming proxy | `/proxy`, `/proxy-dash`, `/proxyimg` | Preserve streaming semantics; avoid buffering changes when adding routers or middlewares. |
| Catch-all | `/` | Normal HTTP routing with `lampac-headers`. |

## Current Traefik Priority Map

Keep these priorities aligned with live labels in `14-lampac.yml`:

| Priority | Router | Rule / purpose |
|---:|---|---|
| 910 | `lampac-api-override` | `PathPrefix(/api/v1.0)` or `PathPrefix(/api/v2.0)`; must beat Traefik dashboard `/api` and Arcane `/api`. |
| 95 | `lampac-auth-pages` | `/adminpanel/auth` and `/weblog/auth`; bypasses BasicAuth so Lampac auth pages can load. |
| 90 | `lampac-sensitive` | `/admin`, `/adminpanel`, `/stats`, `/weblog`, `/database-editor`; uses `lampac-admin-chain`. |
| 70 | `lampac-nws` | `^/(nws|ws)`; uses only scheme-forwarding request headers. |
| 35 | `lampac-cub-plugins` | `^/cub/[^/]+/plugin`; forces `Content-Type: text/javascript`. |
| 10 | `lampac-https` | Host catch-all for `${WEBDOMAIN}`. |
| 1 | `lampac-unknown-host` | Unknown host fallback rewritten to `/`. |

## Middleware Contract

`lampac-headers` sets:

- request headers: `xscheme=https`, `X-Forwarded-Proto=https`
- response/security headers: HSTS, XSS filter, `contentTypeNosniff`

`lampac-nws-headers` intentionally sets only:

- `xscheme=https`
- `X-Forwarded-Proto=https`

Do not add `contentTypeNosniff` or browser XSS response headers to the `/nws` / `/ws` router unless the RCH client behavior has been revalidated.

`lampac-admin-chain` must keep:

- `bouncer@file`
- BasicAuth with `${HT_PASS_ENCODED}`
- rate limit
- `X-Robots-Tag=noindex, nofollow`
- `lampac-headers`

## KnownProxies

`docker-proxy/lampac/config/init.conf` must trust the Docker networks that forward requests:

```json
"KnownProxies": [
  { "ip": "172.18.0.0", "prefixLength": 24 },
  { "ip": "172.19.0.0", "prefixLength": 24 },
  { "ip": "fd00:dead:beef:12::", "prefixLength": 64 },
  { "ip": "fd00:dead:beef:13::", "prefixLength": 64 }
]
```

If the Traefik or DNS network ranges change, update `KnownProxies` in the same change. Without trusted proxies, Lampac may ignore forwarded scheme/client headers and generate HTTP URLs on HTTPS pages.

## Optional Service Gate

Lampac is optional. `docker-proxy/compose.d/run-compose.sh` skips `14-lampac.yml` unless `ENABLE_LAMPAC` is truthy. Installer env and doctor expectations follow the same gate.
