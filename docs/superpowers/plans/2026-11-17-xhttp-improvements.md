# XHTTP Improvements (Streambase Staged Rollout) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship env-driven XHTTP server settings, compare-first managed projection, optional client `extra`, and reversible gRPC disable — with safe defaults matching current behavior, then flip one Streambase env flag at a time with auto subscription smoke after each flip.

**Architecture:** Keep flat server `xhttpSettings` (no server-side `extra` key). Read knobs from env in `build_xhttp_stream_json` / `sanitize_xhttp_stream_json`. Canonicalize `sc*` / padding / bools before compare so panel string/number drift does not churn. Build client `extra` separately and deliver only via a verified subscription channel (JSON first; Clash may GAP). When `ENABLE_VLESS_GRPC=false`, apply `VLESS_GRPC_WHEN_DISABLED=disable` via `inbounds/setEnable/{id}`.

**Tech Stack:** Python 3 stdlib (`unittest`, `json`), existing `xui_runtime` package, panel API Bearer/session, local `tests/3x-ui-scripts/run.sh` / `python -m unittest`, Streambase sync + AfterStart apply.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-17-xhttp-improvements-design.md` (operator-approved).
- Approach C: code defaults = current live shape; behavior changes only via env flips on Streambase.
- No Traefik H3 / Finalmask / `443/udp` changes (AWG/HY2 owns UDP 443).
- Server inbound must not contain `xhttpSettings.extra`.
- Do not enable `mux.cool` on XHTTP.
- Do not default-delete gRPC inbound (`VLESS_GRPC_WHEN_DISABLED=disable`).
- Stdlib-only Python; ASCII spaces only (no NBSP).
- Do not push remotes; sync/mutate Streambase only when the operator asks for a live step.
- Emergency bash parity for new XHTTP env knobs is out of scope unless a task explicitly says otherwise.
- One live env flip → one apply → operator auto smoke → next flip.
- `validate_xhttp_env` runs after `init_defaults` for `check` / `plan` / `apply` (fail before panel HTTP).
- `sanitize_xhttp_stream_json` always `pop("extra")` from server `xhttpSettings` after managed merge.
- `set_inbound_enable`: try `setEnable` (JSON, then form); on HTTP 404 fall back to full `inbounds/update/{id}`.

## File map

| File | Responsibility |
|------|----------------|
| `docker-proxy/3x-ui/scripts/python/xui_runtime/env.py` | Default + validate new `XHTTP_*` / `VLESS_GRPC_WHEN_DISABLED` |
| `docker-proxy/3x-ui/3x-ui.env` | Documented defaults (comments); no behavior change at Step 0 |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py` | Env-driven `build_xhttp_stream_json`; `build_xhttp_client_extra_json`; canonicalize helpers |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/ensure.py` | `sanitize_xhttp_stream_json` managed projection; find/disable helpers reuse |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/clients.py` | XHTTP stream compare via canonicalize before `json_equal` |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/xhttp_extra.py` | (new) subscription delivery for client `extra` / GAP |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/api.py` | `set_inbound_enable(id, enable: bool)` |
| `docker-proxy/3x-ui/scripts/python/xui_runtime/main.py` | Call gRPC when-disabled + optional extra ensure |
| `tests/3x-ui-scripts/python/test_env.py` | Default/validation tests |
| `tests/3x-ui-scripts/python/test_builders.py` | Default XHTTP parity + mode/extra helpers |
| `tests/3x-ui-scripts/python/test_xhttp_settings.py` | (new) canonicalize + sanitize + compare |
| `tests/3x-ui-scripts/python/test_grpc_disable.py` | (new) when-disabled policy |
| `tests/3x-ui-scripts/python/test_xhttp_extra.py` | (new) extra builder + delivery/GAP |
| `docker-proxy/3x-ui/scripts/python/README.md` | Short env knob notes |
| `.project_context/02_state/` | Live step evidence + Clash GAP if any |

---

