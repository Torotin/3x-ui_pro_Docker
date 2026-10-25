# 3x-ui Runtime

## Source Of Truth

Code wins over this reference for **this stack**. For product behavior (panel settings, subscription formats, API shapes), prefer [official 3x-ui docs](https://docs.sanaei.dev/docs/) and verify against the deployed panel version.

Verify live files before changing stack behavior:

- Compose: `docker-proxy/compose.d/12-3x-ui.yml`
- Env: `docker-proxy/3x-ui/3x-ui.env`
- Before-start: `docker-proxy/3x-ui/scripts/00_BeforeStart/download-db.sh`, `docker-proxy/3x-ui/scripts/00_BeforeStart/xray_update.sh`
- After-start: `docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`
- Libraries: `docker-proxy/3x-ui/scripts/lib/*.bash`
- Tests: `tests/3x-ui-scripts/run.sh`

Useful upstream pages: [Panel settings](https://docs.sanaei.dev/docs/config/panel), [Subscription](https://docs.sanaei.dev/docs/config/subscription), [Env vars](https://docs.sanaei.dev/docs/reference/env-vars), [Reverse proxy](https://docs.sanaei.dev/docs/operations/reverse-proxy) (Nginx/Caddy samples — this repo uses Traefik).

## Compose And Routing Contract

`12-3x-ui.yml` is the service contract for the live stack.

- The service joins `traefik-proxy` and `dns-net`; DNS is pinned to AdGuard at `172.19.0.10`.
- It depends on `usque`, `adguard`, `tor-proxy`, and `traefik-acme-exporter` health.
- It publishes TCP `443:${PORT_LOCAL_VISION:-443}` and UDP `443:${PORT_LOCAL_HYSTERIA:-443}` directly for Xray-managed proxy traffic.
- Traefik labels expose HTTP routers on `websecure` for panel, API, native subscription paths, XHTTP, and optional gRPC.
- There is no Traefik L4 TCP router for REALITY passthrough in the live compose. Do not invent one in docs, skills, or implementation.
- Keep panel `webBasePath` (`/${URI_PANEL_PATH}/`) behind Traefik. Official reverse-proxy tips (WebSocket upgrade, proxy subscription too) still apply; TLS is at Traefik, so consider `XUI_SKIP_HSTS=true` only if the panel would otherwise emit conflicting HSTS ([env vars](https://docs.sanaei.dev/docs/reference/env-vars)).

Current HTTP routes:

- Panel health: `/${URI_PANEL_PATH}/health` -> `3xui-panel-svc`
- Panel UI/session routes: `PathPrefix(/${URI_PANEL_PATH})` -> `3xui-panel-svc`, BasicAuth protected
- API: `PathPrefix(/${URI_PANEL_PATH}/panel/api)` -> `3xui-panel-svc`, no BasicAuth chain
- Native subscriptions: `${URI_SUB_PATH}`, `${URI_JSON_PATH}`, `${URI_CLASH_PATH:-/clash/}` -> `3xui-sub-svc`
- XHTTP: `${URI_VLESS_XHTTP}` -> `xhttp3xui-svc`
- gRPC: `${URI_VLESS_GRPC}` -> `grpc3xui-svc` with upstream TLS transport

Do not add a root `/assets/` router. The panel assets are under `/${URI_PANEL_PATH}/assets/...`; a root assets router steals the decoy site's assets and returns 404.

## Runtime Shape

The after-start runtime is bash-based and supports `MODE=check|plan|apply`.

`docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh` pipeline:

1. Load libraries and runtime env.
2. Require/normalize mode and check dependencies.
3. Resolve panel base URL and login. The panel can move after settings are applied, so login happens again later.
4. Detect country flag and build desired state.
5. Apply managed Xray state, then restart Xray if needed before `panelOutbound` can reference managed tags.
6. Ensure panel settings and admin credentials.
7. Resolve/login again after panel settings changes.
8. Repair inbound client `tgId` values in DB.
9. Ensure TLS files, managed inbounds, shared clients, optional gRPC client, optional Hysteria2 client.
10. Repair shared client after inbound sync (also force per-inbound VLESS `flow` in SQLite: Vision=`xtls-rprx-vision`, XHTTP/gRPC empty). Panel `updateClient(flow="")` wipes Vision inbound flow, and `updateInbound` cannot restore it while `clients.flow` is empty.
11. Update geofiles if enabled.
12. Restart panel if required.

Shared first-class `clients.flow` must be `xtls-rprx-vision` (same as `visionFlow`). Leaving it empty breaks TCP Reality after the next shared-client update.

Do not add runtime package installation such as `apk add` to after-start scripts. Missing dependencies should be reported by checks/tests.

## Runtime Libraries

- `log.bash`: logging and fatal errors.
- `env.bash`: environment defaults and runtime normalization.
- `http.bash`: curl/cookie/body handling.
- `3xui_api.bash`: panel API paths, auth, CSRF, route fallback, long mutation helpers.
- `desired_state.bash`: desired panel/inbound/client/geodata state builders.
- `json_state.bash`: JSON transforms for managed Xray state.
- `runtime_common.bash`: shared mode/dependency helpers.
- `panel_runtime.bash`: panel settings, admin, geofile, and DB repair behavior.
- `inbound_runtime.bash`: inbound and client reconciliation.
- `xray_runtime.bash`: managed Xray DNS/routing/outbound state and restart checks.
- `download.bash`: atomic downloads with optional SHA-256 verification.

## Before-Start Scripts

`xray_update.sh` downloads the requested Xray release for the container architecture, verifies the downloaded binary reports a version, backs up the current binary, and atomically installs the new one under `XUI_BIN_FOLDER`.

`download-db.sh` defaults `DOWNLOAD_GEO_DIRECT=true` so custom geodata (`geosite_refilter.dat`, zkeen, v2fly, adlist, …) is present in `/app/bin` before Xray starts. The image build (`AutoDockerBuilder/bin/3x-ui/DockerInit.sh`) bakes the same set in; BeforeStart refreshes them on each container start. Set `DOWNLOAD_GEO_DIRECT=false` only if you intentionally rely on panel/Xray geodata sync alone (that path can fail if assets are missing at first boot).

## Managed Xray Desired State

Before editing generated Xray config logic, read the local stack constraints below and the official Xray documentation at https://xtls.github.io/.

Current local stack constraints:

- VLESS Vision inbound must keep `settings.decryption = "none"`; Xray rejects Vision without it.
- Vision REALITY is direct TCP on the container's local Vision port, published by compose. It is not Traefik L4 passthrough.
- XHTTP is behind Traefik TLS termination; backend stream settings keep `security = "none"`.
- XHTTP external proxy metadata points at the public domain on port 443, where Traefik terminates TLS.
- gRPC, when enabled, uses TLS between Traefik and Xray; Traefik uses `grpc3xui-transport@file`.
- Hysteria2, when enabled, uses UDP 443 direct publish with TLS/H3 masquerade settings.
- Generated managed outbounds are applied before `panelOutbound` so tags like `usque` exist before the panel tries to use them.

Peer expectations:

- DNS peer: prefer `adguard:53` when reachable; otherwise use the fallback resolver list in `xray_runtime.bash`.
- WARP-like SOCKS peer: `usque:${USQUE_PORT}` is included only after it confirms `warp=on`.
- TOR SOCKS peer: `tor-proxy:${TOR_PROXY_PORT}` is included only after it confirms `IsTor=true`.
- Optional Mihomo SOCKS peer is included only when `ENABLE_MIHOMO=true` and the endpoint is reachable.

WARP console behavior:

- `XRAY_MANAGED_WARP_CONSOLE` currently defaults to `false`.
- If console WARP is re-enabled, preserve the GUI-compatible endpoint host `engage.cloudflareclient.com:2408` instead of replacing it with a resolved IP.
- Do not revive old `warp_socks_v5` references.

## Native Subscriptions

Upstream: the subscription server is a **separate** HTTP(S) listener from the panel web UI ([subscription docs](https://docs.sanaei.dev/docs/config/subscription)). Fresh upstream installs may randomize path prefixes; this project pins paths via env.

The project uses native 3x-ui subscription routes. These remnants are **do-not-revive**:

- `docker-proxy/3x-ui/sub-json-processor` — do-not-revive
- `tests/sub-json-processor` — do-not-revive

Native subscription settings live in `docker-proxy/3x-ui/3x-ui.env` (aligned with panel subscription settings):

- `subEnable=true`
- `subPort=${PORT_LOCAL_VLESS_SUBSCRIBE}` (compose/Traefik target; upstream default is often `2096`)
- `subJsonEnable=true`
- `subPath=${URI_SUB_PATH}` — raw/base64 links (and HTML info page when `Accept: text/html` or `?html=1`)
- `subJsonPath=${URI_JSON_PATH}` — Xray-json client config(s)
- `subClashEnable=true`
- `subClashPath=${URI_CLASH_PATH:-/clash/}` — Clash/Mihomo YAML
- `subEncrypt=true` — base64-encode raw subscription body
- `subURI`, `subJsonURI`, and `subClashURI` point at `https://${WEBDOMAIN}` paths (Traefik public URLs; omit `:subPort` behind reverse proxy)

Upstream also exposes Clash aliases when Clash is enabled: `/mihomo/{subId}` (preferred for Mihomo clients) and `/clash-legacy/{subId}` (legacy Clash for Windows only). This stack's Traefik labels currently forward the configured `subPath` / `subJsonPath` / `subClashPath` prefixes — do not assume the aliases are routed unless compose adds them.

Per-inbound **Hosts** (Settings → Hosts / `/panel/api/hosts`) supersede legacy `externalProxy` for extra subscription endpoints. Subscription node ordering can follow inbound order or hosts-first (`subHostSortMode`).

Subscription response headers clients may read: `Subscription-Userinfo`, `Profile-Update-Interval`, optional `Profile-Title` / `Profile-Web-Page-Url` / `Announce`.

Subscription IDs and URLs are credentials. Do not commit real subscription IDs, client IDs, credentials, or generated private keys.

## Server DB Reset Flow

Use this only for an intentional panel DB reset on the server:

```bash
/opt/docker-proxy/compose.d/run-compose.sh down 3x-ui
cp /opt/docker-proxy/3x-ui/clear/x-ui.db /opt/docker-proxy/3x-ui/configs/x-ui.db
/opt/docker-proxy/compose.d/run-compose.sh restart 3x-ui
```

After reset, the after-start runtime reapplies panel settings, managed inbounds, shared clients, geodata, and managed Xray state according to env.

## Validation

Primary local validation:

```bash
bash tests/3x-ui-scripts/run.sh
```

The test runner executes download/runtime fixture tests, CRLF checks, `bash -n`, `shellcheck -x -S warning`, and `shfmt -d` when `shfmt` is installed.

For Xray generated config changes, validate the deployed generated config when available:

```bash
/app/bin/xray-linux-amd64 run -test -c /app/bin/config.json
```

General hygiene:

```bash
git diff --check
```
