# AfterStart Python Idempotency Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive Python AfterStart `MODE=apply` toward a second consecutive run with no spurious `changes` (target `changes=0` or a short documented residual list), starting with the sub-balancer false positive, then panel/VLESS compare noise, then SQLite repair hardening.

**Architecture:** Keep the thin launcher and `XUI_RUNTIME_ENGINE=python|bash` contract. Fix compare-before-mutate ordering and managed-field projections inside existing apply modules. Mirror the sub-balancer ordering fix in bash emergency path. Defer `inbound.py` package split until streambase proves idempotency.

**Tech Stack:** Python 3 stdlib (`unittest`, `sqlite3`, `json`), existing `xui_runtime` package, bash emergency libs, local `tests/3x-ui-scripts/run.sh`.

## Global Constraints

- Stdlib-only Python; no pip / `cryptography`.
- Do not re-enable `XUI_RUNTIME_ENGINE=dual`.
- Do not delete emergency bash AfterStart libs in this plan.
- `MODE=check` / `MODE=plan` must not mutate `x-ui.db` (no INSERT/UPDATE/DELETE).
- ASCII spaces only (no NBSP).
- Do not push or live-sync unless the operator explicitly asks.
- Split `apply/inbound.py` only after Task 3 acceptance (idempotency evidence).
- Spec: `docs/superpowers/specs/2026-11-16-xui-runtime-python-review-design.md`.

## File map

| File | Responsibility |
|------|----------------|
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/sub_balancer.py` | Compare AUTO balancer first; call `plan_or_apply` only when create/update needed |
| `docker-proxy/3x-ui/scripts/lib/sub_balancer.bash` | Same ordering for emergency bash |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/panel.py` | Canonical panel string compare with `rstrip("\n")`; rename misleading `desired` param to `stats` |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound.py` | Managed-key projection for VLESS client compare; sqlite checkpoint after successful repair writes |
| `tests/3x-ui-scripts/python/test_sub_balancer.py` | Plan/noop change_count expectations |
| `tests/3x-ui-scripts/python/test_apply_panel.py` | Trailing-newline equality |
| `tests/3x-ui-scripts/python/test_apply_inbound.py` / `test_apply_inbound_db.py` | Client projection + checkpoint behavior |
| `tests/3x-ui-scripts/test_libs.bash` | Bash sub_balancer already-matches does not count a change (if covered) |

---

### Task 1: Sub balancer — compare before `plan_or_apply`

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/sub_balancer.py`
- Modify: `docker-proxy/3x-ui/scripts/lib/sub_balancer.bash`
- Modify: `tests/3x-ui-scripts/python/test_sub_balancer.py`
- Test: `tests/3x-ui-scripts/python/test_sub_balancer.py`

**Interfaces:**
- Consumes: `PanelApi.list_sub_balancers` / `add_sub_balancer` / `update_sub_balancer`, `ApplyStats`, `plan_or_apply(mode, stats, message) -> bool`
- Produces: `ensure_auto_sub_balancer(...)` that increments `stats.change_count` only when create or update is planned/applied

- [ ] **Step 1: Write the failing tests**

Update `TestEnsureAutoSubBalancer` so noop asserts zero changes, and plan mode lists before deciding:

```python
def test_noop_when_matches(self) -> None:
    body = json.dumps(
        {
            "success": True,
            "obj": [
                {
                    "id": 3,
                    "remark": "AUTO-example.test",
                    "strategy": "leastPing",
                    "enabled": True,
                    "inboundIds": [1, 2],
                }
            ],
        }
    )
    api = self._mock_api(body)
    stats = ApplyStats()
    ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "apply", stats, "1", "2")
    api.list_sub_balancers.assert_called_once()
    api.add_sub_balancer.assert_not_called()
    api.update_sub_balancer.assert_not_called()
    self.assertEqual(stats.change_count, 0)

def test_plan_mode_reports_create_without_mutating(self) -> None:
    api = self._mock_api(json.dumps({"success": True, "obj": []}))
    stats = ApplyStats()
    ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "plan", stats, "1", "2")
    api.list_sub_balancers.assert_called_once()
    api.add_sub_balancer.assert_not_called()
    api.update_sub_balancer.assert_not_called()
    self.assertEqual(stats.change_count, 1)

def test_plan_mode_noop_when_matches(self) -> None:
    body = json.dumps(
        {
            "success": True,
            "obj": [
                {
                    "id": 3,
                    "remark": "AUTO-example.test",
                    "strategy": "leastPing",
                    "enabled": True,
                    "inboundIds": [1, 2],
                }
            ],
        }
    )
    api = self._mock_api(body)
    stats = ApplyStats()
    ensure_auto_sub_balancer(api, {"WEBDOMAIN": "example.test"}, "plan", stats, "1", "2")
    api.list_sub_balancers.assert_called_once()
    api.add_sub_balancer.assert_not_called()
    api.update_sub_balancer.assert_not_called()
    self.assertEqual(stats.change_count, 0)
```