### Task 1: Env defaults and validation

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/env.py`
- Modify: `docker-proxy/3x-ui/3x-ui.env`
- Modify: `tests/3x-ui-scripts/python/test_env.py`
- Test: `tests/3x-ui-scripts/python/test_env.py`

**Interfaces:**
- Consumes: existing `init_defaults(env)` / `_set_default`
- Produces:
  - defaults: `XHTTP_MODE=packet-up`, `XHTTP_SC_MAX_BUFFERED_POSTS=50`, `XHTTP_SC_MAX_EACH_POST_BYTES=5000000`, `XHTTP_SC_STREAM_UP_SERVER_SECS=5-20`, `XHTTP_X_PADDING_BYTES=100-1000`, `XHTTP_NO_SSE_HEADER=true`, `XHTTP_SET_HOST=true`, `XHTTP_HEADERS_UA=` (empty), `XHTTP_CLIENT_EXTRA_ENABLE=false`, `XHTTP_XMUX_MAX_CONCURRENCY=16-32`, `XHTTP_XMUX_H_MAX_REQUEST_TIMES=600-900`, `XHTTP_XMUX_H_MAX_REUSABLE_SECS=1800-3000`, `VLESS_GRPC_WHEN_DISABLED=disable`
  - `validate_xhttp_env(env: Mapping[str, str]) -> None` raises `ValueError` on unknown mode/UA/policy

- [ ] **Step 1: Write the failing tests**

Add to `test_env.py`:

```python
def test_xhttp_defaults_match_current_live_shape(self) -> None:
    env: dict[str, str] = {"WEBDOMAIN": "example.test"}
    init_defaults(env)
    self.assertEqual(env.get("XHTTP_MODE"), "packet-up")
    self.assertEqual(env.get("XHTTP_SC_MAX_BUFFERED_POSTS"), "50")
    self.assertEqual(env.get("XHTTP_SC_MAX_EACH_POST_BYTES"), "5000000")
    self.assertEqual(env.get("XHTTP_SC_STREAM_UP_SERVER_SECS"), "5-20")
    self.assertEqual(env.get("XHTTP_X_PADDING_BYTES"), "100-1000")
    self.assertEqual(env.get("XHTTP_NO_SSE_HEADER"), "true")
    self.assertEqual(env.get("XHTTP_SET_HOST"), "true")
    self.assertEqual(env.get("XHTTP_HEADERS_UA"), "")
    self.assertEqual(env.get("XHTTP_CLIENT_EXTRA_ENABLE"), "false")
    self.assertEqual(env.get("VLESS_GRPC_WHEN_DISABLED"), "disable")

def test_validate_xhttp_env_rejects_bad_mode(self) -> None:
    with self.assertRaises(ValueError):
        validate_xhttp_env({"XHTTP_MODE": "nope"})

def test_validate_xhttp_env_accepts_auto(self) -> None:
    validate_xhttp_env(
        {
            "XHTTP_MODE": "auto",
            "XHTTP_HEADERS_UA": "",
            "VLESS_GRPC_WHEN_DISABLED": "disable",
        }
    )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PYTHONPATH=docker-proxy/3x-ui/scripts/python python -m unittest tests.3x-ui-scripts.python.test_env.TestEnvDefaults.test_xhttp_defaults_match_current_live_shape -v`  
(or discover path used on this repo: `cd` repo root and `python -m unittest tests.3x-ui-scripts.python.test_env -v` after adjusting import style to match existing tests)

Expected: FAIL (missing defaults / `validate_xhttp_env` not defined)

- [ ] **Step 3: Implement defaults + validator**

In `env.py` inside `init_defaults`:

```python
_set_default(env, "XHTTP_MODE", "packet-up")
_set_default(env, "XHTTP_SC_MAX_BUFFERED_POSTS", "50")
_set_default(env, "XHTTP_SC_MAX_EACH_POST_BYTES", "5000000")
_set_default(env, "XHTTP_SC_STREAM_UP_SERVER_SECS", "5-20")
_set_default(env, "XHTTP_X_PADDING_BYTES", "100-1000")
_set_default(env, "XHTTP_NO_SSE_HEADER", "true")
_set_default(env, "XHTTP_SET_HOST", "true")
_set_default(env, "XHTTP_HEADERS_UA", "")
_set_default(env, "XHTTP_CLIENT_EXTRA_ENABLE", "false")
_set_default(env, "XHTTP_XMUX_MAX_CONCURRENCY", "16-32")
_set_default(env, "XHTTP_XMUX_H_MAX_REQUEST_TIMES", "600-900")
_set_default(env, "XHTTP_XMUX_H_MAX_REUSABLE_SECS", "1800-3000")
_set_default(env, "VLESS_GRPC_WHEN_DISABLED", "disable")
```

Add:

```python
_XHTTP_MODES = frozenset({"auto", "packet-up", "stream-up", "stream-one"})
_XHTTP_UAS = frozenset({"", "firefox", "edge", "golang"})
_GRPC_WHEN_DISABLED = frozenset({"disable", "leave", "delete"})

def validate_xhttp_env(env: Mapping[str, str]) -> None:
    mode = (env.get("XHTTP_MODE") or "packet-up").strip()
    if mode not in _XHTTP_MODES:
        raise ValueError(f"XHTTP_MODE invalid: {mode}")
    ua = (env.get("XHTTP_HEADERS_UA") or "").strip().lower()
    if ua not in _XHTTP_UAS:
        raise ValueError(f"XHTTP_HEADERS_UA invalid: {ua}")
    policy = (env.get("VLESS_GRPC_WHEN_DISABLED") or "disable").strip()
    if policy not in _GRPC_WHEN_DISABLED:
        raise ValueError(f"VLESS_GRPC_WHEN_DISABLED invalid: {policy}")
