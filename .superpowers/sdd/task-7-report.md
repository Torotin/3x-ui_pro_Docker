# Task 7 Report: WSL client smokes (mihomo + xray-core)

**Branch:** `feat/client-sub-connection-policies`  
**Live:** `streambase.linkpc.net`  
**SUB_ID:** `670866a00067a9b6`  
**Status:** Complete

## Deliverables

| Path | Role |
|---|---|
| `tests/wsl-clients/smoke_mihomo_sub.sh` | Clash fetch + policy asserts + `mihomo -t` + optional PROXY 401 |
| `tests/wsl-clients/smoke_xray_sub.sh` | JSON fetch + rule/balancer asserts + `xray run -test` |
| `tests/wsl-clients/README.md` | How to run in WSL |

## Product bug found by smoke (fixed + redeployed)

`mihomo -t` initially failed: AUTO/PROXY listed inbound remark `🇩🇪 vless-tcp-reality`, but Clash publishes Reality/externalProxy as `remark-<shared-email>` → `🇩🇪 vless-tcp-reality-streambase.linkpc.net-autogen`.

**Fix:**

- `clash_subscription_proxy_name_for_kind` — Vision uses `remark-email`
- `map_clash_remarks_to_published_proxy_names` — remap remarks against a Clash body when available
- AfterStart emits Vision Clash names via the helper
- Unit tests added; synced to VPS; `run-compose.sh restart 3x-ui` → AfterStart `changes=7`

## Smoke results (WSL)

Installed into `~/.local/bin` (no root package install): Mihomo Meta v1.19.33, Xray 26.10.21.

### `smoke_mihomo_sub.sh` — PASS

```text
OK: fetched 2662 bytes
OK: name: AUTO
OK: type: url-test
OK: MATCH,DIRECT
OK: admin DOMAIN,arcane…,PROXY
OK: no residual MATCH,PROXY
OK: mihomo -t
OK: PROXY curl arcane:9443 → 401
smoke_mihomo_sub: PASS
```

### `smoke_xray_sub.sh` — PASS

```text
OK: fetched 20957 bytes
OK: docs=5
OK: first doc: admin→proxy then network→direct
OK: AUTO/balancer doc at index 4
OK: AUTO balancers/leastPing
OK: AUTO observatory present
OK: xray run -test
smoke_xray_sub: PASS
```

## Spec coverage (Task 7)

| Requirement | Result |
|---|---|
| Clash AUTO url-test | PASS |
| MATCH/catch-all DIRECT | PASS |
| Admin DOMAIN→PROXY | PASS |
| mihomo config test | PASS |
| Optional admin via PROXY → 401 | PASS |
| JSON admin→proxy then network→direct | PASS |
| AUTO leastPing + observatory | PASS |
| xray run -test | PASS |

## Quality

- Smokes retry transient HTTP 500s (seen on live sub endpoints).
- Runtime binaries optional via `SKIP_RUNTIME=1`; body asserts still run.
- Unit tests: `bash tests/3x-ui-scripts/test_libs.bash` → OK after naming fix.

## Concerns

1. Panel still appends trailing JSON `network→proxy` after `subJsonRules`; first-match keeps residual DIRECT (unchanged from Task 6).
2. Vision Clash naming depends on shared client email matching panel export (`remark-email`). Body remapper is available when a Clash body file is supplied to discovery.
3. Transient Clash/JSON HTTP 500s still occur; smokes retry up to 5 times.
