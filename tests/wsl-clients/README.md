# WSL client subscription smokes

Live checks for Clash/Mihomo and Xray JSON subscription connection policies
(AUTO + PROXY, residual DIRECT, admin → PROXY).

## Prerequisites (WSL)

- `curl`, `jq`, `bash`
- Optional: `mihomo` (or `clash` / `clash-meta`) for `mihomo -t`
- Optional: `xray` / `xray-core` for `xray run -test`

If the runtime binaries are missing, the scripts still fetch the live
subscription and assert policy shape via `grep`/`jq`, then print `SKIP` for
the binary step.

## Environment

| Variable | Default / purpose |
|---|---|
| `WEBDOMAIN` | `streambase.linkpc.net` |
| `SUB_ID` | client subscription id (required unless full URL set) |
| `CLASH_SUB_URL` | full Clash URL (overrides path + `SUB_ID`) |
| `JSON_SUB_URL` | full JSON URL (overrides path + `SUB_ID`) |
| `CLASH_PATH` | `/A1yh2uqDoMqw/` |
| `JSON_PATH` | `/Kr3AbtowEqom/` |
| `SKIP_RUNTIME` | `1` to skip mihomo/xray binary checks |
| `SKIP_PROXY_CURL` | `1` to skip optional mixed-port 401 probe |

## Run (from Windows → WSL)

```bash
wsl -e bash -lc 'cd /mnt/y/3x-ui_pro_Docker && WEBDOMAIN=streambase.linkpc.net SUB_ID=670866a00067a9b6 bash tests/wsl-clients/smoke_mihomo_sub.sh'
wsl -e bash -lc 'cd /mnt/y/3x-ui_pro_Docker && WEBDOMAIN=streambase.linkpc.net SUB_ID=670866a00067a9b6 bash tests/wsl-clients/smoke_xray_sub.sh'
```

Or inside WSL:

```bash
cd /mnt/y/3x-ui_pro_Docker
export WEBDOMAIN=streambase.linkpc.net SUB_ID=670866a00067a9b6
bash tests/wsl-clients/smoke_mihomo_sub.sh
bash tests/wsl-clients/smoke_xray_sub.sh
```

## What is asserted

### `smoke_mihomo_sub.sh`

1. Fetch Clash YAML
2. `name: AUTO`, `type: url-test`
3. `MATCH,DIRECT` present; no residual `MATCH,PROXY`
4. `DOMAIN,arcane.$WEBDOMAIN,PROXY`
5. Optional: `mihomo -t -f …`
6. Optional: short mixed-port run + curl via PROXY to `https://arcane.$WEBDOMAIN:9443/` expecting `401`

### `smoke_xray_sub.sh`

1. Fetch JSON subscription
2. First document: admin domain → `proxy` (or balancer), then first `network` rule → `direct`
3. AUTO / balancer document: `leastPing` balancer when present
4. Optional: `xray run -test -c …` on AUTO (or first) config