```

Wire note (Task 1 defines the function; Task 7 installs the call site): `validate_xhttp_env(env)` must run **immediately after `init_defaults` for every MODE** (`check`, `plan`, `apply`), before any panel HTTP. A typo in `XHTTP_MODE` / `VLESS_GRPC_WHEN_DISABLED` / UA must fail `MODE=check` the same way as `apply`.

Add commented keys to `3x-ui.env` near `ENABLE_VLESS_GRPC` (values via defaults; do not force live flips).

- [ ] **Step 4: Run tests to verify they pass**

Run: `PYTHONPATH=docker-proxy/3x-ui/scripts/python python -m unittest discover -s tests/3x-ui-scripts/python -p 'test_env.py' -v`  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/env.py docker-proxy/3x-ui/3x-ui.env tests/3x-ui-scripts/python/test_env.py
git commit -m "feat(3x-ui): add XHTTP env defaults and validation"
```

---

### Task 2: Builder + sanitize project `mode` from env (Step 1 code)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/ensure.py` (`sanitize_xhttp_stream_json`)
- Modify: `tests/3x-ui-scripts/python/test_builders.py`
- Create or modify: `tests/3x-ui-scripts/python/test_xhttp_settings.py`
- Test: `tests/3x-ui-scripts/python/test_xhttp_settings.py`, `test_builders.py`

**Interfaces:**
- Consumes: `env["XHTTP_MODE"]`, `env["XHTTP_SET_HOST"]`
- Produces: `build_xhttp_stream_json(..., env=)` sets `xhttpSettings.mode` from env (default `packet-up`); `sanitize_xhttp_stream_json` always sets `mode` from env; omits/clears `host` when `XHTTP_SET_HOST` is false

- [ ] **Step 1: Write the failing tests**

```python
from xui_runtime.builders.streams import build_xhttp_stream_json
from xui_runtime.apply.inbound.ensure import sanitize_xhttp_stream_json

def test_build_xhttp_default_mode_packet_up(self) -> None:
    obj = build_xhttp_stream_json("/xhttp", "example.test", env={})
    self.assertEqual(obj["xhttpSettings"]["mode"], "packet-up")
    self.assertNotIn("extra", obj["xhttpSettings"])

def test_build_xhttp_mode_from_env_auto(self) -> None:
    obj = build_xhttp_stream_json(
        "/xhttp", "example.test", env={"XHTTP_MODE": "auto"}
    )
    self.assertEqual(obj["xhttpSettings"]["mode"], "auto")

def test_sanitize_xhttp_updates_mode_only_from_env(self) -> None:
    stream = {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {"path": "/old", "host": "old.test", "mode": "packet-up"},
    }
    out = sanitize_xhttp_stream_json(
        stream, "/xhttp", "example.test", {"XHTTP_MODE": "auto", "XHTTP_SET_HOST": "true"}
    )
    self.assertEqual(out["xhttpSettings"]["mode"], "auto")
    self.assertEqual(out["xhttpSettings"]["path"], "/xhttp")
    self.assertEqual(out["xhttpSettings"]["host"], "example.test")
```

Keep existing `test_xhttp_stream` parity: fixture must still match default `packet-up` (already expected).

- [ ] **Step 2: Run tests to verify they fail**

Run: `PYTHONPATH=docker-proxy/3x-ui/scripts/python python -m unittest discover -s tests/3x-ui-scripts/python -p 'test_xhttp_settings.py' -v`  
Expected: FAIL (mode still hard-coded / sanitize ignores mode)

- [ ] **Step 3: Minimal implementation**

In `build_xhttp_stream_json`:

```python
env = env or {}
mode = (env.get("XHTTP_MODE") or "packet-up").strip() or "packet-up"
set_host = (env.get("XHTTP_SET_HOST") or "true").strip().lower() in ("1", "true", "yes", "on")
xhttp: dict[str, Any] = {
    "path": path,
    # existing sc*/headers/padding defaults unchanged in this task
    "mode": mode,
}
if set_host:
    xhttp["host"] = host
# ... rest of current fields ...
```

In `sanitize_xhttp_stream_json`, after copying `xhttpSettings`:

```python
mode = (env.get("XHTTP_MODE") or "packet-up").strip() or "packet-up"
xhttp["mode"] = mode
xhttp["path"] = path
if (env.get("XHTTP_SET_HOST") or "true").strip().lower() in ("1", "true", "yes", "on"):
    xhttp["host"] = host
else:
    xhttp.pop("host", None)
```

Do **not** yet rewrite `sc*` / padding / headers in sanitize (Task 3).

- [ ] **Step 4: Run tests to verify they pass**

Run builders + new tests + existing `test_xhttp_stream`.  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/ensure.py \
  tests/3x-ui-scripts/python/test_xhttp_settings.py \
  tests/3x-ui-scripts/python/test_builders.py
