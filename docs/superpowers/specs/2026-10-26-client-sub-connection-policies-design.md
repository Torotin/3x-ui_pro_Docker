# Design: Client subscription connection policies (AUTO + DIRECT default)

Date: 2026-10-26  
Status: approved (brainstorm)  
Branch: `feat/xray-admin-access`  
Depends on: client subscription admin-plane routing (`2026-10-26-client-sub-admin-routing-design.md`)

## Problem

Subscriptions currently expose each managed inbound as a separate selectable node (Clash `PROXY` select / JSON per-inbound docs). Clients must pick a node manually. There is no stock “best / most alive” policy, and the default catch-all still sends all traffic through the proxy — conflicting with the desired default of **DIRECT** until a later iteration adds client-side routing packs.

## Goals

- Ship a hybrid connection policy in **Clash and JSON** subscriptions:
  - **AUTO** — auto-pick among all managed inbound nodes (alive/best).
  - **PROXY** — manual select of nodes (and AUTO where the format allows).
- Default residual traffic: **`MATCH` / catch-all → DIRECT**.
- Keep admin-plane rules unchanged: admin FQDNs → **PROXY** (manual select path).
- Drive this via **native panel** mechanisms only (AllSetting + Sub Balancers API).
- Verify in **WSL** with **mihomo** and **xray-core** clients.

## Non-goals

- Full client routing packs (geosite/RU/banks/etc.) — next iteration.
- Subscription HTTP post-processors / Traefik body rewriters.
- Happ-only HTTP headers (`subEnableRouting` / `subRoutingRules`).
- Renaming `URI_SUB_PATH` / `URI_JSON_PATH` / `URI_CLASH_PATH`.
- Changing server-side Xray `admin-traefik` routing.
- Disabling base64 / `subEnable` in this design (separate issue; `subEnable=false` is a master gate on this panel).

## Hard invariants

1. **Native only** — no generator that rewrites subscription HTTP responses outside 3x-ui.
2. **Do not confuse Happ headers with Clash/JSON config.**
3. **Admin FQDN set** unchanged: `arcane`, `homepage`, `adguard`, `3x-ui`, `traefik`, `lampac-admin` under `${WEBDOMAIN}` → **PROXY**.
4. **Clash `proxy-groups` wholesale replace** — if emitting custom groups, must include a full `PROXY` list with real node names or omit custom groups entirely (documented fallback).
5. **`subJsonRoutingRules` is not Happ-only** — it bakes a routing profile into JSON for any Xray client — but panel `applyJsonRouting` always appends catch-all `network → proxy`, so it cannot express DIRECT default. This design therefore uses **`subJsonRules` + `subJsonDns`** for admin + DIRECT catch-all, and clears managed `subJsonRoutingRules`.

## Decisions (from brainstorm)

| Topic | Choice |
| --- | --- |
| Formats | Clash + JSON |
| Policy shape | Hybrid AUTO + manual PROXY |
| AUTO membership | All managed inbounds present in the sub (Vision / XHTTP / gRPC / Hysteria2 as enabled) |
| Default residual route | DIRECT |
| Admin domains | PROXY (unchanged) |
| Approach | Native-first (AllSetting Clash rules + JSON rules/dns + Sub Balancers) |
| Live client tests | WSL: mihomo + xray-core |

## Chosen approach

**Native-first connection policies.**

### Clash

Extend `subClashRules` builder to emit (when node names can be discovered):

```yaml
proxy-groups:
  - name: AUTO
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies: [<all discovered node names>]
  - name: PROXY
    type: select
    proxies: [AUTO, <all discovered node names>, DIRECT]
hosts: # unchanged admin map when PUBLIC_IPV4 set
dns:
  fake-ip-filter: # unchanged
rules:
  - DOMAIN,<adminFQDN>,PROXY
  # …
  - MATCH,DIRECT
```

If node-name discovery fails: do **not** emit custom `proxy-groups`; still emit admin DOMAIN rules + `MATCH,DIRECT` + hosts/dns; WARN.

### JSON

