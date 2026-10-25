# 3x-ui Panel API

## Scope

Use this reference when changing `docker-proxy/3x-ui/scripts/lib/3xui_api.bash`, API-driven runtime behavior, inbounds, first-class clients, hosts, nodes, server operations, settings, Xray template updates, native subscriptions, or backup/DB flows.

Upstream OpenAPI-derived docs (source of truth for product API shapes):

- [API Reference](https://docs.sanaei.dev/docs/reference/api)
- [Authentication](https://docs.sanaei.dev/docs/reference/api/authentication)
- [API Tokens](https://docs.sanaei.dev/docs/reference/api/api-tokens)
- [Inbounds](https://docs.sanaei.dev/docs/reference/api/inbounds) · [Clients](https://docs.sanaei.dev/docs/reference/api/clients) · [Hosts](https://docs.sanaei.dev/docs/reference/api/hosts) · [Nodes](https://docs.sanaei.dev/docs/reference/api/nodes)
- [Settings](https://docs.sanaei.dev/docs/reference/api/settings) · [Xray Settings](https://docs.sanaei.dev/docs/reference/api/xray-settings) · [Server](https://docs.sanaei.dev/docs/reference/api/server)
- [Subscription server](https://docs.sanaei.dev/docs/reference/api/subscription-server) · [Sub balancers](https://docs.sanaei.dev/docs/reference/api/subscription-balancers) · [WebSocket](https://docs.sanaei.dev/docs/reference/api/websocket)

This file is a project operational index plus stack-specific helper notes. If sending unfamiliar fields, verify against the deployed panel and [docs.sanaei.dev](https://docs.sanaei.dev/docs/reference/api) first. Live code and the deployed panel win over this reference.

## Authentication Boundary

Official panel rule ([auth docs](https://docs.sanaei.dev/docs/reference/api/authentication)): **cookie session and Bearer token both work for every endpoint under `/panel/api/*`**. CSRF is required for browser cookie sessions on unsafe methods; Bearer callers skip CSRF (middleware short-circuits).

| Mode | Setup | CSRF | Use |
| --- | --- | --- | --- |
| Cookie session | `POST /login` with username, password, and optional `twoFactorCode`; keep cookies | Get `/csrf-token` and send `X-CSRF-Token` on unsafe requests when available | UI, WebSocket (`/ws`), and any `/panel/api/*` call |
| Bearer API token | Settings → Security → API Token; send `Authorization: Bearer <token>` | Not required for authenticated Bearer API requests | Programmatic `/panel/api/*` (bots, scripts, nodes) |

Scoped token roles ([API tokens](https://docs.sanaei.dev/docs/reference/api/api-tokens)):

| Scope | Capability |
| --- | --- |
| `admin` | Full panel API (default) |
| `monitor` | Read-only status/metrics |
| `node-sync` | Node configuration without panel self-update |
| `node-admin` | `node-sync` plus panel self-update |

Tokens are stored as SHA-256 hashes; plaintext is returned **once** at create. Prefer least privilege for automation.

**Project helper rule** (`3xui_api.bash`): emit Bearer only for paths under `/panel/api/*`. Dual-path helpers may still fall back to legacy `/panel/setting/*` and `/panel/xray/*` on HTTP 404 for older panels — that is compatibility, not the current upstream contract. `/ws` and public subscription bodies remain cookie/session or unauthenticated subscription-server routes as documented upstream.

Never persist real API tokens, credentials, cookies, subscription IDs, client IDs, generated private keys, or node tokens in the repository, fixtures, logs, reports, or project context.

Example API-token request:

```bash
curl -fsS \
  -H "Authorization: Bearer ${XUI_API_TOKEN}" \
  -H "Accept: application/json" \
  "${XUI_BASE_URL}/panel/api/inbounds/list"
```

Common response envelope:

```json
{"success":true,"obj":{},"msg":""}
```

Check `.success` and surface `.msg`; do not assume HTTP 200 means a mutation was applied.

## Runtime API Helper Contract

`3xui_api.bash` owns panel HTTP calls.

- `xui_url` appends a path to the resolved panel base.
- `xui_api_auth_args` adds Bearer only for `/panel/api/*`.
- `xui_csrf_args` adds `X-CSRF-Token` when `/csrf-token` returns one.
- `xui_login` logs in with JSON credentials and optional `TWO_FACTOR_CODE`.
- `resolve_panel_base` tries current, configured, domain, and default local bases with current and new credentials because first apply can change base path, port, and admin credentials.
- `*_dual_path` helpers try canonical `/panel/api/...` routes first and fall back to legacy UI routes on HTTP 404.
- `*_once_long` helpers disable retry for create-like mutations where a timeout could duplicate work.

Route migration in current helpers:

| Function | Canonical | Legacy fallback |
| --- | --- | --- |
| `xui_get_panel_settings` | `POST /panel/api/setting/all` | `POST /panel/setting/all` |
| `xui_update_panel_settings` | `POST /panel/api/setting/update` | `POST /panel/setting/update` |
| `xui_update_admin_credentials` | `POST /panel/api/setting/updateUser` | `POST /panel/setting/updateUser` |
| `xui_restart_panel` | `POST /panel/api/setting/restartPanel` | `POST /panel/setting/restartPanel` |
| `xui_get_xray_settings` | `POST /panel/api/xray/` | `POST /panel/xray/` |
| `xui_update_xray_settings` | `POST /panel/api/xray/update` | `POST /panel/xray/update` |
| `xui_warp_config` | `POST /panel/api/xray/warp/config` | `POST /panel/xray/warp/config` |
| `xui_warp_register` | `POST /panel/api/xray/warp/reg` | `POST /panel/xray/warp/reg` |

## Authentication And Session Routes

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/login` | Start cookie session; JSON body includes `username`, `password`, optional `twoFactorCode`. |
| POST | `/logout` | Clear session cookie; browser session requires CSRF. |
| GET | `/csrf-token` | Return a CSRF token for the current session. |
| POST | `/getTwoFactorEnable` | Return whether OTP is required at login. |

## Inbounds

Payload rule: current 3.x responses return `settings`, `streamSettings`, and `sniffing` as nested JSON objects. Writes should send nested objects; JSON-encoded strings are legacy compatibility only.

| Method | Path | Purpose / notes |
| --- | --- | --- |
| GET | `/panel/api/inbounds/list` | Full inbound list with enriched `clientStats`. |
| GET | `/panel/api/inbounds/list/slim` | Reduced client fields for list pages. |
| GET | `/panel/api/inbounds/options` | Picker fields: `id`, `remark`, `protocol`, `port`, `tlsFlowCapable`. |
| GET | `/panel/api/inbounds/get/{id}` | Full single inbound. |
| POST | `/panel/api/inbounds/add` | Create full inbound payload. |
| POST | `/panel/api/inbounds/update/{id}` | Replace full inbound; avoid for enable-only changes. |
| POST | `/panel/api/inbounds/setEnable/{id}` | Enable-only change for large inbounds. |
| POST | `/panel/api/inbounds/del/{id}` | Delete inbound and associated client-stats rows. |
| POST | `/panel/api/inbounds/bulkDel` | Delete many inbounds sequentially; returns per-id failures and restarts Xray at most once. |
| POST | `/panel/api/inbounds/{id}/resetTraffic` | Reset inbound aggregate counters only. |
| POST | `/panel/api/inbounds/{id}/delAllClients` | Remove all clients attached to one inbound while keeping the inbound; destructive. |
| POST | `/panel/api/inbounds/resetAllTraffics` | Reset all inbound aggregate counters. |
| POST | `/panel/api/inbounds/import` | Import form field `data` containing JSON. |
| GET | `/panel/api/inbounds/{id}/fallbacks` | Read fallback children for a master inbound. |
| POST | `/panel/api/inbounds/{id}/fallbacks` | Replace `{"fallbacks":[...]}`; triggers Xray restart. |

Fallback entries use `childId`, optional `name`, `alpn`, `path`, `xver`, and `sortOrder`.

## First-Class Clients

A client can attach to multiple inbounds. For writes, use JSON bodies. Encode `{email}` and `{subId}` as URL path components.

| Method | Path | Purpose / body |
| --- | --- | --- |
| GET | `/panel/api/clients/list` | Full clients including inbound IDs and traffic. |
| GET | `/panel/api/clients/list/paged` | Slim paginated list; query `page`, `pageSize` max 200, `search`, `filter`, `protocol`, `sort`, `order`. |
| GET | `/panel/api/clients/get/{email}` | Full client plus `inboundIds`. |
| POST | `/panel/api/clients/add` | `{"client":{...},"inboundIds":[...]}`; server can generate protocol secrets. |
| POST | `/panel/api/clients/update/{email}` | Replacement client body, not a patch. Preserve required fields. |
| POST | `/panel/api/clients/del/{email}` | Delete and detach; `?keepTraffic=1` keeps traffic row. |
| POST | `/panel/api/clients/{email}/attach` | `{"inboundIds":[...]}`. |
| POST | `/panel/api/clients/{email}/detach` | `{"inboundIds":[...]}`. |
| POST | `/panel/api/clients/resetAllTraffics` | Reset all client counters. |
| POST | `/panel/api/clients/delDepleted` | Delete quota-exhausted or expired clients. |
| POST | `/panel/api/clients/bulkAdjust` | `{"emails":[...],"addDays":n,"addBytes":n}`; unlimited fields are skipped. |
| POST | `/panel/api/clients/bulkDel` | Delete many clients; optional `keepTraffic=true`; one Xray restart at the end. |
| POST | `/panel/api/clients/bulkCreate` | Create many clients from `/add` payloads; duplicate/error items are skipped with reasons. |
| POST | `/panel/api/clients/bulkAttach` | Attach many existing clients to many inbounds; returns per-email attached/skipped/errors. |
| POST | `/panel/api/clients/bulkDetach` | Detach many existing clients from many inbounds; client rows remain. |
| POST | `/panel/api/clients/bulkResetTraffic` | Reset traffic for many clients. |
| POST | `/panel/api/clients/resetTraffic/{email}` | Reset one client and re-enable it across attachments. |
| POST | `/panel/api/clients/updateTraffic/{email}` | `{"upload":bytes,"download":bytes}`. |
| POST | `/panel/api/clients/ips/{email}` | Connected source IP history. |
| POST | `/panel/api/clients/clearIps/{email}` | Clear source IP history. |
| POST | `/panel/api/clients/onlines` | Emails active within heartbeat window. |
| POST | `/panel/api/clients/lastOnline` | Email-to-last-seen timestamp map. |
| GET | `/panel/api/clients/traffic/{email}` | One client's traffic/quota/expiry. |
| GET | `/panel/api/clients/subLinks/{subId}` | Subscription URLs as JSON array, not base64. |
| GET | `/panel/api/clients/links/{email}` | All share URLs for one client. |

Core managed client fields include `email`, `subId`, protocol secret fields (`id`, `uuid`, `password`, `auth`), `flow`, `totalGB`, `expiryTime`, `limitIp`, `tgId`, `comment`, `enable`, and optional group labels when supported by the deployed panel.

## Client Groups

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/panel/api/clients/groups` | List persisted and derived groups with member counts. |
| GET | `/panel/api/clients/groups/{name}/emails` | Return email list for one group. |
| POST | `/panel/api/clients/groups/create` | Create an empty persistent group. |
| POST | `/panel/api/clients/groups/rename` | Rename a group and propagate labels. |
| POST | `/panel/api/clients/groups/delete` | Delete group placeholder and clear group labels; clients are not deleted. |
| POST | `/panel/api/clients/groups/bulkAdd` | Add many clients to a group, auto-creating the group if needed. |
| POST | `/panel/api/clients/groups/bulkRemove` | Clear group labels from many clients without deleting clients. |

## Nodes

Remote nodes are other 3x-ui panels registered by URL plus API token. Never expose `apiToken` in logs or retained output.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/panel/api/nodes/list` | Node configuration and last health snapshot. |
| GET | `/panel/api/nodes/get/{id}` | Single node. |
| POST | `/panel/api/nodes/add` | Create node from connection details. |
| POST | `/panel/api/nodes/update/{id}` | Replace connection details. |
| POST | `/panel/api/nodes/del/{id}` | Delete without migrating attached inbounds. |
| POST | `/panel/api/nodes/setEnable/{id}` | Pause/resume traffic sync. |
| POST | `/panel/api/nodes/test` | Probe unsaved connection details. |
| POST | `/panel/api/nodes/certFingerprint` | Fetch HTTPS leaf certificate SHA-256 fingerprint for pinning self-signed nodes. |
| POST | `/panel/api/nodes/probe/{id}` | Probe and update cached health. |
| POST | `/panel/api/nodes/updatePanel` | Trigger panel self-update on enabled online nodes; returns per-node results. |
| GET | `/panel/api/nodes/history/{id}/{metric}/{bucket}` | Node `cpu` or `mem` history. |

Connection fields include `name`, `remark`, `scheme`, `address`, `port`, `basePath`, `apiToken`, `enable`, and `allowPrivateAddress`. Review SSRF/private-address implications before enabling private-address access.

## Server, Geo, And Backup API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/panel/api/server/status` | Cached host/Xray status snapshot. |
| GET | `/panel/api/server/history/{metric}/{bucket}` | Six-hour history for `cpu`, `mem`, `netUp`, `netDown`, `online`, load metrics. |
| GET | `/panel/api/server/xrayMetricsState` | Xray runtime metrics availability/current snapshot. |
| GET | `/panel/api/server/xrayMetricsHistory/{metric}/{bucket}` | Xray allocation/GC metric history. |
| GET | `/panel/api/server/xrayObservatory` | Latest outbound observatory snapshot. |
| GET | `/panel/api/server/xrayObservatoryHistory/{tag}/{bucket}` | Outbound probe history. |
| GET | `/panel/api/server/getXrayVersion` | Available Xray binary versions. |
| GET | `/panel/api/server/getPanelUpdateInfo` | Check for a newer panel release. |
| GET | `/panel/api/server/getConfigJson` | Running assembled Xray config. |
| GET | `/panel/api/server/getDb` | Download SQLite backup. |
| GET | `/panel/api/server/getNewUUID` | Generate UUID. |
| GET | `/panel/api/server/getNewX25519Cert` | Generate REALITY keypair. |
| GET | `/panel/api/server/getNewmldsa65` | Generate ML-DSA-65 material. |
| GET | `/panel/api/server/getNewmlkem768` | Generate ML-KEM-768 material. |
| GET | `/panel/api/server/getNewVlessEnc` | Generate VLESS encryption options. |
| POST | `/panel/api/server/stopXrayService` | Stop all proxy traffic; destructive/operator-visible. |
| POST | `/panel/api/server/restartXrayService` | Reload current Xray config. |
| POST | `/panel/api/server/installXray/{version}` | Install Xray version or `latest`; destructive/operator-visible. |
| POST | `/panel/api/server/updatePanel` | Self-update panel and restart; destructive/operator-visible. |
| POST | `/panel/api/server/updateGeofile[/{fileName}]` | Refresh default geo files. |
| POST | `/panel/api/server/logs/{count}` | Panel log tail. |
| POST | `/panel/api/server/xraylogs/{count}` | Filtered Xray log tail. |
| POST | `/panel/api/server/importDB` | Restore multipart `db`; destructive and restarts panel. |
| POST | `/panel/api/server/getNewEchCert` | Generate ECH data for form field `sni`. |
| GET | `/panel/api/custom-geo/list` | List custom GeoIP/GeoSite sources. |
| GET | `/panel/api/custom-geo/aliases` | List usable custom geo aliases. |
| POST | `/panel/api/custom-geo/add` | Add custom geo source. |
| POST | `/panel/api/custom-geo/update/{id}` | Replace custom geo source. |
| POST | `/panel/api/custom-geo/delete/{id}` | Remove custom geo source. |
| POST | `/panel/api/custom-geo/download/{id}` | Download one custom geo source. |
| POST | `/panel/api/custom-geo/update-all` | Refresh all custom geo sources. |
| POST | `/panel/api/backuptotgbot` | Send fresh DB backup to configured Telegram admins. |

Allowed history bucket seconds: `2`, `30`, `60`, `120`, `180`, `300`.

## Hosts (per-inbound subscription overrides)

Hosts supersede the legacy inbound `externalProxy` array ([Hosts API](https://docs.sanaei.dev/docs/reference/api/hosts)). Each enabled host emits an extra subscription link/proxy with its own address/port/TLS.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/panel/api/hosts/list` | Hosts grouped by inbound / sort order. |
| GET | `/panel/api/hosts/raw` | Flat host rows with numeric IDs (pickers). |
| POST | `/panel/api/hosts/add` | Create host override(s). |
| POST | `/panel/api/hosts/update/{id}` | Replace one host row. |
| POST | `/panel/api/hosts/del/{id}` | Delete one host. |
| POST | `/panel/api/hosts/bulk*` | Bulk enable/disable/delete/reorder when present on the deployed panel. |

Do not reintroduce `externalProxy` fields in managed inbound JSON unless the live panel version still requires them.

## Subscription balancers

JSON-subscription client-side balancers ([sub-balancers](https://docs.sanaei.dev/docs/reference/api/subscription-balancers)): each enabled balancer becomes an extra JSON config document (`routing.balancers` + `burstObservatory`) for clients on the selected inbounds.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/panel/api/sub-balancers` | List balancers. |
| POST | `/panel/api/sub-balancers` | Create (`remark`, `inboundIds`, strategy `random`/`roundRobin`/`leastPing`/`leastLoad`, optional weights). |
| POST | `/panel/api/sub-balancers/{id}` | Full-row update. |
| DELETE or POST | `/panel/api/sub-balancers/{id}` or `.../{id}/del` | Delete. |

## Settings, Xray, Subscriptions, And WebSocket

Canonical settings/Xray routes are under `/panel/api/...` and accept Bearer or cookie auth. Project helpers keep session/CSRF capability and may try legacy `/panel/setting/*` / `/panel/xray/*` on 404.

| Family | Routes / purpose |
| --- | --- |
| Settings | `/panel/api/setting/all`, `/panel/api/setting/update`, `/panel/api/setting/updateUser`, `/panel/api/setting/restartPanel`, with legacy `/panel/setting/*` fallbacks in runtime helpers. |
| API tokens | `/panel/api/setting/apiTokens`, `/panel/api/setting/apiTokens/create`, `/panel/api/setting/apiTokens/delete/{id}`, `/panel/api/setting/apiTokens/setEnabled/{id}` (scopes + `expectedScope` on mutate). |
| Xray template/outbounds | `/panel/api/xray/`, `/panel/api/xray/update`, `/panel/api/xray/warp/{action}` (and Nord/PIA helpers when present upstream), with legacy `/panel/xray/*` fallbacks in runtime helpers. |
| Native subscription server | Separate listen port (`subPort`, project: `PORT_LOCAL_VLESS_SUBSCRIBE`). Formats: raw/base64 at `subPath`, JSON at `subJsonPath`, Clash/Mihomo at `subClashPath`, plus aliases `/mihomo/{subId}` and `/clash-legacy/{subId}` when Clash is enabled ([subscription config](https://docs.sanaei.dev/docs/config/subscription)). Treat subscription IDs as credentials. |
| WebSocket | `GET /ws` requires a cookie session; Bearer is not supported. Events include `status`, `xrayState`, `notification`, and `invalidate`. |

## Mutation Safety

- Prefer `inbounds/options` for selection UI and `clients/list/paged` for large client tables.
- Prefer `inbounds/setEnable/{id}` for enable toggles; avoid rewriting full inbound JSON solely to change one flag.
- Use bulk endpoints for large multi-client or multi-inbound changes to avoid per-item races and repeated Xray restarts.
- Treat delete, bulk delete, group delete, host delete, traffic reset, depleted-client cleanup, database import, Xray stop/install, panel update, node panel update, API-token delete, and panel restart as destructive/operator-visible operations.
- Do not blindly retry non-idempotent create/update/delete calls after a timeout; reconcile by reading state first.
- Fetch before replace-style update operations so omitted client or node fields are not lost.
- When changing project runtime helpers, keep `xui_api_post_json_once_long` and similar no-retry helpers for create-like operations.