git commit -m "feat(3x-ui): drive XHTTP mode from env in builder and sanitize"
```

---

### Task 3: Canonicalize + managed `sc*` / padding / headers projection (Step 2 code)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/ensure.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/clients.py` (`ensure_vless_stream`)
- Modify: `tests/3x-ui-scripts/python/test_xhttp_settings.py`
- Test: `tests/3x-ui-scripts/python/test_xhttp_settings.py`

**Interfaces:**
- Consumes: Task 1 env keys; Task 2 sanitize/builder
- Produces:
  - `canonicalize_xhttp_settings(settings: Mapping[str, Any]) -> dict[str, Any]`
  - `apply_managed_xhttp_settings(xhttp: dict, env, path, host) -> dict` used by builder + sanitize
  - `xhttp_stream_equal(left_stream, right_stream) -> bool` for ensure path
  - Builder/sanitize set: `scMaxBufferedPosts`, `scMaxEachPostBytes`, `scStreamUpServerSecs`, `xPaddingBytes`, `noSSEHeader`, managed headers (Cache-Control / CORS + optional UA)

- [ ] **Step 1: Write the failing tests**

```python
def test_canonicalize_sc_int_and_str_equal(self) -> None:
    a = canonicalize_xhttp_settings({"scMaxBufferedPosts": 50, "scMaxEachPostBytes": 5000000})
    b = canonicalize_xhttp_settings({"scMaxBufferedPosts": "50", "scMaxEachPostBytes": "5000000"})
    self.assertEqual(a["scMaxBufferedPosts"], b["scMaxBufferedPosts"])
    self.assertEqual(a["scMaxEachPostBytes"], b["scMaxEachPostBytes"])

def test_sanitize_applies_sc_and_padding_from_env(self) -> None:
    env = {
        "XHTTP_MODE": "packet-up",
        "XHTTP_SET_HOST": "true",
        "XHTTP_SC_MAX_BUFFERED_POSTS": "50",
        "XHTTP_SC_MAX_EACH_POST_BYTES": "500000-1000000",
        "XHTTP_SC_STREAM_UP_SERVER_SECS": "5-20",
        "XHTTP_X_PADDING_BYTES": "100-1000",
        "XHTTP_NO_SSE_HEADER": "true",
        "XHTTP_HEADERS_UA": "",
    }
    stream = {"network": "xhttp", "security": "tls", "xhttpSettings": {"mode": "stream-up"}}
    out = sanitize_xhttp_stream_json(stream, "/xhttp", "example.test", env)
    self.assertEqual(out["security"], "none")
    self.assertEqual(out["xhttpSettings"]["scMaxEachPostBytes"], "500000-1000000")
    self.assertNotIn("extra", out["xhttpSettings"])

def test_xhttp_stream_equal_ignores_sc_type_noise(self) -> None:
    left = {"network": "xhttp", "security": "none", "xhttpSettings": {"mode": "auto", "scMaxBufferedPosts": 50}}
    right = {"network": "xhttp", "security": "none", "xhttpSettings": {"mode": "auto", "scMaxBufferedPosts": "50"}}
    self.assertTrue(xhttp_stream_equal(left, right))
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL (helpers missing / sanitize not projecting sc*)

- [ ] **Step 3: Implement helpers + wire sanitize/builder/compare**

```python
def _env_bool(env: Mapping[str, str], key: str, default: bool = False) -> bool:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return str(raw).strip().lower() in ("1", "true", "yes", "on")

def canonicalize_xhttp_settings(settings: Mapping[str, Any]) -> dict[str, Any]:
    out = dict(settings)
    for key in (
        "scMaxBufferedPosts",
        "scMaxEachPostBytes",
        "scStreamUpServerSecs",
        "xPaddingBytes",
    ):
        if key in out and out[key] is not None:
            out[key] = str(out[key]).strip()
    if "noSSEHeader" in out:
        val = out["noSSEHeader"]
        if isinstance(val, str):
            out["noSSEHeader"] = val.strip().lower() in ("1", "true", "yes", "on")
        else:
            out["noSSEHeader"] = bool(val)
    return out

def managed_xhttp_headers(env: Mapping[str, str]) -> dict[str, str]:
    headers = {
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST",
    }
    ua = (env.get("XHTTP_HEADERS_UA") or "").strip().lower()
    if ua:
        headers["User-Agent"] = ua
    return headers