1. Keep **`subJsonDns`** (apex + admin hosts → `PUBLIC_IPV4`).
2. Set **`subJsonRules`** to Xray field-rule array: admin `full:<fqdn> → proxy`, then `network: tcp,udp → direct`.
3. Clear **`subJsonRoutingRules`** in desired state (empty) so baked profile cannot override DIRECT catch-all.
4. Ensure a **Sub Balancer** (native API): remark `AUTO`, strategy `leastPing`, `inboundIds` = all managed inbounds attached to the shared/subscription clients; configure panel-wide **`subJsonObservatory`** (probe URL/interval). Emits an extra JSON subscription document with balancer + observatory for `leastPing`.

### Rejected alternatives

- Clash-only now / JSON later — breaks “both formats”.
- Subscription post-processor — violates native-only.
- Relying solely on `subJsonRoutingRules` for DIRECT default — panel hardcodes catch-all → proxy.

## Architecture

```text
managed inbounds
        │
        ├─ Clash AllSetting (subClashEnableRouting + subClashRules)
        │     AUTO url-test + PROXY select + MATCH,DIRECT + admin→PROXY
        │
        └─ JSON AllSetting + Sub Balancers API
              subJsonDns + subJsonRules (admin→proxy, catch-all→direct)
              subJsonRoutingRules cleared
              Sub Balancer AUTO (leastPing) + subJsonObservatory
```

## Components

| Unit | Responsibility |
| --- | --- |
| `sub_admin_routing.bash` | Clash rules with AUTO/PROXY/MATCH,DIRECT; JSON rules/dns builders; optional node-name helper |
| AfterStart (`3x-ui-upd.sh`) | Export Clash/JSON fields before `ensure_panel_settings` |
| `desired_panel_keys` | Include `subJsonRules`, `subJsonDns`, `subJsonRoutingRules` (managed empty), `subJsonObservatory` as needed |
| Sub Balancer ensure helper | Idempotent create/update of AUTO balancer via panel API |
| WSL smoke harness | mihomo + xray-core checks against live or fixture subs |

## Error handling

| Condition | Behavior |
| --- | --- |
| Clash node names undiscoverable | Skip custom `proxy-groups`; keep admin rules + `MATCH,DIRECT`; WARN |
| Empty `PUBLIC_IPV4` | Omit hosts / JSON dns hosts; WARN |
| Sub Balancer API failure / no inbound ids | Skip balancer; WARN; other JSON fields still apply |
| Stale non-empty `subJsonRoutingRules` | Desired empty string overwrites so `subJsonRules` DIRECT wins |
| Panel rejects AllSetting | Fail apply visibly; keep prior settings |

## Testing

### Unit

- Clash builder emits AUTO (`url-test`), PROXY select including AUTO + nodes + DIRECT, admin DOMAIN→PROXY, `MATCH,DIRECT`.
- JSON `subJsonRules` builder: admin → proxy, catch-all → direct.
- `subJsonDns` unchanged semantics (apex + six admin hosts).
- AfterStart/desired keys manage observatory / cleared routing profile as specified.

### Live / WSL (in scope)

Run on **WSL** with:

1. **mihomo** — import Clash sub; assert groups AUTO/PROXY; residual default DIRECT; admin `:9443` via PROXY → HTTP 401 when proxied.
2. **xray-core** — import JSON sub (or merged client config); `xray run -test`; smoke that default path is DIRECT; admin path via proxy outbound/rules → 401; balancer document does not prevent start.

## Done when

- Clash and JSON subscriptions expose AUTO + manual PROXY semantics as above.
- Residual default is DIRECT in both formats (within panel capabilities).
- Admin FQDNs still route to PROXY.
- `subJsonRoutingRules` is not left overriding DIRECT.
- WSL mihomo + xray-core smokes pass.
- No subscription post-processor exists.

## Follow-ups (explicitly later)

- Client routing rule packs (what to send through PROXY/AUTO vs DIRECT).
- Revisit `subJsonRoutingRules` if upstream allows a DIRECT catch-all.
- Base64/`subEnable` policy (blocked today: master subscription gate).
