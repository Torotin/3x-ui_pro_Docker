# Design: AfterStart Python runtime — post-migration review

Date: 2026-11-16  
Status: approved (brainstorming, scope D = architecture + plan compliance + severity)  
Branch: `refactor/xui-runtime-python` (tip includes Task 15 `1a90f9b`)  
Primary tree: [`docker-proxy/3x-ui/scripts/python/xui_runtime/`](../../../docker-proxy/3x-ui/scripts/python/xui_runtime/)  
Launcher: [`docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh`](../../../docker-proxy/3x-ui/scripts/01_AfterStart/3x-ui-upd.sh)  
Plan (historical): Cursor plan `python_runtime_strangler_2af8b038`

## Goal

Record a full review of the strangler migration (Tasks 0–15) so follow-up work has an agreed severity list, plan-compliance gaps, and fix order — without reopening locked migration decisions.

## Non-goals

- Re-introducing `XUI_RUNTIME_ENGINE=dual`
- Migrating BeforeStart to Python in this epic
- Deleting emergency bash AfterStart libs in this pass
- Pushing/syncing to hosts without an explicit operator request
- Installer `script/` changes

## Review method

Combined format agreed in brainstorming:

1. Layer walkthrough (launcher → env/http/api → desired/builders → apply → tests → rollout)
2. Plan compliance matrix (locked decisions + Tasks 0–15)
3. Severity register (Critical / Important / Nice) with fix priority

## Architecture summary

| Layer | Verdict |
|-------|---------|
| Thin launcher | Default `python` → `exec python3 -m xui_runtime`; bash libs lazy-loaded for emergency `bash` only; `dual` rejected |
| Foundation (`env`, `http_client`, `api`, `crypto_cmd`) | Clear boundaries; stdlib + `subprocess` for `xray`/`openssl` |
| `desired` / `builders` | Separated from apply; Vision dual TLS fingerprints addressed |
| `apply/*` + `main` | Pipeline mirrors bash; `apply/inbound.py` ~1470 lines is oversized |
| `parity.py` | Still present as offline CLI; AfterStart no longer invokes it after Task 15 |
| Compose | Mount `../3x-ui/scripts/python:/mnt/sh/python:ro` in `12-3x-ui.yml` |
| BeforeStart | Remains bash (follow-up epic) |

End-state achieved for AfterStart primary path: Python. Emergency bash kept for rollback without restoring image/scripts from backup.

## Plan compliance

| Decision / criterion | Status |
|----------------------|--------|
| Scope = 3x-ui scripts + image only | pass |
| Stdlib-only; no pip / `cryptography` | pass |
| Crypto via `xray` / `openssl` subprocess | pass |
| Atomic `engine=python` (no partial apply) | pass |
| `MODE=check` / `plan` must not mutate `x-ui.db` | pass (`repair_*` gated on `apply`) |
| Dual builders → cutover → retire dual | pass |
| Default python + emergency bash | pass |
| BeforeStart stays bash | pass |
| Local unittest + bash suite green | pass (~111 Python + `tests/3x-ui-scripts/run.sh`) |
| Streambase backup + mutation proof | pass (Task 13; backup `streambase-py-runtime-20261116125015`) |
| Branch pushed / upstream tracking | gap — no upstream on `refactor/xui-runtime-python` |
| Task 15 soak ≥7 days | drift — operator early retirement same day as cutover |
| Nearly pure Python / no dual maintenance | partial — dual removed; bash emergency + `parity.py` + large `inbound.py` remain |
| Idempotent apply | gap — streambase observed non-zero `changes` every run |

## Severity register

### Critical

None for “Python is already primary on streambase.” Rollback remains `XUI_RUNTIME_ENGINE=bash` or restore backup `streambase-py-runtime-*`.

### Important

1. **Sub balancer counts a change before compare** — `ensure_auto_sub_balancer` calls `plan_or_apply` before the “already matches” check, so every `MODE=apply` increments `change_count` even when the AUTO balancer is unchanged. Ported from the same order in bash `sub_balancer.bash`.
2. **Non-idempotent Python apply** — streambase saw ~`changes=8` per run. Besides (1), likely contributors: panel settings string/`subClashRules` compare noise; VLESS inbound client sync injecting `password`/`auth` into desired client JSON; AWG profile sync edges.
3. **SQLite repair vs panel lock** — `repair_*_db` on apply can WARN `database locked` while the panel holds `x-ui.db`; operators still need `PRAGMA wal_checkpoint(FULL)` before trusting bind-mount reads.
4. **Branch not pushed** — Task 15 commit is local-only until operator asks to push/sync.
5. **`inbound.py` size (~1470 lines)** — create/stream/client/AWG/sqlite in one module; future edits are high-risk.

### Nice / debt

6. `ensure_panel_settings` parameter named `desired` but typed/used as `ApplyStats` (actually `stats`).
7. `parity.py` leftover after dual retirement — keep as offline tool; document as dev-only.
8. Early soak — document operator-approved same-day retirement as the soak criterion used.
9. Bash emergency libs + bash AfterStart tests — retain until a dedicated “delete bash AfterStart” epic.
10. Python `select_tls_fingerprint()` defaults to `random` (bash used `RANDOM`); live sanitize preserves an existing allowed fingerprint, so apply sync is fine; offline parity against a freshly built bash stream may differ.

## Recommended fix order

1. Move `plan_or_apply` in `ensure_auto_sub_balancer` to after the already-matches check (and mirror the same fix in bash for emergency parity).
2. Drive remaining idempotency: panel compare, VLESS client field noise, AWG sync — prove with a second apply `changes=0` (or documented residual).
3. Soften sqlite repair under lock (retry/backoff already partial; avoid noisy false urgency; document WAL checkpoint).
4. Optional split of `inbound.py` after idempotency is green.
5. Push/sync branch and streambase scripts only on explicit request.

## Success criteria for follow-up plan

- Second consecutive `MODE=apply` on a stable streambase reports no spurious sub-balancer change.
- Documented residual change sources (if any) are intentional and listed.
- Spec and skill refs state: default `python`, emergency `bash`, `dual` retired, soak criterion = operator early retire 2026-11-16.
- No Critical findings introduced by the fix pass.

## Out of scope reminders

- Do not delete emergency bash path in the idempotency fix pass.
- Do not re-enable dual.
- Do not expand to non-streambase hosts without a separate rollout task.