def apply_managed_xhttp_settings(
    path: str,
    host: str,
    env: Mapping[str, str],
) -> dict[str, Any]:
    mode = (env.get("XHTTP_MODE") or "packet-up").strip() or "packet-up"
    buffered = (env.get("XHTTP_SC_MAX_BUFFERED_POSTS") or "50").strip()
    each_post = (env.get("XHTTP_SC_MAX_EACH_POST_BYTES") or "5000000").strip()
    stream_secs = (env.get("XHTTP_SC_STREAM_UP_SERVER_SECS") or "5-20").strip()
    padding = (env.get("XHTTP_X_PADDING_BYTES") or "100-1000").strip()
    xhttp: dict[str, Any] = {
        "path": path,
        "mode": mode,
        "headers": managed_xhttp_headers(env),
        "scMaxBufferedPosts": int(buffered) if buffered.isdigit() else buffered,
        "scMaxEachPostBytes": each_post,
        "scStreamUpServerSecs": stream_secs,
        "noSSEHeader": _env_bool(env, "XHTTP_NO_SSE_HEADER", True),
        "xPaddingBytes": padding,
    }
    if _env_bool(env, "XHTTP_SET_HOST", True):
        xhttp["host"] = host
    return xhttp
```

`sanitize_xhttp_stream_json`: merge managed fields onto the existing `xhttpSettings` dict, then **always** strip a stray server-side `extra`:

```python
xhttp = dict(sanitized.get("xhttpSettings") or {})
managed = apply_managed_xhttp_settings(path, host, env)
xhttp.update(managed)
xhttp.pop("extra", None)  # panel may have stored client extra on inbound; never send to Xray server
sanitized["xhttpSettings"] = xhttp
```

Unit test must assert: inbound stream that arrived with `"extra": {...}` leaves sanitize **without** `extra`. Keep sockopt trusted XFF + externalProxy TLS sanitize as today.

`build_xhttp_stream_json`: build `xhttpSettings` via `apply_managed_xhttp_settings` (no `extra` key).

In `ensure_vless_stream`, when `kind == "xhttp"`:

```python
if kind == "xhttp":
    if xhttp_stream_equal(components.get("streamSettings") or {}, desired_stream):
        log.log("INFO", f"{label} stream already matches desired state.")
        return
else:
    if json_equal(components, desired_components):
        ...
```

Where `xhttp_stream_equal` deep-compares streams after running `canonicalize_xhttp_settings` on both `xhttpSettings` objects and uses existing `json_equal` for the rest of the stream object.

- [ ] **Step 4: Run tests**

Run: `PYTHONPATH=docker-proxy/3x-ui/scripts/python python -m unittest discover -s tests/3x-ui-scripts/python -p 'test_xhttp_settings.py' -v`  
Also run `test_builders.py` and `test_apply_inbound.py`.  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/ensure.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/clients.py \
  tests/3x-ui-scripts/python/test_xhttp_settings.py
git commit -m "feat(3x-ui): manage and canonicalize XHTTP sc/padding/headers"
```

---

### Task 4: Client `extra` builder (no delivery yet)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/builders/__init__.py` (export)
- Create: `tests/3x-ui-scripts/python/test_xhttp_extra.py`
- Test: `tests/3x-ui-scripts/python/test_xhttp_extra.py`

**Interfaces:**
- Consumes: xmux env keys; optional `XHTTP_HEADERS_UA`
- Produces: `build_xhttp_client_extra_json(env: Mapping[str, str]) -> dict[str, Any]` — never used as server inbound `extra`

- [ ] **Step 1: Write the failing test**

```python
def test_client_extra_xmux_shape(self) -> None:
    extra = build_xhttp_client_extra_json(
        {
            "XHTTP_X_PADDING_BYTES": "100-1000",
            "XHTTP_XMUX_MAX_CONCURRENCY": "16-32",
            "XHTTP_XMUX_H_MAX_REQUEST_TIMES": "600-900",
            "XHTTP_XMUX_H_MAX_REUSABLE_SECS": "1800-3000",
            "XHTTP_HEADERS_UA": "",
        }
    )
    self.assertEqual(extra["xPaddingBytes"], "100-1000")
    self.assertEqual(extra["xmux"]["maxConcurrency"], "16-32")
    self.assertEqual(extra["xmux"]["maxConnections"], 0)
    self.assertNotIn("headers", extra)

def test_client_extra_includes_ua_when_set(self) -> None:
    extra = build_xhttp_client_extra_json({"XHTTP_HEADERS_UA": "firefox"})
    self.assertEqual(extra["headers"]["User-Agent"], "firefox")
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL (`build_xhttp_client_extra_json` missing)

- [ ] **Step 3: Implement**

```python
def build_xhttp_client_extra_json(env: Mapping[str, str]) -> dict[str, Any]:
    extra: dict[str, Any] = {
        "xPaddingBytes": (env.get("XHTTP_X_PADDING_BYTES") or "100-1000").strip(),
        "xmux": {
            "maxConcurrency": (env.get("XHTTP_XMUX_MAX_CONCURRENCY") or "16-32").strip(),
            "maxConnections": 0,
            "cMaxReuseTimes": 0,
            "hMaxRequestTimes": (env.get("XHTTP_XMUX_H_MAX_REQUEST_TIMES") or "600-900").strip(),
            "hMaxReusableSecs": (env.get("XHTTP_XMUX_H_MAX_REUSABLE_SECS") or "1800-3000").strip(),
            "hKeepAlivePeriod": 0,
        },
    }
    ua = (env.get("XHTTP_HEADERS_UA") or "").strip().lower()
    if ua:
        extra["headers"] = {"User-Agent": ua}
    return extra