Remove or rewrite the old `test_plan_mode_skips_api` (it expected `list` never called and always `change_count=1`).

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cd /mnt/y/3x-ui_pro_Docker
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_sub_balancer.TestEnsureAutoSubBalancer -v
```

Expected: `test_noop_when_matches` fails on `change_count` (got 1), and new plan tests fail under current early-`plan_or_apply` behavior.

- [ ] **Step 3: Fix Python `ensure_auto_sub_balancer`**

In `apply/sub_balancer.py`, delete the early:

```python
if not plan_or_apply(mode, stats, f"{remark} sub balancer ensured inboundIds={ids_csv}"):
    return
```

Flow becomes:

1. Validate `remark` / inbound ids (unchanged early returns).
2. `list_sub_balancers` (+ JSON parse / WARN paths unchanged).
3. If missing → `if not plan_or_apply(... created ...): return` then `add_sub_balancer`.
4. If present and matches → log already matches; **return with no `plan_or_apply`**.
5. If present and differs → `if not plan_or_apply(... updated ...): return` then `update_sub_balancer`.

Keep message text informative (`created` / `updated` / or retain `ensured` only on mutating paths). Prefer distinct messages:

- `f"{remark} sub balancer created inboundIds={ids_csv}"`
- `f"{remark} sub balancer updated inboundIds={ids_csv}"`

- [ ] **Step 4: Mirror the same order in bash `sub_balancer.bash`**

Move `plan_or_apply` from before `xui_list_sub_balancers` to the create and update branches only (after the already-matches return). Keep soft-WARN success behavior.

- [ ] **Step 5: Re-run focused Python tests**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_sub_balancer -v
```

Expected: OK.

- [ ] **Step 6: Commit**

```bash
git add \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/sub_balancer.py \
  docker-proxy/3x-ui/scripts/lib/sub_balancer.bash \
  tests/3x-ui-scripts/python/test_sub_balancer.py
git commit -m "$(cat <<'EOF'
fix(3x-ui): count sub balancer changes only when mutating

Compare AUTO balancer state before plan_or_apply so matching apply/plan runs stay at changes=0.
EOF
)"
```

---

### Task 2: Panel settings — strip trailing newlines in compare

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/panel.py`
- Modify: `tests/3x-ui-scripts/python/test_apply_panel.py`

**Interfaces:**
- Consumes: `panel_desired_json`, `panel_current_managed_json`, `json_equal`
- Produces: string projection that treats `"rules\n"` and `"rules"` as equal for managed keys (esp. `subClashRules`)

- [ ] **Step 1: Write the failing test**

```python
def test_trailing_newline_does_not_force_panel_update(self) -> None:
    current = {
        **_panel_fixture(),
        "subClashRules": "hosts:\n  example.test: 1.2.3.4\n",
        "panelOutbound": "direct",
    }
    env = {"subClashRules": "hosts:\n  example.test: 1.2.3.4"}
    desired = panel_desired_json(current, env)
    projected = panel_current_managed_json(current)
    self.assertEqual(desired["subClashRules"], projected["subClashRules"])
```

- [ ] **Step 2: Run test to verify it fails**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_apply_panel.TestPanelJsonHelpers.test_trailing_newline_does_not_force_panel_update -v
```

Expected: FAIL (strings differ by trailing `\n`).

- [ ] **Step 3: Normalize in `_value_as_compare_string`**

```python
def _value_as_compare_string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    return str(value).rstrip("\n")
```

Also rename `ensure_panel_settings(..., desired: ApplyStats, ...)` parameter to `stats: ApplyStats` and update the body/`plan_or_apply` call sites in that function.

- [ ] **Step 4: Run panel tests**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_apply_panel -v
```

Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/panel.py \
  tests/3x-ui-scripts/python/test_apply_panel.py
git commit -m "$(cat <<'EOF'
fix(3x-ui): ignore trailing newlines in panel settings compare

Keep subClashRules and other managed string fields idempotent across YAML/Clash renderers.
EOF
)"
```

---

