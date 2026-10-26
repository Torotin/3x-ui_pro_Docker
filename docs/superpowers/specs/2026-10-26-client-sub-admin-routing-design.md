# Design: Client subscription admin-plane routing (native 3x-ui)

Date: 2026-10-26  
Status: approved (brainstorm)  
Branch: `feat/xray-admin-access`  
Depends on: Xray-only admin access (`2026-10-25-xray-admin-access-design.md`)

## Problem

Admin UIs live on Traefik entrypoint `admin` (`https://<svc>.${WEBDOMAIN}:9443/…`) and are reached only when the **client** sends that traffic through Xray (server routes admin FQDNs / `:9443` to `admin-traefik`).

Native 3x-ui subscriptions currently ship Clash/JSON/base64 **without** admin-plane client routing:

- `subClashEnableRouting=false`, `subClashRules` empty  
- JSON routing fields empty  
- `subEnableRouting` / `subRoutingRules` are Happ-only HTTP headers (not Clash)

Operators must hand-craft Mihomo configs (e.g. prizrak-test). Fresh Clash/JSON subscribers miss admin Hosts or hit fake-ip / `geoip:private` failures.

## Goals

- Clash and JSON subscriptions include **correct admin-plane routing** so panels open through a stock client config.
- Drive this only via **native panel AllSetting** (`ensure_panel_settings` / `desired_panel_keys`) — no subscription post-processor.
- DNS safety for admin FQDNs: `hosts` → public A (`PUBLIC_IPV4`) + `fake-ip-filter` for `WEBDOMAIN` / `+.${WEBDOMAIN}` when the Clash merge accepts those keys.
- Hidden Clash group `ADMIN` (`hidden: true`) whose only upstream is `PROXY`.
- Disable classic base64/standard subscription (`subEnable=false`) **after** an audit that clients already use Clash/JSON.
- Live-verify on `vps-vdsok-streambase-torotin`.

## Non-goals

- RU/geosite “full” routing packs (banks/gov/etc.).
- Enabling Happ / Incy subscription profiles as part of this work.
- Custom subscription reverse-proxy / YAML patch middleware.
- Changing `URI_SUB_PATH` / `URI_JSON_PATH` / `URI_CLASH_PATH` strings without a separate approved migration.
- Replacing server-side `admin-traefik` routing (already required).
- Installing private CAs on client devices.

## Hard invariants

1. **Subscription continuity:** Do not rename/move Clash/JSON public paths without approval. Base64 disable is an enable-flag change after audit, with rollback `subEnable=true`.
2. **Native only:** No new generator that rewrites sub HTTP responses outside 3x-ui.
3. **Do not confuse Happ headers with Clash routing:** `subEnableRouting` / `subRoutingRules` must not be treated as Clash/JSON config.
4. **Admin FQDN set** matches server plane: `arcane`, `homepage`, `adguard`, `3x-ui`, `traefik`, `lampac-admin` under `${WEBDOMAIN}`.
5. **No silent capability lie:** If spike shows the panel ignores `hosts` / `hidden` / `proxy-groups`, document fallback explicitly (rules → `PROXY`); do not invent a post-processor in this design.

## Decisions (from brainstorm)

| Topic | Choice |
| --- | --- |
| Scope | Admin-plane only |
| Formats with routing | Clash + JSON |
| Base64 | Audit, then disable (`subEnable=false`) |
| DNS | `hosts` + `fake-ip-filter` (preferred) |
| Clash group | Hidden `ADMIN` → `[PROXY]` |
| Injection | Native panel settings (approach 2) |

## Chosen approach

**Approach 2 — Full desired-state through native Clash/JSON settings.**

Render managed subscription fields from env/`desired_state` into panel AllSetting:

1. **Spike** on the deployed 3x-ui: fetch Clash YAML after setting a probe `subClashRules` YAML block; confirm which top-level keys merge (`rules`, `proxy-groups`, `hosts`, `dns`, …).
2. **Clash:** `subClashEnableRouting=true` + `subClashRules` YAML that includes (as supported):
   - `proxy-groups` with generated-compatible `PROXY` and hidden `ADMIN` → `PROXY`
   - `rules` with `DOMAIN,<adminFQDN>,ADMIN` (and optional port-aware rules if useful) before `MATCH,PROXY`
   - `hosts` / `dns.fake-ip-filter` when merge supports them
3. **JSON:** enable/fill `subJsonRoutingRules` / `subJsonRules` / `subJsonDns` as supported for the same admin domains.
4. Expand `desired_panel_keys` + env overlay so `ensure_panel_settings` converges these fields.
5. **Base64:** audit usage → disable `subEnable`; keep path strings unless a later change is approved.
6. Update install summary to highlight Clash/JSON URIs as canonical for admin access.

### Rejected alternatives

- **Rules-only → PROXY:** weaker DNS story; no hidden ADMIN semantics.
- **Native rules + rely only on AdGuard rewrite:** fails for clients using built-in Clash DNS/fake-ip without our DoH.
- **Subscription post-processor:** violates native-only decision.

## Architecture