```

Assert in a unit test that `build_xhttp_stream_json(... )["xhttpSettings"]` still has no `extra` key when client helper is used separately.

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/builders/streams.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/builders/__init__.py \
  tests/3x-ui-scripts/python/test_xhttp_extra.py
git commit -m "feat(3x-ui): add XHTTP client extra builder"
```

---

### Task 5: Panel `setEnable` + gRPC when-disabled policy (Step 4 code)

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/api.py`
- Create: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/grpc_policy.py` (or functions in `ensure.py` if small)
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/main.py`
- Create: `tests/3x-ui-scripts/python/test_grpc_disable.py`
- Test: `tests/3x-ui-scripts/python/test_grpc_disable.py`

**Interfaces:**
- Consumes: `PanelApi`, `desired`, `find_inbound_by_port` / `managed_inbound_remarks`, `plan_or_apply`
- Produces:
  - `PanelApi.set_inbound_enable(inbound_id: int | str, enable: bool) -> HttpResult` — see fallback contract below
  - `ensure_grpc_when_disabled(desired, api, env, mode, stats) -> None`

**`set_inbound_enable` contract (version-tolerant):**

1. Try `POST /panel/api/inbounds/setEnable/{id}` with JSON `{"enable": bool}` first.
2. If the panel wants form-encoded on that route, retry once as form `enable=true|false` (same path).
3. On **HTTP 404** (route missing on this panel build), fallback like legacy settings dual-path: `GET` inbound, set `enable`, `POST /panel/api/inbounds/update/{id}` with the full inbound object (do not invent partial updates that drop clients).
4. Unit-test the 404 → update fallback with a mock session.

- [ ] **Step 1: Write the failing tests**

```python
def test_disable_policy_calls_set_enable_false(self) -> None:
    # mock list_inbounds returns managed grpc id=9 enable=True
    # ENABLE_VLESS_GRPC=false, VLESS_GRPC_WHEN_DISABLED=disable
    ensure_grpc_when_disabled(desired, api, env, "apply", stats)
    api.set_inbound_enable.assert_called_once_with("9", False)
    self.assertEqual(stats.change_count, 1)

def test_leave_policy_does_not_set_enable(self) -> None:
    env["VLESS_GRPC_WHEN_DISABLED"] = "leave"
    ensure_grpc_when_disabled(desired, api, env, "apply", stats)
    api.set_inbound_enable.assert_not_called()
    api.del_inbound.assert_not_called()

def test_already_disabled_is_noop(self) -> None:
    # grpc enable=False
    ensure_grpc_when_disabled(...)
    api.set_inbound_enable.assert_not_called()
    self.assertEqual(stats.change_count, 0)

def test_delete_policy_uses_delete_managed(self) -> None:
    env["VLESS_GRPC_WHEN_DISABLED"] = "delete"
    # assert delete path invoked once (mock delete_managed_inbound_kind or del_inbound)
```

- [ ] **Step 2: Run tests — expect FAIL**

- [ ] **Step 3: Implement API + policy**

```python
# api.py — sketch; match existing api_post / api_post_json helpers
def set_inbound_enable(self, inbound_id: int | str, enable: bool) -> HttpResult:
    path = f"/panel/api/inbounds/setEnable/{inbound_id}"
    result = self.api_post_json(path, {"enable": bool(enable)})
    if result.code == "404":
        # Panel build without setEnable: full-row update fallback
        get = self.get_inbound(inbound_id)
        if not get.ok or not self.session.success_json():
            return get
        obj = api_obj_json(self.session)  # or equivalent
        obj["enable"] = bool(enable)
        return self.update_inbound(inbound_id, obj)
    # If setEnable exists but rejects JSON, one form-encoded retry before treating as failure
    if not self.session.success_json():
        form = self.api_post(path, [("enable", "true" if enable else "false")])
        if form.ok and self.session.success_json():
            return form
    return result
```

Add a unit test: first `setEnable` returns 404 → assert `update_inbound` called with `enable=False` and clients preserved.

```python
def ensure_grpc_when_disabled(...):
    if (env.get("ENABLE_VLESS_GRPC") or "false").strip().lower() == "true":
        return
    policy = (env.get("VLESS_GRPC_WHEN_DISABLED") or "disable").strip()
    if policy == "leave":
        return
    if policy == "delete":
        delete_managed_inbound_kind("grpc", desired, api, mode, stats)
        return
    # disable
    # locate managed grpc inbound; if missing → INFO return
    # if enable already false → INFO return
    # plan_or_apply(...); api.set_inbound_enable(id, False)
