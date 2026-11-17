# Design: XHTTP improvements (Streambase staged rollout)

Date: 2026-11-17  
Status: approved  
Branch: `refactor/xui-runtime-python` (baseline commit before this work: `3777fa4`)  
Primary tree: [`docker-proxy/3x-ui/scripts/python/xui_runtime/`](../../../docker-proxy/3x-ui/scripts/python/xui_runtime/)  
Live canary: Streambase (`WEBDOMAIN` / subscription **auto**)  
Official sources: [XHTTP transport](https://xtls.github.io/en/config/transports/xhttp.html), [XHTTP: Beyond REALITY #4113](https://github.com/XTLS/Xray-core/discussions/4113), [extra sharing PR #4000](https://github.com/XTLS/Xray-core/pull/4000)

## Goal

Improve managed VLESS+XHTTP behind Traefik TLS (`security=none` on backend) with env-driven knobs, compare-first managed projection, optional client `extra` for subscriptions, and clean reversible gRPC disable on Streambase — without changing default live behavior until each env flag is flipped and smoke-tested.

## Non-goals

- Traefik / edge HTTP/3 or Finalmask `quicParams` (item 7 dropped: public `443/udp` is AWG/HY2; prior H3 attempts were high-risk)
- `downloadSettings` uplink/downlink split
- Replacing Vision REALITY with XHTTP
- Enabling `mux.cool` on XHTTP
- Deleting the gRPC inbound by default
- Pushing remotes or mutating non-Streambase hosts without an explicit ask
- Installer `script/` changes in this pass

## Approach (locked): C

1. Ship code with **safe defaults equal to current behavior**.
2. Sync once; Step 0 baseline smoke on subscription **auto**.
3. Flip **one env flag at a time** on Streambase; after each flip: apply → verify → operator client smoke on **auto**.
4. Rollback of any step is restoring **one** env value (plus gRPC re-enable on next apply if needed) — no code redeploy required for behavior rollback.

## Section 1 — Live step order

| Step | Change on Streambase | Expectation |
|------|----------------------|-------------|
| 0 | Code sync; all new env defaults = current behavior | auto baseline PASS |
| 1 | `XHTTP_MODE=auto` (optional later `stream-up`) | XHTTP in auto works |
| 2 | Managed sync for remaining `xhttpSettings` keys | `changes≈0` on re-apply; auto PASS |
| 3 | `XHTTP_CLIENT_EXTRA_ENABLE=true` (xmux + mode delivery) | JSON has `extra`; Clash checked separately |
| 4 | gRPC off + remove from AUTO (`VLESS_GRPC_WHEN_DISABLED=disable`) | auto without gRPC |
| 5 | Tune `sc*` ranges / `noSSEHeader` A/B | auto PASS |
| 8 | `XHTTP_HEADERS_UA=firefox` (or `edge`) | auto PASS |

### Step 1 vs 2 (ordering contract)

- **Step 1:** `build_xhttp_stream_json` and `sanitize_xhttp_stream_json` read `XHTTP_MODE` and project **`mode` only** (plus existing path/host/security/XFF). Builder default remains `packet-up` so Step 0 is a no-op for clients.
- **Step 2:** extend managed projection to `scMaxBufferedPosts`, `scMaxEachPostBytes`, `scStreamUpServerSecs`, `xPaddingBytes`, `noSSEHeader`, and managed `headers` (including UA when set).

### Step 3 vs 4 (isolation)

Keep client `extra` (Step 3) and gRPC/AUTO membership (Step 4) separate so Mihomo/v2rayN/Happ failures can be attributed to XHTTP `extra` mutation vs AUTO selector rebuild.

## Section 2 — Env, xhttpSettings, client extra, gRPC

### Server vs client (official)

- **Server inbound:** flat `xhttpSettings` (`host`, `path`, `mode`, `sc*`, `xPaddingBytes`, `noSSEHeader`, `headers`). Do **not** put an `extra` key on the server object (when `extra` is present, Xray treats only `host`/`path`/`mode`/`extra` as effective).
- **Client share:** `host`, `path`, `mode`, `extra`. Put xmux / client headers / shared padding policy inside `extra`.

### Env defaults (Step 0 = current live shape)

| Env | Default | Live flip |
|-----|---------|-----------|
| `XHTTP_MODE` | `packet-up` | Step 1 → `auto` (then optional `stream-up`) |
| `XHTTP_SC_MAX_BUFFERED_POSTS` | `50` | Step 5 |
| `XHTTP_SC_MAX_EACH_POST_BYTES` | `5000000` | Step 5 → range e.g. `500000-1000000` |
| `XHTTP_SC_STREAM_UP_SERVER_SECS` | `5-20` | Step 5 if needed |
| `XHTTP_X_PADDING_BYTES` | `100-1000` | Step 5 |
| `XHTTP_NO_SSE_HEADER` | `true` | Step 5 A/B → `false` |
| `XHTTP_SET_HOST` | `true` | opt-out of setting `host` to `WEBDOMAIN` |
| `XHTTP_HEADERS_UA` | empty | Step 8 → `firefox` \| `edge` \| `golang` |
| `XHTTP_CLIENT_EXTRA_ENABLE` | `false` | Step 3 → `true` |
| `XHTTP_XMUX_MAX_CONCURRENCY` | `16-32` | client `extra` only |
| `XHTTP_XMUX_H_MAX_REQUEST_TIMES` | `600-900` | client `extra` only |
| `XHTTP_XMUX_H_MAX_REUSABLE_SECS` | `1800-3000` | client `extra` only |
| `ENABLE_VLESS_GRPC` | `false` | Step 4: ensure `false` on Streambase |
| `VLESS_GRPC_WHEN_DISABLED` | `disable` | `disable` \| `leave` \| `delete` |

Out of scope env: H3 ALPN, `downloadSettings`, Finalmask.

### Compare-first normalization (Step 2 accent)

Panel/API may return `scMaxBufferedPosts` as `"50"` or `50`; range forms of `scMaxEachPostBytes` / `xPaddingBytes` / `scStreamUpServerSecs` are strings. Before equality:

- canonicalize all managed `sc*` and `xPaddingBytes` with `str(val).strip()`;
- canonicalize `noSSEHeader` to bool;
- compare managed `headers` on a defined key set only.

Otherwise every apply falsely reports XHTTP stream churn.

### Client `extra` template (Step 3)

```json
{
  "xPaddingBytes": "100-1000",
  "xmux": {
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "cMaxReuseTimes": 0,
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000",
    "hKeepAlivePeriod": 0
  }
}
```

Optional `headers.User-Agent` only when `XHTTP_HEADERS_UA` is set (typically Step 8).

### Delivery into subscriptions (Step 3 accent)

Priority:

1. Mechanism that actually lands in JSON subscription outbound `xhttpSettings.extra`.
2. Fallback: `subJsonFragment` (or equivalent panel setting) if verified on live panel.
3. Hosts API is **not** the primary channel for XHTTP `extra` (address/TLS overrides, not the extra blob).
4. Do not extend legacy `externalProxy` for `extra`.

**Clash/Mihomo caveat:** 3x-ui Clash YAML often does **not** forward full `xhttpSettings.extra` (unlike raw JSON). Step 3 PASS requires JSON delivery **or** an explicit documented GAP; absence of `extra` in Clash YAML alone is not a regression if JSON works and auto still passes. Do not leave `XHTTP_CLIENT_EXTRA_ENABLE=true` “silently on” with no delivery path.

### gRPC when `ENABLE_VLESS_GRPC=false` (Step 4)

Existing behavior: skip `ensure_inbound("grpc")` / `ensure_grpc_client`; empty `grpc_id` drops gRPC from AUTO balancer.

Add `VLESS_GRPC_WHEN_DISABLED`:

| Value | Behavior |
|-------|----------|
| `disable` (default, Streambase) | if managed gRPC inbound exists → `setEnable(false)`; stays out of AUTO; row kept for rollback |
| `leave` | do not create/sync; may leave an enabled orphan |
| `delete` | `delete_managed_inbound_kind("grpc")` only when explicitly requested |

Do not change Traefik gRPC labels, `443/udp`, or AWG/HY2.

## Section 3 — Errors, rollback, verification

### Principles

- One live flag → one apply → one auto smoke; next flag only after PASS or explicit skip.
- Behavior rollback = one env value (+ gRPC re-enable on next apply). Code with safe defaults stays.
- Never default-delete gRPC; never touch H3 / `443/udp`.
- Soft-fail paths (geofile / WARP / usque) remain non-blocking for these steps.

### Error handling by layer

| Layer | Failure | Behavior |
|-------|---------|----------|
| Builder / env | unknown `XHTTP_MODE`, `VLESS_GRPC_WHEN_DISABLED`, or UA | fail fast (ERROR, non-zero); do not write inbound |
| Sanitize / inbound update | panel API failure | existing `InboundApplyError` / WARN+skip where soft; do not flip next env |
| Managed compare | unmanaged key drift | ignore; managed mismatch → single update |
| Client `extra` | Clash omits `extra`, JSON has it | not Clash FAIL; record GAP; use fragment or keep extra JSON-only |
| gRPC disable | inbound missing | INFO no-op |
| gRPC disable | `setEnable` fails | WARN; Step 4 FAIL; do not escalate to delete |
| Listen / Traefik | XHTTP port down after mode flip | WARN from port wait; rollback `XHTTP_MODE` |
| Client smoke | auto degrades | stop pipeline; rollback last flag |

### Rollback table (Streambase)

| Step | Rollback |
|------|----------|
| 0 | git revert only if synced code breaks apply |
| 1 | `XHTTP_MODE=packet-up` → apply |
| 2 | keep code; fix normalize if false diffs |
| 3 | `XHTTP_CLIENT_EXTRA_ENABLE=false` (+ clear fragment if written) |
| 4 | `ENABLE_VLESS_GRPC=true` → apply (re-enable + balancer); row intact under `disable` |
| 5 | restore previous `sc*` / SSE env strings |
| 8 | `XHTTP_HEADERS_UA=` empty |

Before each live step: short env/DB backup tag (pattern `streambase-…`), not a full stack wipe.

### Verification

**Local (before sync):**

- unit: builder reads env; default matches current packet-up shape;
- unit: sanitize/compare treats `"50"` and `50` equal; range strings equal;
- unit: client `extra` shape; server inbound has no `extra` key;
- unit: `ENABLE_VLESS_GRPC=false` + `disable` takes disable path, not delete;
- existing inbound/python tests + `git diff --check`.

**Streambase after each flag:**

1. Sync python runtime → AfterStart apply.
2. Log shows expected change set; second apply → `changes≈0`.
3. Sub URLs HTTP 200 (STD / JSON / Clash).
4. JSON XHTTP node: expected `mode`; from Step 3, `extra.xmux` if enable delivered.
5. Clash/Mihomo: AUTO group healthy; missing `extra` in YAML is GAP, not automatic FAIL.
6. Operator smoke: clients on subscription **auto** → PASS before next flag.
7. Step 4 extra checks: gRPC absent from AUTO `inboundIds`; managed gRPC `enable=false`; Vision/XHTTP/(AWG|HY2) remain.

**Stop criteria:** auto fail; XHTTP listen down; perpetual `changes>0` after normalize fix; Clash AUTO selector broken (not merely missing `extra`).

**Step 2 PASS accent:** two consecutive applies with unchanged env must not churn XHTTP stream.

**Step 3 PASS accent:** JSON carries `extra`, or documented GAP with enable not left silently on without a delivery path.

## Implementation touchpoints (for writing-plans)

- `builders/streams.py` — env-driven XHTTP builder; client `extra` helper
- `apply/inbound/ensure.py` — sanitize + managed projection + normalize
- `env.py` / `3x-ui.env` — defaults and validation
- `main.py` (+ inbound helpers) — gRPC when-disabled policy
- `apply/sub_balancer.py` — already filters empty ids; verify Step 4
- panel subscription delivery path for `extra` / optional `subJsonFragment`
- tests under `tests/3x-ui-scripts/python/`

## Open items for implementation plan only

- Exact panel API/settings key that injects `xhttpSettings.extra` into JSON sub (discover on live Streambase during Step 3).
- Whether Step 5 default range for `scMaxEachPostBytes` should be `500000-1000000` or another Traefik-safe band (decide after Step 1–2 smoke).

## Approval

- Approach C + Sections 1–3 approved in chat (2026-11-17).
- Item 7 (H3/Finalmask) explicitly out of scope.
- This file: awaiting operator review before invoking `writing-plans`.