```text
PUBLIC_IPV4 + WEBDOMAIN + admin host list
        │
        ▼
desired_state / env  →  panel AllSetting
        │                 (subClashEnableRouting, subClashRules,
        │                  subJson* routing/DNS fields, subEnable)
        ▼
3x-ui subscription server
        ├─ Clash path  → Mihomo YAML (merged rules/groups/hosts)
        ├─ JSON path   → Xray client JSON (+ routing/DNS if supported)
        └─ base64 path → disabled after audit
        │
        ▼
Client (FlClash/Mihomo/…) → PROXY → Xray → admin-traefik :9443
```

## Components

### Runtime (`docker-proxy/3x-ui/scripts`)

- Extend `desired_panel_keys` for Clash routing flags/rules and JSON routing/DNS keys actually present on the panel.
- Helper to build `subClashRules` YAML from `WEBDOMAIN` + `PUBLIC_IPV4` (fail/skip hosts if IPv4 missing).
- `ensure_panel_settings` already POSTs full AllSetting — keep that contract (3.7 validation).

### Installer / summary

- Document Clash + JSON subscription URLs as required for admin panels.
- Note base64 deprecated/disabled after migration.

### Traefik

- No new routers required. Existing `3xui-sub` continues to front enabled paths.

## Clash profile shape (target)

When merge allows full block:

```yaml
proxy-groups:
  - name: PROXY
    type: select
    # proxies: preserved/merged with panel-generated node list (spike-defined)
  - name: ADMIN
    type: select
    hidden: true
    proxies:
      - PROXY
hosts:
  arcane.${WEBDOMAIN}: ${PUBLIC_IPV4}
  # … other admin FQDNs + apex WEBDOMAIN
dns:
  fake-ip-filter:
    - ${WEBDOMAIN}
    - "+.${WEBDOMAIN}"
rules:
  - DOMAIN,arcane.${WEBDOMAIN},ADMIN
  - DOMAIN,homepage.${WEBDOMAIN},ADMIN
  - DOMAIN,adguard.${WEBDOMAIN},ADMIN
  - DOMAIN,3x-ui.${WEBDOMAIN},ADMIN
  - DOMAIN,traefik.${WEBDOMAIN},ADMIN
  - DOMAIN,lampac-admin.${WEBDOMAIN},ADMIN
  - MATCH,PROXY
```

Exact merge semantics for `PROXY.proxies` auto-fill vs wholesale `proxy-groups` replace are **spike-gated**. If custom `proxy-groups` drops node names, prefer rules targeting the panel’s existing `PROXY` group and omit a separate `ADMIN` group only if `hidden` groups cannot be added without breaking node lists — still record the gap.

## JSON profile shape (target)

- Routing rules matching the six admin FQDNs to the subscription’s proxy outbound (panel field names as supported: `subJsonRoutingRules` / `subJsonRules`).
- DNS/hosts via `subJsonDns` when present and effective; otherwise document gap (Clash remains canonical for admin DNS).

## Base64 migration

1. Audit access/logs or operator confirmation that clients use Clash/JSON.  
2. Announce Clash/JSON URIs (summary / ops note).  
3. Set `subEnable=false` via desired panel settings.  
4. Rollback: `subEnable=true`.

## Error handling

| Condition | Behavior |
| --- | --- |
| Spike: `hosts`/`dns` ignored | Ship DOMAIN→`PROXY`/`ADMIN` rules only; note DNS gap |
| Spike: custom `proxy-groups` clears nodes | Do not replace `PROXY` wholesale; inject rules to existing `PROXY`; add `ADMIN` only if safe |
| `PUBLIC_IPV4` empty | Skip `hosts` entries; WARN in logs |
| Panel rejects AllSetting | Keep prior settings; fail apply visibly |
| Base64 disabled too early | Re-enable `subEnable` |

## Testing

- Unit: Clash rules builder emits all six admin domains; hosts map uses provided IPv4; empty IPv4 omits hosts.
- Unit/mock: panel desired keys include routing enable + non-empty Clash rules.
- Live: Clash fetch contains admin `DOMAIN` rules; optional assert `hosts`/`ADMIN` if spike OK.
- Live: client via Clash sub reaches `https://arcane.${WEBDOMAIN}:9443/` → HTTP 401 (Basic Auth).
- Live: after disable, standard `subPath` does not serve a usable base64 node list.
- Regression: JSON/Clash path prefixes and VLESS share links still work.

## Verification (live)

1. Apply panel settings; restart panel if required by runtime.  
2. `curl` Clash + JSON subscription bodies for a test `subId`.  
3. Import Clash into FlClash/Mihomo; open each admin URL on `:9443`.  
4. Confirm no `blocked target: 172.18.0.6:9443` regressions on server.  
5. Complete base64 audit → disable → smoke Clash/JSON only.

## Done when

- Clash (and JSON as capable) subscriptions carry admin-plane routing without manual YAML.
- Admin panels open through a stock subscription on the test VPS.
- Base64 is off after audit, with documented rollback.
- No subscription response post-processor exists.
- Gaps from spike (if any) are explicit in this spec / follow-up issue, not papered over.

## Open spike checklist (resolve in implementation plan)

1. Which top-level keys does `mergeClashRulesYAML` apply on the deployed image?  
2. Does overriding `proxy-groups` preserve per-node proxy names for `PROXY`?  
3. Can `hidden: true` on `ADMIN` appear in the served YAML?  
4. Which JSON fields actually alter client routing/DNS on this panel build?  
5. Confirm Happ header fields remain untouched.