```

Wire in `main.py` after the `ENABLE_VLESS_GRPC` create branch (always call when false):

```python
if env.get("ENABLE_VLESS_GRPC", "false") == "true":
    grpc_id = ensure_inbound("grpc", ...) or ""
else:
    grpc_id = ""
    ensure_grpc_when_disabled(desired, api, env, mode, stats)
```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/api.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/grpc_policy.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/main.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/apply/inbound/__init__.py \
  tests/3x-ui-scripts/python/test_grpc_disable.py
git commit -m "feat(3x-ui): disable managed gRPC inbound when flag is false"
```

---

### Task 6: Client `extra` subscription delivery + GAP (Step 3 code)

**Files:**
- Create: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/xhttp_extra.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/main.py`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/apply/panel.py` only if writing `subJsonFragment`
- Modify: `tests/3x-ui-scripts/python/test_xhttp_extra.py`
- Test: `tests/3x-ui-scripts/python/test_xhttp_extra.py`

**Interfaces:**
- Consumes: `build_xhttp_client_extra_json`, panel settings update helpers, `XHTTP_CLIENT_EXTRA_ENABLE`
- Produces: `ensure_xhttp_client_extra(api, env, mode, stats) -> str`  
  return value one of: `applied` | `noop` | `gap`  
  On `gap`: log WARN with reason; do **not** leave enable semantically “success” without delivery — if enable true and delivery impossible, set outcome `gap` and leave panel unchanged (operator must set enable false or fix channel)

**Delivery algorithm (locked by spec):**

1. If `XHTTP_CLIENT_EXTRA_ENABLE` is false → noop (optionally clear a previously written managed marker from `subJsonFragment` if present).
2. If true → prefer a channel that lands in **JSON** sub `outbounds[].streamSettings.xhttpSettings.extra`.
3. Probe order for implementer on Streambase (read-only first):
   - Inspect one JSON subscription document for an existing XHTTP outbound shape.
   - Check whether panel exposes an inbound/UI field for XHTTP extra (Hosts is **not** primary).
   - If only `subJsonFragment` can inject: write a minimal documented fragment **only after** a dry-run shows it appears under XHTTP `extra` (not blindly globally).
4. If no channel works → return `gap`, log, do not invent Clash-only hacks; record GAP in `.project_context/02_state/current_gaps.md` during live Step 3.

- [ ] **Step 1: Write failing unit tests for enable false / gap / applied**

```python
def test_extra_disabled_is_noop(self) -> None:
    stats = ApplyStats()
    outcome = ensure_xhttp_client_extra(api, {"XHTTP_CLIENT_EXTRA_ENABLE": "false"}, "apply", stats)
    self.assertEqual(outcome, "noop")
    self.assertEqual(stats.change_count, 0)

def test_extra_enabled_without_channel_returns_gap(self) -> None:
    # force delivery backend = none
    outcome = ensure_xhttp_client_extra(api, {"XHTTP_CLIENT_EXTRA_ENABLE": "true"}, "apply", stats)
    self.assertEqual(outcome, "gap")
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement module with pluggable delivery**

```python
def ensure_xhttp_client_extra(...) -> str:
    enabled = (env.get("XHTTP_CLIENT_EXTRA_ENABLE") or "false").strip().lower() in ("1", "true", "yes", "on")
    if not enabled:
        return "noop"
    extra = build_xhttp_client_extra_json(env)
    # Try registered delivery backends; if none succeed → gap
    ...
```

Keep server inbound free of `extra` (assert in test).

Wire `ensure_xhttp_client_extra` in `main.py` after panel settings / before or after inbound sync (after XHTTP inbound exists is fine; delivery is subscription-side).

- [ ] **Step 4: Run unit tests — PASS**

- [ ] **Step 5: Commit**

```bash
git add docker-proxy/3x-ui/scripts/python/xui_runtime/apply/xhttp_extra.py \
  docker-proxy/3x-ui/scripts/python/xui_runtime/main.py \
  tests/3x-ui-scripts/python/test_xhttp_extra.py \
  .project_context/02_state/current_gaps.md