### Task 3: VLESS inbound client — managed-key projection

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound.py`
- Modify: `tests/3x-ui-scripts/python/test_apply_inbound.py`

**Interfaces:**
- Consumes: current inbound `settings.clients[]`, desired shared client id/email/subId/flow
- Produces: compare helper that ignores empty panel defaults (`password`/`auth`/`decryption` when empty) and only diffs managed fields

- [ ] **Step 1: Add helpers + failing test**

Add (near `vless_client_api_json`):

```python
_MANAGED_VLESS_CLIENT_KEYS = (
    "id",
    "uuid",
    "email",
    "subId",
    "flow",
    "enable",
    "limitIp",
    "totalGB",
    "expiryTime",
    "tgId",
)

def _normalize_empty_default(value: Any) -> Any:
    if value is None:
        return ""
    return value

def managed_vless_client_projection(client: Mapping[str, Any]) -> dict[str, Any]:
    """Project fields AfterStart owns; drop empty panel defaults that cause churn."""
    out: dict[str, Any] = {}
    for key in _MANAGED_VLESS_CLIENT_KEYS:
        if key in client:
            out[key] = client.get(key)
    # Include password/auth only when non-empty so panel "" defaults do not force rewrites.
    for key in ("password", "auth"):
        raw = _normalize_empty_default(client.get(key))
        if str(raw).strip() != "":
            out[key] = raw
    if "uuid" not in out and "id" in out:
        out["uuid"] = out["id"]
    if "id" not in out and "uuid" in out:
        out["id"] = out["uuid"]
    out["tgId"] = _normalize_tg_id(out.get("tgId", 0))
    return out
```

Test idea (adapt to existing fixtures/mocks in `test_apply_inbound.py`):

```python
def test_managed_vless_projection_ignores_empty_password_auth(self) -> None:
    from xui_runtime.apply.inbound import managed_vless_client_projection

    current = {
        "id": "11111111-1111-1111-1111-111111111111",
        "uuid": "11111111-1111-1111-1111-111111111111",
        "email": "a@example.test",
        "subId": "deadbeefcafebabe",
        "flow": "xtls-rprx-vision",
        "password": "",
        "auth": "",
        "enable": True,
        "tgId": 0,
    }
    desired = {
        "id": "11111111-1111-1111-1111-111111111111",
        "uuid": "11111111-1111-1111-1111-111111111111",
        "email": "a@example.test",
        "subId": "deadbeefcafebabe",
        "flow": "xtls-rprx-vision",
        "password": "",
        "auth": "",
        "enable": True,
        "tgId": 0,
    }
    self.assertEqual(
        managed_vless_client_projection(current),
        managed_vless_client_projection(desired),
    )
```

- [ ] **Step 2: Run test (projection helper missing → FAIL)**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_apply_inbound -v
```

- [ ] **Step 3: Use projection inside `ensure_vless_inbound_client`**

Replace full `json_equal(current_settings, desired_settings)` with a clients-aware compare:

1. Build `desired_settings` as today (still write full client objects on real updates).
2. For equality, compare:
   - non-client settings keys via `json_equal` after dropping `clients`
   - clients via sorted managed projections for emails AfterStart owns (shared + legacy), and identity for foreign clients (or compare foreign clients unchanged).

Minimal safe approach matching the spec: when checking whether to update, project each client in both lists with `managed_vless_client_projection` and `json_equal` those lists (order by email), plus compare `decryption`/`encryption` and other non-client settings.

Do **not** generate fresh `new_client_secret()` for compare when secrets are empty and the existing inbound client already has empty/`password`/`auth` — prefer existing inbound client password/auth when building the desired client for comparison if `secrets` lacks non-empty values.

- [ ] **Step 4: Run inbound + full python suite slice**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_apply_inbound \
  tests.3x-ui-scripts.python.test_apply_inbound_db -v
```

Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound.py \
  tests/3x-ui-scripts/python/test_apply_inbound.py
git commit -m "$(cat <<'EOF'
fix(3x-ui): compare VLESS clients on managed fields only

Ignore empty panel password/auth defaults so inbound client sync stops rewriting every apply.
EOF
)"
```

---

