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

## XHTTP env knobs

Defaults are applied in `env.init_defaults`; invalid combinations fail in all modes
(`check` / `plan` / `apply`) via `validate_xhttp_env` before panel login.

| Env | Default | Rollout step |
|-----|---------|--------------|
| `XHTTP_MODE` | `packet-up` | 1 → `auto` (optional `stream-up`) |
| `XHTTP_SC_MAX_BUFFERED_POSTS` | `50` | 2 / 5 |
| `XHTTP_SC_MAX_EACH_POST_BYTES` | `5000000` | 2 / 5 |
| `XHTTP_SC_STREAM_UP_SERVER_SECS` | `5-20` | 2 / 5 |
| `XHTTP_X_PADDING_BYTES` | `100-1000` | 2 / 5 |
| `XHTTP_NO_SSE_HEADER` | `true` | 2 / 5 A/B → `false` |
| `XHTTP_SET_HOST` | `true` | 2 |
| `XHTTP_HEADERS_UA` | empty | 8 → `firefox` \| `edge` \| `golang` |
| `XHTTP_CLIENT_EXTRA_ENABLE` | `false` | 3 → `true` |
| `XHTTP_XMUX_MAX_CONCURRENCY` | `16-32` | 3 (client `extra` only) |
| `XHTTP_XMUX_H_MAX_REQUEST_TIMES` | `600-900` | 3 |
| `XHTTP_XMUX_H_MAX_REUSABLE_SECS` | `1800-3000` | 3 |
| `ENABLE_VLESS_GRPC` | `false` | 4 |
| `VLESS_GRPC_WHEN_DISABLED` | `disable` | 4 (`disable` \| `leave` \| `delete`) |

Step **0** = code sync with all defaults (current live shape). Design:
`docs/superpowers/specs/2026-11-17-xhttp-improvements-design.md`.

## AmneziaWG env knobs (`AWG_*`)

Defaults are applied in `env.init_defaults`; invalid combinations fail in all modes
(`check` / `plan` / `apply`) via `validate_awg_env` before panel login. Managed
server settings are built in `builders/awg_settings.py` (compare-first sync).

Live rollout order (one knob or documented sub-flip per step; fresh client profile
after obfuscation changes): design
`docs/superpowers/specs/2026-11-17-awg-improvements-design.md`, operator checklist
`docs/superpowers/plans/2026-11-17-awg-improvements.md` Task 6.

| Env | Default | Rollout step |
|-----|---------|--------------|
| `AWG_MTU` | `1280` | 0; `auto` (Step 6) resolves via `resolve_awg_mtu` in `[1280,1420]` |
| `AWG_MTU_OVERHEAD` | `96` | 6 (with `AWG_MTU=auto`) |
| `AWG_HOST_MTU` | empty | 6 (preferred Path MTU when `auto`) |
| `AWG_S1`...`AWG_S4` | `16` each | 0 (equal when `AWG_RANDOM_TRAILERS=true`) |
| `AWG_H1`...`AWG_H4` | `1`...`4` | 0 (fixed under header protection; do not tune live) |
| `AWG_JC` | `4` | 4 optional (`4..12`) |
| `AWG_JMIN` / `AWG_JMAX` | `50` / `120` | 0 (`Jmin <= Jmax`) |
| `AWG_CONTENT_PADDING` | `0-16` | 5 (`0-32` / `8-32`) |
| `AWG_KEEPALIVE_TIMEOUT` | `9-17` | 0 |
| `AWG_REKEY_AFTER_TIME` | empty (omit) | 3 |
| `AWG_REKEY_TIMEOUT` | empty (omit) | 3 |
| `AWG_REJECT_AFTER_TIME` | empty (omit) | 3 |
| `AWG_MAX_HANDSHAKE_ATTEMPTS` | empty (omit) | 3 |
| `AWG_RANDOM_TRAILERS` | `true` | 0 |
| `AWG_DISABLE_COOKIES` | `false` | 5 optional (DoS trade-off) |
| `AWG_I1`...`AWG_I5` | `I1=<r 55>`, others empty | 4 unique CPS; empty omits packet |
| `AWG_I1_MTU_HEADROOM` | `120` | 4 (`estimate_cps_bytes(I1) + headroom <= MTU`) |
| `AWG_DNS1` / `AWG_DNS2` | `8.8.8.8` / `8.8.4.4` | 5 optional |
| `AWG_CLIENT_KEEPALIVE` | `25` | 0 (panel client hygiene) |

Step **0** = code sync; defaults match prior managed AWG shape. Step **1** = full
managed compare (no env flip). Step **2** = validation wired (fail-fast on bad env).
Clash export of `I1`-`I5` is verified on live Step 4 only; do not assume a GAP until
then.

## Tests

```bash
bash tests/3x-ui-scripts/run.sh
# or focused:
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest discover -s tests/3x-ui-scripts/python -v
```