git commit -m "feat(3x-ui): add XHTTP client extra delivery with explicit GAP"
```

---

### Task 7: Docs touch + validate_xhttp_env for all MODEs

**Files:**
- Modify: `docker-proxy/3x-ui/scripts/python/README.md`
- Modify: `docker-proxy/3x-ui/scripts/python/xui_runtime/main.py` (validate after `init_defaults` for **check / plan / apply**)
- Modify: `docs/superpowers/specs/2026-11-17-xhttp-improvements-design.md` status → `approved`
- Optional: `.agents/skill/3x-ui/references/3x-ui-runtime.md` one short XHTTP env bullet
- Test: re-run `test_env.py` + full python discover

- [ ] **Step 1: Add README knobs table** (defaults, Step mapping 0/1/2/3/4/5/8)

- [ ] **Step 2: Wire `validate_xhttp_env(env)` in `main` immediately after `init_defaults`, on the shared path used by `check`, `plan`, and `apply` (not only inside the apply branch). On `ValueError`: log ERROR and return 1 **before** panel login / HTTP.**

- [ ] **Step 3: Run**

`PYTHONPATH=docker-proxy/3x-ui/scripts/python python -m unittest discover -s tests/3x-ui-scripts/python -v`  
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -f docs/superpowers/specs/2026-11-17-xhttp-improvements-design.md
git add docker-proxy/3x-ui/scripts/python/README.md \
  docker-proxy/3x-ui/scripts/python/xui_runtime/main.py \
  .agents/skill/3x-ui/references/3x-ui-runtime.md
git commit -m "docs(3x-ui): document XHTTP env knobs and mark design approved"
```

---

### Task 8: Streambase rollout (operator-gated, one flag at a time)

**Files:**
- Sync target: `/opt/docker-proxy/3x-ui/scripts/python/`
- Env: Streambase `3x-ui.env` / compose env
- Evidence: `.project_context/02_state/last_changes.md` (+ gaps if Step 3 GAP)

**Interfaces:**
- Consumes: Tasks 1–7 code on branch; SSH/sync method already used for this host
- Produces: per-step PASS notes; stop on auto fail

- [ ] **Step 0: Sync code with defaults only; backup tag `streambase-xhttp-…`; AfterStart apply twice → `changes≈0`; operator auto smoke PASS**

- [ ] **Step 1: Set `XHTTP_MODE=auto`; apply twice; JSON shows mode auto; auto smoke PASS**  
  Rollback: `XHTTP_MODE=packet-up`

- [ ] **Step 2: Confirm managed sc*/padding projection (no env change if defaults already applied); two applies no XHTTP churn; auto smoke PASS**

- [ ] **Step 3: Set `XHTTP_CLIENT_EXTRA_ENABLE=true` only after delivery channel verified; fetch JSON for `extra.xmux`; Clash missing `extra` = GAP not FAIL; auto smoke PASS**  
  If GAP: set enable back to `false`, document, continue to Step 4

- [ ] **Step 4: Ensure `ENABLE_VLESS_GRPC=false` + policy `disable`; gRPC `enable=false`; absent from AUTO ids; auto smoke PASS**  
  Rollback: `ENABLE_VLESS_GRPC=true`

- [ ] **Step 5: Flip `XHTTP_SC_MAX_EACH_POST_BYTES` to agreed range (default candidate `500000-1000000`); optional `XHTTP_NO_SSE_HEADER=false` as separate sub-flip; auto smoke each**

- [ ] **Step 8: Set `XHTTP_HEADERS_UA=firefox` (or `edge`); apply; auto smoke PASS**

- [ ] **Step final: Update `.project_context` state; commit evidence docs if appropriate (no push unless asked)**

Do not batch env flips. Do not enable H3.

---

## Spec coverage self-review

| Spec item | Task |
|-----------|------|
| Approach C safe defaults | Task 1, Task 8 Step 0 |
| Step 1 mode-only then Step 2 rest | Task 2 then Task 3 |
| Compare canonicalize sc*/padding/bool | Task 3 |
| Server flat / no server `extra` | Tasks 2–4 tests |
| Client `extra` + Clash GAP rule | Tasks 4, 6, 8 Step 3 |
| gRPC `disable` not delete | Task 5, Task 8 Step 4 |
| UA Step 8 | Task 3 headers + Task 8 Step 8 |
| No H3 / 443/udp | Global constraints + Task 8 |
| Per-flag rollback / auto smoke | Task 8 |
| `validate` fail-fast on check/plan/apply | Tasks 1, 7 |
| Strip stray server `extra` on sanitize | Task 3 |
| `setEnable` 404 → update fallback | Task 5 |

## Placeholder scan

No TBD steps; Step 5 exact range remains the spec's open item and is decided during Task 8 Step 5 after Steps 1–2 smoke (candidate recorded). Delivery backend for Task 6 is algorithmically specified with an explicit `gap` outcome rather than a vague “implement later”.

## Type consistency

- `build_xhttp_client_extra_json(env) -> dict[str, Any]`
- `canonicalize_xhttp_settings` / `apply_managed_xhttp_settings` / `xhttp_stream_equal`
- `ensure_xhttp_client_extra(...) -> str` in `{applied, noop, gap}`
- `ensure_grpc_when_disabled(...)`
- `PanelApi.set_inbound_enable(id, enable: bool)`
- Env names match the spec table exactly
