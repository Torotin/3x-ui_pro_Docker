# Design: Stabilize AmneziaWG 3.1 on akar (prizrak health + traffic)

Date: 2026-11-08  
Status: approved for planning (canary)  
Related: UDP443 AWG rollout; prizrak-core `192.168.10.1:9090`; skill `amnezia-wg` (baseline 3.1)

## Problem

Clash/prizrak healthchecks for `🇵🇱 amneziawg` (provider `akar`) alternate between ~60–70ms and `delay=0` (UI “—”), with occasional ~5s timeouts. The same pattern appears on vdsina; streambase AWG is mostly dead in history. VLESS/HY2 on the same hosts look healthier in neighboring groups → failure mode is AWG-profile / WG-client specific, not “host unreachable”.

Live akar inbound obfuscation (panel-generated) conflicts with AmneziaWG 3.1 guidance:

- `RandomTrailers=on` with **unequal** `S1–S4` (28/102/37/16)
- Custom `H1–H4` while Header Protection is enabled (docs: keep `1/2/3/4` with HP)
- `DisableCookies=on`
- Large junk (`Jmax=305`)
- Client `keepAlive` / PersistentKeepalive **missing** (NAT flap → ok→0→ok)

Measurement path: prizrak-core `v1.19.33-r11`, group `AWG_AUTO` (Smart), test URL `generate_204`; node history matches operator table 1:1 for akar.

## Goals

1. Stable prizrak healthchecks for `🇵🇱 amneziawg`: few/no `delay=0`, typical delay &lt; 200ms over 30–60 minutes.
2. Stable manual / TUN traffic through the same node without periodic drops.
3. Canary **only on akar**; roll the same profile to vdsina/streambase only after canary success.

## Non-goals

- Changing UDP port or leaving AmneziaWG backend
- Editing prizrak Smart / `ping-config` as the primary fix
- Kernel AWG mode (stay on panel embedded `amneziawg-go`)
- Rotating `HeaderProtectionKey` or peer keypairs unless required for recovery
- Fixing vdsina/streambase in the same change set

## Target profile (akar inbound id=5)

Keep: port `443`, existing server keypair, existing client keypairs/`allowedIPs`, existing `HeaderProtectionKey`.

| Field | Target |
|---|---|
| S1–S4 | Equal, ≥12 and ≤32 (panel S4 cap), value **16** |
| H1–H4 | `1`, `2`, `3`, `4` |
| HeaderProtectionKey | Unchanged |
| RandomTrailers | `on` |
| DisableCookies | `off` (canary DPI lever; may re-enable later) |
| Jc / Jmin–Jmax | ~`4` / ~`50`–`120` |
| I1 | Keep short unique CPS or existing `<r N>`; never docs demo CPS |
| ContentPaddingAddition | Soften to ~`0-16` |
| Timing ranges (Rekey*/KeepaliveTimeout/MaxHandshake*) | Leave or mild soften; not the primary lever |
| Client `keepAlive` | `25` on all attached clients |

## Architecture / data flow

```text
Operator / API
  -> 3x-ui panel inbound update (settings.server + clients[].keepAlive)
  -> embedded amneziawg-go (panel) on UDP/443
  -> subscription HTTP provider "akar"
  -> prizrak-core WireGuard proxy "🇵🇱 amneziawg"
  -> healthcheck generate_204 + user traffic
```

Obfuscation lives once on the inbound `settings.server` and is inherited by exported client configs. Clash must refresh the provider after the server change so on-wire params match.

## Apply procedure

1. Backup inbound id=5 `settings` JSON and note current prizrak history baseline.
2. `POST /panel/api/inbounds/update/5` with a **full** `settings` object:
   - Always re-send current `server.privateKey` / `server.publicKey` and every client’s keys/`allowedIPs` (omit keys risk silent server key rotation on some panel builds).
   - Patch `settings.server` to the target profile.
   - Set each client `keepAlive: 25` explicitly.
3. Confirm inbound enabled and UDP/443 still listening; restart panel/Xray only if the running instance did not pick up settings.
4. On prizrak: `PUT /providers/proxies/akar` (refresh). Do not change other providers in this canary.
5. Observe `/providers/proxies` → `akar` → `🇵🇱 amneziawg` history; optional group view `AWG_AUTO`.

## Verification

- **API:** over 30–60 minutes, `🇵🇱 amneziawg` history mostly non-zero delays &lt; 200ms; `alive=true` consistently preferred.
- **Manual:** browse / TUN via that node without periodic stalls matching the old flap period.
- **Regression:** VLESS (and other non-AWG) nodes on akar remain healthy in prizrak.

## Rollback

Restore backed-up `settings` via the same update path (again with full key material) → refresh provider `akar`. If only cookies cause DPI pain, flip `DisableCookies` back to `on` before full rollback.

## Risks

| Risk | Mitigation |
|---|---|
| API update drops server keys | Always echo stored keypair; verify publicKey unchanged after update |
| Prizrak keeps stale obfuscation | Mandatory provider refresh; confirm new sub timestamp |
| `DisableCookies=off` worsens DPI | Canary-only; quick toggle or full rollback |
| Equal S=16 too small for path MTU concerns | Still ≥12 for HP; raise equal S within ≤32 if needed |
| Success on healthcheck but not traffic (or reverse) | Both are explicit success criteria; do not promote canary until both pass |

## Follow-up (out of this canary)

After akar succeeds: apply the same profile to vdsina and streambase (streambase currently worst in prizrak history). Optionally revisit prizrak `ping-config` only if AWG params are healthy but Smart still mis-scores.

## References

- AmneziaWG docs: https://docs.amnezia.org/ru/documentation/amnezia-wg
- 3x-ui AmneziaWG: https://docs.sanaei.dev/docs/config/amneziawg/
- Prizrak API: https://core.prizrak.app/api/
- Skill: `amnezia-wg` (`VERSION_CHECK: OK` as of 2026-11-08; `amneziawg-go` tag `v3.1.20260828`)