### Task 4: SQLite repair — checkpoint after write; keep before panel restart

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound.py`
- Modify: `tests/3x-ui-scripts/python/test_apply_inbound_db.py`
- Verify order in: `docker-proxy/3x-ui/scripts/python/xui_runtime/main.py`

**Interfaces:**
- Consumes: `sqlite3.connect(..., timeout=10.0)`, existing `pragma busy_timeout=5000`
- Produces: after successful mutating repair, `PRAGMA wal_checkpoint(TRUNCATE)`; repair remains before `restart_panel_if_needed`

- [ ] **Step 1: Confirm pipeline order**

In `main.py`, `repair_inbound_client_tg_ids_db` already runs before inbound mutations and before `restart_panel_if_needed`. Keep that. `repair_shared_client_db` / flow repair stay in apply path before final panel restart. Do not move repairs after panel restart.

- [ ] **Step 2: Write failing test for checkpoint**

Prefer a small helper:

```python
def _sqlite_commit_with_checkpoint(con: sqlite3.Connection) -> None:
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
```

Test with tempfile DB that repair changes a row and does not raise; optionally spy/monkeypatch `Connection.execute` to assert checkpoint pragma was issued after a successful update.

- [ ] **Step 3: Implement helper and use it in**

- `repair_shared_client_db`
- `repair_inbound_client_tg_ids_db`
- `repair_inbound_vless_client_flows_db`

Only call checkpoint when a write actually happened (or always after successful `commit` of a repair function that performed updates — prefer “only if `changed` / update executed”).

Keep retries on `sqlite3.Error` for shared client repair. Log WARN on final failure unchanged.

- [ ] **Step 4: Run DB tests + compile**

```bash
PYTHONPATH=docker-proxy/3x-ui/scripts/python python3 -m unittest \
  tests.3x-ui-scripts.python.test_apply_inbound_db -v
python3 -m compileall -q docker-proxy/3x-ui/scripts/python
```

Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound.py \
  tests/3x-ui-scripts/python/test_apply_inbound_db.py
git commit -m "$(cat <<'EOF'
fix(3x-ui): checkpoint sqlite WAL after successful repair writes

Flush repair updates before panel restart so x-ui reloads disk state cleanly.
EOF
)"
```

---

### Task 5: Local full suite + project context note

**Files:**
- Modify: `.project_context/02_state/last_changes.md` (gitignored OK if present)
- Modify: `.project_context/02_state/local_verification.md` (gitignored OK)
- Optional skill touch: `references/3x-ui-runtime.md` only if compare rules need a one-liner

- [ ] **Step 1: Run full local suite**

```bash
cd /mnt/y/3x-ui_pro_Docker
bash tests/3x-ui-scripts/run.sh
git diff --check
```

Expected: exit 0; Python 111+ OK.

- [ ] **Step 2: Record verification note**

Append to local project context: Tasks 1–4 done; remaining residual changes (if any) listed; streambase re-proof still operator-gated.

- [ ] **Step 3: Commit any tracked test/docs leftovers**

Only tracked paths (not `.project_context/`).

---

### Task 6 (optional, gated): Split `apply/inbound.py` after streambase `changes≈0`

**Do not start until** operator confirms a second consecutive streambase `MODE=apply` with no spurious changes (or an agreed residual list).

**Files:**
- Create: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/__init__.py`
- Create: `.../ensure.py`, `clients.py`, `amneziawg.py`, `db_repair.py`
- Delete/replace: monolithic `apply/inbound.py` (keep import path `xui_runtime.apply.inbound`)
- Test: existing `tests/3x-ui-scripts/python/test_apply_inbound*.py` must pass without import edits if re-exports are complete

- [ ] **Step 1: Move code behind package re-exports**
- [ ] **Step 2: Full unittest discover**
- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor(3x-ui): split inbound apply into package modules

Keep public re-exports so unit tests and main imports stay stable after idempotency.
EOF
)"
```

---

### Task 7 (operator-gated): Streambase proof

**Only when operator asks for live sync/proof.**

- [ ] Sync scripts (not whole unrelated tree) to streambase.
- [ ] `MODE=plan` then two `MODE=apply` cycles; capture `changes=` lines.
- [ ] Confirm no spurious AUTO balancer change; list any residual changes.
- [ ] Update `.project_context/03_verification/server_verification.md` with evidence paths.

---

## Spec coverage checklist

| Spec item | Task |
|-----------|------|
| #1 sub balancer plan_or_apply after compare | Task 1 |
| #2 panel `rstrip("\n")` | Task 2 |
| #2 VLESS empty password/auth / managed projection | Task 3 |
| #2 AWG residual | investigate during Task 5/7 if changes remain |
| #3 sqlite checkpoint + before panel restart | Task 4 |
| #5 inbound split after changes=0 | Task 6 (gated) |
| Push/sync only on request | Task 7 (gated) |
| Nice #6 rename panel param | Task 2 |
| No dual / keep bash emergency | Global constraints |

## Placeholder / consistency self-check

- No TBD steps; commands and expected outcomes listed.
- `plan_or_apply(mode, stats, message)` signature consistent across tasks.
- Public import path `xui_runtime.apply.inbound` preserved through optional split.
