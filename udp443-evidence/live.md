# Streambase live verification — managed UDP443 AWG backend

**Date (UTC):** 2026-11-08T03:53Z  
**Host:** tide-drift (`vps-vdsok-streambase`)  
**Branch deployed:** `feat/udp443-backend-awg` @ `64c8dbc9437a7ffc6bd27f881af44334e05a6b57`  
**Deploy root:** `/opt/docker-proxy`

## Sync applied

- `docker-proxy/3x-ui/scripts/**` — rsync from branch workspace via `/tmp/udp443-scripts-sync` (no CRLF conversion; `dos2unix`/`sed '\r$'` avoided after corruption incident)
- `docker-proxy/3x-ui/3x-ui.env`
- `docker-proxy/compose.d/12-3x-ui.yml`
- `compose.d/.env` keys: `UDP443_BACKEND=amneziawg`, `PORT_LOCAL_UDP443=443`, `ENABLE_HYSTERIA2=false`, `ENABLE_AMNEZIAWG=true` (secrets unchanged)

**Restart:** `/opt/docker-proxy/compose.d/run-compose.sh restart 3x-ui`

## Runtime env (container)

| Variable | Value |
|----------|-------|
| `UDP443_BACKEND` | `amneziawg` |
| `ENABLE_AMNEZIAWG` | `true` |
| `ENABLE_HYSTERIA2` | `false` |
| `PORT_LOCAL_UDP443` | `443` |

Container: **healthy** after AfterStart.

## Panel DB (`inbounds`)

AWG backend (final state after switch test restored AWG):

| id | remark | port | protocol | enable |
|----|--------|------|----------|--------|
| 13 | `awg-spike-443` | 443 | amneziawg | 1 |

AfterStart (apply mode) highlights:

- `APPLY: delete managed hysteria2 inbound id=4` — no Hysteria2 left on 443
- `amneziawg inbound already exists id=13 port=443; preserving existing configuration.` — spike inbound retained (managed alias `awg-spike-443` accepted)

No `hysteria2` rows in sqlite after AWG mode.

## UDP listener

```
ss -ulnp | grep :443
UNCONN 0 0 0.0.0.0:443 0.0.0.0:*
UNCONN 0 0 [::]:443 [::]:*
```

Host publishes `443/udp` to `3x-ui` per `12-3x-ui.yml`.

## Optional backend switch test

1. Set `UDP443_BACKEND=hysteria2` + derived enables → restart → **id=14** `🇩🇪 hysteria2` on **443** (`protocol=hysteria`), healthy.
2. Restored `UDP443_BACKEND=amneziawg` → **id=13** AWG on **443** again; HY2 row absent.

## Client smoke (WSL, optional)

`~/awg-spike/client-phone.conf` exists. `awg-quick up` reached interface config via userspace fallback; IPv6 rule step failed (`RTNETLINK: No such device`) — typical WSL2 userspace path. Phone client reported working in prior spike; not re-tested here.

## Incidents / ops notes

- Initial sync used `sed -i 's/\r$//'` on scripts with LF-only payloads; that corrupted tokens (`dirname`→`diname`, `$user`→`use`). **Fix:** re-staged via `scp` to `/tmp` + `sudo rsync` without CRLF tools (local scripts are LF-only).

## Outcome

**PASS:** Managed AWG owns **443/udp** on streambase; Hysteria2 deleted from 443; AfterStart apply completes; backend switch round-trip verified.
