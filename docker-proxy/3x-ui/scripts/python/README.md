# 3x-ui Python runtime (`xui_runtime`)

Primary AfterStart engine (`XUI_RUNTIME_ENGINE=python`, default). The thin launcher
`01_AfterStart/3x-ui-upd.sh` execs `python3 -m xui_runtime --mode check|plan|apply`.
Emergency rollback: `XUI_RUNTIME_ENGINE=bash` (libs under `scripts/lib/`). Dual-engine
mode is retired.

## Layout

| Path | Role |
|------|------|
| `xui_runtime/env.py` | Env load/normalize; `resolve_afterstart_dir` / `resolve_xui_env_path` |
| `xui_runtime/http_client.py` / `api.py` | Panel HTTP + API |
| `xui_runtime/desired.py` + `builders/` | Desired state builders |
| `xui_runtime/apply/` | Panel, Xray, sub balancer/routing |
| `xui_runtime/apply/inbound/` | Inbound package (`ensure`, `clients`, `amneziawg`, `db_repair`); import path unchanged |
| `xui_runtime/main.py` | Orchestrator (bash `main()` order) |
| `xui_runtime/parity.py` | Offline builder parity CLI (dev-only; AfterStart does not call it) |

Stdlib only — no pip / `cryptography`. Crypto via `xray` / `openssl` subprocess.

## Env discovery

Container mounts: `/mnt/sh/afterstart`, `/mnt/sh/python`, `/mnt/sh/lib`. Compose
`env_file` injects `3x-ui.env`; file lookup still tries host
`scripts/../../3x-ui.env` and package-adjacent `3x-ui/3x-ui.env`.

`cli()` uses `resolve_afterstart_dir()` so direct `python3 -m xui_runtime` prefers
`/mnt/sh/afterstart` over a non-existent `.../01_AfterStart` under `/mnt/sh`.

## Deterministic IDs

When `CLIENT_SUB_ID` is unset: `sha256(f"{WEBDOMAIN or 'localhost'}:{shared_email}")[:16]`
via `env.deterministic_sub_id`. MODE `check` / `plan` reuse the same env loading and IDs as `apply`.

## Tests

```bash
bash tests/3x-ui-scripts/run.sh
# or focused:
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest discover -s tests/3x-ui-scripts/python -v
```
