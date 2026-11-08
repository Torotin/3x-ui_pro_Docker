# Design: UDP443 backend (AmneziaWG ↔ Hysteria2) + managed scripts

Date: 2026-11-08  
Status: draft for user review  
Branch target (implementation): new feature branch from `dev` (not the spike evidence-only branch)  
Live verification host: **`vps-vdsok-streambase`**

## Problem

Streambase proved native 3x-ui AmneziaWG on `443/udp` (spike inbound id=13, WSL + phone QR OK). Installer and AfterStart still assume Hysteria2 owns that UDP publish via `ENABLE_HYSTERIA2` / `PORT_LOCAL_HYSTERIA`. Operators need a single, understandable way to choose which protocol owns public `443/udp`, with AWG as the new default, without running both on the same port.

## Goals

- Wizard/env selector **`UDP443_BACKEND=amneziawg|hysteria2|off`** (default **`amneziawg`**).
- Rename port var to **`PORT_LOCAL_UDP443`** (compose `443:${PORT_LOCAL_UDP443:-443}/udp`).
- AfterStart desired_state + ensure/delete for **`amneziawg`** and existing **`hysteria2`**, mutually exclusive on that port.
- Inactive protocol: **delete** managed inbound (recreate on switch-back).
- Update `script/**` templates, menu, firewall copy, summary; update `docker-proxy/3x-ui/scripts/**` runtime.
- Unit/installer/compose tests updated locally; **end-to-end validation on streambase**.

## Non-goals (v1)

- Second UDP publish / HY2 on alternate public port.
- Parking disabled inbounds on 5443 (spike-only mitigation; automation uses delete).
- Kernel-mode AWG (unsupported in Docker).
- Fixing upstream panel export `true`/`false` vs `on`/`off` (document workaround only).
- Full Clash Meta AmneziaWG node parity as a release blocker.
- Merging spike docs branch as a substitute for this feature work.

## Decisions

| Topic | Choice |
|---|---|
| Port ownership | Mutual exclusion on shared public **`443/udp`** |
| Menu UX | Single selector **`UDP443_BACKEND`** (not two independent toggles) |
| Default | **`amneziawg`** |
| Inactive inbound | **Delete** managed row |
| Port env name | **`PORT_LOCAL_UDP443`** |
| Legacy port env | Read **`PORT_LOCAL_HYSTERIA`** if new unset |
| Legacy enable | If **`UDP443_BACKEND` unset**: `ENABLE_HYSTERIA2=true` → `hysteria2`; `ENABLE_HYSTERIA2=false` → **`amneziawg`** (new default, not `off`); if both unset → **`amneziawg`** |
| Compose | Keep single UDP mapping; switch variable name only |
| UFW | Keep `443/udp` allow while backend ≠ conceptual “no UDP service”; wording = UDP443 backend |
| Live test | **streambase** after script sync/restart |
| Clash/AUTO | VLESS path unchanged; do not block v1 on AWG Clash proxy type; omit HY2 from Clash when backend ≠ hysteria2 |

## Architecture

```text
installer wizard
  UDP443_BACKEND + PORT_LOCAL_UDP443
        │
        ▼
compose.d/.env + 3x-ui.env
        │
        ▼
AfterStart 3x-ui-upd.sh
  resolve backend → ensure active inbound on PORT_LOCAL_UDP443
                 → delete other managed udp443 inbound (hy2 xor awg)
                 → ensure protocol-specific client(s)
                 → wait UDP listener when backend ≠ off
```

Panel constraint (from spike): even `enable=0` can reserve the panel port — hence **delete**, not disable-in-place on 443.

## Env / installer (`script/`)

- Templates (`install.env`, `docker.env`, summary): add `UDP443_BACKEND`, `PORT_LOCAL_UDP443`; stop writing `ENABLE_HYSTERIA2` / `PORT_LOCAL_HYSTERIA` as primary keys (compat read retained in `02_env.sh`).
- Menu (`01_menu.sh`): replace HY2 bool toggle with cycling/select for `UDP443_BACKEND`.
- `02_env.sh`: defaults, normalization, legacy mapping table above; export derived booleans for libs if useful (`ENABLE_HYSTERIA2` / `ENABLE_AMNEZIAWG` as **derived**, not independently settable in wizard).
- Firewall/uninstall/summary strings: “UDP 443 backend” not “Hysteria2-only”.

## AfterStart (`docker-proxy/3x-ui/scripts/`)

- `desired_state.bash`: inbound kind **`amneziawg`** (`protocol=amneziawg`, port from `PORT_LOCAL_UDP443`, subnet/mtu/dns; preserve panel-generated obfuscation `server` on update).
- `inbound_runtime.bash` / `3x-ui-upd.sh`: ensure active kind; **delete** managed inactive kind (match by managed remark/protocol policy consistent with existing ensure).
- AWG clients: first-class `clients/add` + inbound id (spike path); HY2 keeps `ensure_hysteria2_client`.
- `xray_runtime.bash` wait: UDP wait for active backend only.
- `env.bash`: load/normalize new vars (+ derived flags).

## Subscriptions

- Managed AWG client ensured for operator use (panel conf/QR/sub — already validated on phone).
- Clash/AUTO: no hard dependency on AWG proxy type in v1; when backend is `amneziawg`, do not advertise HY2; keep VLESS nodes.

## Testing

### Local (mock)

- `tests/install-scripts/test_installer_cli.bash` — selector, env render, bool validation removal/replacement.
- `tests/run-compose/test_stage_tcp_clean_architecture.bash` — `PORT_LOCAL_UDP443`, generic UDP443 stage ownership.
- `tests/3x-ui-scripts/test_libs.bash` — desired_state/ensure/delete/wait for amneziawg + exclusivity.

### Live (required for done)

Host: **`vps-vdsok-streambase`**

1. Sync scripts + env (`UDP443_BACKEND=amneziawg`, `PORT_LOCAL_UDP443=443`).
2. Restart/recreate `3x-ui` as project usual.
3. Confirm: one UDP listener on 443; protocol amneziawg; no competing HY2 on 443.
4. Client smoke: existing phone/WSL conf or fresh panel export (fix `true`/`false`→`on`/`off` if needed for Linux).
5. Switch test (optional but preferred): `hysteria2` then back to `amneziawg` — delete/recreate behavior, port free.
6. `off` (optional): no managed UDP inbound / no required listener.

Spike leftovers (id=13 / id=4): reconcile under managed remarks or delete+recreate; do not leave dual owners.

## Risks

| Risk | Mitigation |
|---|---|
| Panel port reservation | Delete inactive managed inbound |
| Legacy env surprise | Document mapping; prefer explicit `UDP443_BACKEND` on streambase |
| Clash without AWG node | Accepted in v1; native QR works |
| Export boolean JSON | Ops note; phone/Amnezia apps may accept panel QR as-is |
| Name churn in tests | Update all HYSTERIA port assertions in one PR |

## Success criteria

- Fresh install defaults to AWG on `443/udp` via selector.
- Cannot enable HY2 and AWG together through installer/env resolution.
- AfterStart converges to exactly one managed UDP443 inbound (or none if `off`).
- Local test suites green for changed contracts.
- Streambase live: AWG connect works after managed apply; HY2 not bound to 443 while AWG active.

## Open follow-ups (post-v1)

- Optional Clash/AWG emission when Meta supports stack config.
- Rename-only cleanup removing all `PORT_LOCAL_HYSTERIA` compat shims.
- Panel export normalization (`on`/`off`) if upstream allows.
